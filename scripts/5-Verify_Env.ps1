# ====================================================================
# ENVIRONMENT VERIFICATION SCRIPT
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Needs steps 1 to 4. Step 4 exits zero on a broken environment: every real
# failure so far was silent (a gstreamer subdirectory skipping itself, a
# DLL that built and could not load, gstreamer finding no plugins). This
# step asserts what is wanted: packages installed, every library LOADABLE,
# tools reachable, commands running, requested elements registered.
# Read-only; exits non-zero when something is wrong (unless -NoFail).
# ====================================================================

param
(
    # @brief JSON configuration, the same file the other steps were given. A bare name resolves against config/.
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief Toolchain id of a configuration with 'toolchains', e.g. -Toolchain ucrt. Empty for a single-toolchain
    # configuration. Resolved once below, so the rest of the script sees one subsystem and one triplet.
    [string]$Toolchain = "",

    # @brief Report problems and still exit zero.
    [switch]$NoFail,

    # @brief Validate the configuration and stop, changing nothing.
    [switch]$ValidateOnly
)

# FUNCTIONS
# --------------------------------------------------------------------

function Write-NoFormat
{
    param ($msg)
    Write-Host $msg
    if ($globalLogFile) {Add-Content -Path $globalLogFile -Value $msg}
}

function Write-Info
{
    param ($msg)
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][INFO][$msg]"
    Write-Host $line
    if ($globalLogFile) {Add-Content -Path $globalLogFile -Value $line}
}

function Write-Warn
{
    param ($msg)
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][WARN][$msg]"
    Write-Host $line
    if ($globalLogFile) {Add-Content -Path $globalLogFile -Value $line}
}

function Write-Error
{
    param ($msg)
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][ERROR][$msg]"
    Write-Host $line
    if ($globalLogFile){Add-Content -Path $globalLogFile -Value $line}
}

function Abort-WithError
{
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][ERROR][Verification could not run!]"
    Write-Host $line
    if ($globalLogFile){Add-Content -Path $globalLogFile -Value $line}

    if ([Environment]::UserInteractive -and -not [System.Console]::IsInputRedirected) {
        Write-Host ""
        Write-Host "Press any key to exit..."
        [void][System.Console]::ReadKey($true)
    }

    if ($originalTitle) { $host.UI.RawUI.WindowTitle = $originalTitle }
    # The log of a run that died is the one somebody will want, and the one nobody saves.
    if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }
    exit 1
}

function Get-ScriptDirectory
{
    if ($PSScriptRoot) { return $PSScriptRoot }
    else { return Split-Path -Parent (Convert-Path -LiteralPath ([System.Environment]::GetCommandLineArgs()[0])) }
}

function Read-EnvFile
{
    # @brief Read the generated .env into a hashtable, expanding ${...} the way the launcher does.
    # @note Line by line and in order, because that is the launcher's own contract: a forward reference expands to
    #       nothing there too, and this must see exactly what the launcher would see rather than a tidier version.
    param ([string]$Path)

    $map = @{}
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8))
    {
        $line = [string]$raw
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }

        $idx = $line.IndexOf("=")
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim().Trim('"')

        while ($val -match '\$\{([A-Za-z_][A-Za-z0-9_]*)\}')
        {
            $name = $Matches[1]
            $repl = if ($map.ContainsKey($name)) { [string]$map[$name] } else { "" }
            $val  = $val.Replace('${' + $name + '}', $repl)
        }

        $map[$key] = $val
    }
    return $map
}

function Get-VcpkgToolDirectories
{
    # @brief Every installed/<triplet>/tools directory holding executables: tools/<port>/ or tools/<port>/bin/
    #        (Qt6, icu...). Must match the launcher's own scan.
    param ([string]$ToolsRoot)

    $dirs = @()
    if (-not (Test-Path -LiteralPath $ToolsRoot)) { return $dirs }

    foreach ($first in (Get-ChildItem -LiteralPath $ToolsRoot -Directory -ErrorAction SilentlyContinue))
    {
        if (Get-ChildItem -LiteralPath $first.FullName -Filter "*.exe" -File -ErrorAction SilentlyContinue)
        {
            $dirs += $first.FullName
        }
        foreach ($second in (Get-ChildItem -LiteralPath $first.FullName -Directory -ErrorAction SilentlyContinue))
        {
            if (Get-ChildItem -LiteralPath $second.FullName -Filter "*.exe" -File -ErrorAction SilentlyContinue)
            {
                $dirs += $second.FullName
            }
        }
    }
    return $dirs
}

# --------------------------------------------------------------------
# Results
# --------------------------------------------------------------------
# Collected, then summarised and written to the installation record.

$script:results = @()

function Add-Result
{
    # @param State "ok", "fail" or "skip": a check that could not run (e.g. vcpkg's lock held) is not a failure.
    param
    (
        [string]$Group,
        [string]$Name,
        [string]$State,
        [string]$Detail = ""
    )

    $script:results += [pscustomobject]@{
        Group  = $Group
        Name   = $Name
        State  = $State
        Detail = $Detail
    }
}

function Set-GroupTotal
{
    # @brief How many items a group examined when it files fewer results (the load check files one), for the summary.
    param ([string]$Group, [int]$Total)

    $script:groupTotals[$Group] = $Total
}

# ====================================================================
# START
# ====================================================================

$script:groupTotals = @{}

$scriptStart   = Get-Date
$originalTitle = $host.UI.RawUI.WindowTitle
$host.UI.RawUI.WindowTitle = "Environment verification"

$scriptDir = Get-ScriptDirectory
# The steps live in scripts/. Everything they read out of the generator or write back into it -- the
# configuration, the overlay ports and triplets, the MSYS2 package cache, the launcher templates and these
# logs -- sits one level up beside that directory, so it is all named from the root and not from here.
$drivEnvRoot = Split-Path -Parent $scriptDir
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir   = Join-Path $drivEnvRoot "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }
$globalLogFile = Join-Path $logsDir "${timestamp}_generic_devdrive-verify.log"

Write-Info "ENVIRONMENT VERIFICATION"

# --------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------

if ([System.IO.Path]::IsPathRooted($ConfigFile)) { $cfgPath = $ConfigFile }
else { $cfgPath = Join-Path (Join-Path $drivEnvRoot "config") $ConfigFile }

if (-not (Test-Path -LiteralPath $cfgPath))
{
    Write-Error "Configuration not found: $cfgPath"
    Abort-WithError
}

try { $Cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch
{
    Write-Error "Configuration is not valid JSON: $($_.Exception.Message)"
    Abort-WithError
}

# Validate the whole configuration before anything reads a value out of it. An unknown key is an ERROR here rather
# than a silent fall-back to a default; the head of DrivEnvConfig.ps1 explains why that distinction earns a file.
. (Join-Path $PSScriptRoot "DrivEnvConfig.ps1")
. (Join-Path $PSScriptRoot "DrivEnvLogs.ps1")

$cfgProblems = @(Test-DrivEnvConfig -Config $Cfg)
if ($cfgProblems.Count -gt 0)
{
    Write-Error ("Configuration has {0} problem(s): {1}" -f $cfgProblems.Count, $cfgPath)
    foreach ($cfgProblem in $cfgProblems) { Write-Error "    $cfgProblem" }
    Abort-WithError
}

Write-Info "Configuration validated against the schema: no problems."
$metaLine = Get-DrivEnvMetadataSummary -Cfg $Cfg; if ($metaLine) { Write-Info $metaLine }

# --------------------------------------------------------------------
# TOOLCHAIN PROJECTION
# --------------------------------------------------------------------
# From here $Cfg holds ONE toolchain: msys2.target.subsystem and vcpkg.target.triplet are plain scalars.
# Runs after Test-DrivEnvConfig, which has already checked the ids and every projection.

$generated = Get-DrivEnvGenerateList -Cfg $Cfg

if ([string]::IsNullOrWhiteSpace($Toolchain))
{
    # A dual configuration run without -Toolchain would silently build whichever toolchain the unprojected
    # file happens to resemble, and there is no good candidate: the shared section has no subsystem and no
    # triplet at all. Refusing is the only honest answer.
    if ($generated.Count -gt 0)
    {
        Write-Error ("This configuration generates {0} toolchain(s) -- {1} -- so -Toolchain must say which one." -f $generated.Count, ($generated -join ", "))
        Write-Error "    Run it through Generate-DrivEnv.ps1, which loops the steps over them, or name one here."
        Abort-WithError
    }
}
else
{
    if ($generated.Count -eq 0)
    {
        Write-Error ("-Toolchain '{0}' was given, but this configuration declares no 'toolchains'." -f $Toolchain)
        Abort-WithError
    }

    if ($generated -notcontains $Toolchain)
    {
        Write-Error ("-Toolchain '{0}' is not generated by this configuration. It generates: {1}" -f $Toolchain, ($generated -join ", "))
        Abort-WithError
    }

    $Cfg = Resolve-DrivEnvToolchain -Cfg $Cfg -Id $Toolchain
    Write-Info ("Toolchain '{0}': subsystem '{1}', triplet '{2}'." -f $Toolchain, $Cfg.msys2.target.subsystem, $Cfg.vcpkg.target.triplet)
}

# This toolchain's files, from the one table every step names them with. Step 2 wrote the env file under this name.
$names = Get-DrivEnvToolchainNames -Cfg $Cfg
if ($null -eq $names)
{
    Write-Error "Cannot name this toolchain's files: environment.dev_drive_letter, environment.dev_env_name or the toolchain key is blank."
    Abort-WithError
}

# The one variable every read of the env file below goes through, assigned once, here, and printed under -ValidateOnly
# AS IT IS -- so what the tests see is what the step opens.
$envFilePath = $names.EnvFile

# The log was opened before the configuration said which toolchain this is; from here it carries the key, like the
# logs of steps 2 to 4. Moved, not copied, so what was written so far stays in it.
$keyedLog = Join-Path $logsDir (Get-DrivEnvLogName -Timestamp $timestamp -Role "generic_devdrive-verify" -Key $names.Key)
if ($globalLogFile -and ($keyedLog -ne $globalLogFile) -and (Test-Path -LiteralPath $globalLogFile))
{
    try   { Move-Item -LiteralPath $globalLogFile -Destination $keyedLog -Force -ErrorAction Stop; $globalLogFile = $keyedLog }
    catch { Write-Warn ("The log keeps its first name, {0}: {1}" -f $globalLogFile, $_.Exception.Message) }
}

if ($ValidateOnly)
{
    Write-Info ("Env file for this toolchain: {0}" -f $envFilePath)
    Write-Info "-ValidateOnly was given, so nothing further will run."
    exit 0
}
$driveLetter = ([string]$Cfg.environment.dev_drive_letter).Trim().TrimEnd(':').ToUpperInvariant()
$devEnvName  = ([string]$Cfg.environment.dev_env_name).Trim()

if (-not (Test-Path -LiteralPath $envFilePath))
{
    Write-Error "No generated environment file at $envFilePath. Run steps 1 to 4 for this toolchain first."
    $legacy = Get-DrivEnvLegacyEnvFile -Cfg $Cfg
    if ($legacy -and (Test-Path -LiteralPath $legacy))
    {
        Write-Error "This drive has $legacy, the single env file of a drive generated before 3.0.0 named one per toolchain."
    }
    Abort-WithError
}

$envMap  = Read-EnvFile -Path $envFilePath

# THE FILE IS THIS TOOLCHAIN'S, by its contents as well as by its name. A verification that read the other
# toolchain's file would compose the other toolchain's PATH and verify that, under this one's name.
$identity = Get-DrivEnvEnvFileProblem -EnvMap $envMap -Key $names.Key -Path $envFilePath
if ($identity)
{
    Write-Error $identity
    Abort-WithError
}
$vcpkgRoot = [string]$envMap["VCPKG_ROOT"]
$triplet   = [string]$envMap["VCPKG_DEFAULT_TRIPLET"]
$toolchainRoot = Get-DrivEnvToolchainRoot -EnvMap $envMap -Msys2Root $envMap["MSYS2_ROOT"] `
                                          -Msys2Env $envMap["MSYS2_ENV"] -Warn { param($m) Write-Warn $m }

if (-not $vcpkgRoot -or -not $triplet)
{
    Write-Error "VCPKG_ROOT or VCPKG_DEFAULT_TRIPLET missing from $envFilePath."
    Abort-WithError
}

$installedRoot = Join-Path $vcpkgRoot "installed/$triplet"
$binDir        = Join-Path $installedRoot "bin"
$pluginDir     = Join-Path $installedRoot "plugins/gstreamer"
$toolsRoot     = Join-Path $installedRoot "tools"
$vcpkgExe      = Join-Path $vcpkgRoot "vcpkg.exe"

# Everything checked must resolve inside this toolchain: its prefix or its triplets' installed trees (including
# per-package overrides), not merely the drive (Get-DrivEnvToolchainScopeViolation).
$tk = Get-DrivEnvToolchainKey -Cfg $Cfg
$installedRoots = @($installedRoot)
foreach ($t in (Get-DrivEnvToolchainTriplets -Cfg $Cfg))
{
    if ($t -ine $triplet) { $installedRoots += (Join-Path $vcpkgRoot "installed/$t") }
}

function Get-ScopeViolation
{
    # @return "" when Source belongs to the toolchain being verified, otherwise why it does not.
    param ([string]$Source)
    return (Get-DrivEnvToolchainScopeViolation -Source $Source -ToolchainRoot $toolchainRoot -InstalledRoots $installedRoots `
                                               -VcpkgRoot $vcpkgRoot -DriveLetter $driveLetter -ToolchainKey $tk)
}

Write-Info "Drive     : ${driveLetter}:"
Write-Info "Toolchain : $tk"
Write-Info "Triplet   : $triplet"
Write-Info "Installed : $installedRoot"

# --------------------------------------------------------------------
# What to check
# --------------------------------------------------------------------
# Each list comes from environment.verification; without it, only the packages and load checks run.

$verify = $Cfg.environment.verification

function Get-VerifyFlag
{
    param ([string]$Name, [bool]$Default)
    if ($verify -and ($verify.PSObject.Properties.Name -contains $Name)) { return [bool]$verify.$Name }
    return $Default
}

function Get-VerifyList
{
    param ([string]$Name)
    if ($verify -and ($verify.PSObject.Properties.Name -contains $Name)) { return @($verify.$Name) }
    return @()
}

$checkPackages = Get-VerifyFlag -Name "check_packages" -Default $true
$checkDllLoad  = Get-VerifyFlag -Name "check_dll_load" -Default $true
# Wrapped in @() here: a one-entry list comes back unrolled, and a single PSCustomObject has no .Count in 5.1.
$checkTools    = @(Get-VerifyList -Name "check_tools")
$checkCommands = @(Get-VerifyList -Name "check_commands")
$checkElements = @(Get-VerifyList -Name "check_gstreamer_elements")

# --------------------------------------------------------------------
# The environment this verification runs in
# --------------------------------------------------------------------
# Built from scratch, mirroring the launcher exactly (VCPKG_ROOT yes, PKG_CONFIG_PATH no): a PATH carrying another
# environment loads its DLLs (0xC0000139), and a better PATH than the launcher's would pass where users fail.
$toolDirs = Get-VcpkgToolDirectories -ToolsRoot $toolsRoot
$pathParts = @()
$pathParts += $toolDirs
$pathParts += $binDir
$pathParts += $vcpkgRoot
if ($toolchainRoot) { $pathParts += (Join-Path $toolchainRoot "bin") }
$pathParts += @("$env:SystemRoot\System32", "$env:SystemRoot")

$env:PATH = ($pathParts -join ';')

# GStreamer isolated: drop inherited GST_* (possibly the other toolchain's), this triplet's plugin path only, and a
# registry file of this run's own instead of the per-user cache shared by every toolchain. Restored at the end.
foreach ($gstVar in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'GST_*' } | ForEach-Object { $_.Name }))
{
    Remove-Item -LiteralPath ("Env:" + $gstVar) -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $pluginDir) { $env:GST_PLUGIN_PATH = $pluginDir }
$gstRegistryFile = Join-Path $env:TEMP ("drivenv-verify_{0}_{1}_registry.bin" -f $tk, $timestamp)
$env:GST_REGISTRY = $gstRegistryFile

Write-Info "Tool directories found: $($toolDirs.Count)"

# ====================================================================
# CHECK 1: the requested packages are installed
# ====================================================================

if ($checkPackages)
{
    Write-Info "CHECK: requested packages are installed."

    if (-not (Test-Path -LiteralPath $vcpkgExe))
    {
        Add-Result -Group "packages" -Name "vcpkg.exe" -State "fail" -Detail "not found at $vcpkgExe"
    }
    else
    {
        # --x-json keyed "name:triplet": one vcpkg tree holds every toolchain, so a package is looked up under the
        # triplet step 4 built it for (the plain listing also truncates that column). JSON and stderr to separate files.
        $listOutFile = Join-Path $env:TEMP ("drivenv-verify_{0}_{1}_vcpkg_list.json" -f $tk, $timestamp)
        $listErrFile = Join-Path $env:TEMP ("drivenv-verify_{0}_{1}_vcpkg_list.err" -f $tk, $timestamp)
        $listCode = -1
        $listText = ""
        $listErr  = ""
        try
        {
            $listProc = Start-Process -FilePath $vcpkgExe -ArgumentList @('list', '--x-json') -NoNewWindow -Wait -PassThru `
                                      -RedirectStandardOutput $listOutFile -RedirectStandardError $listErrFile
            $listCode = $listProc.ExitCode
            $listText = [string](Get-Content -LiteralPath $listOutFile -Raw -ErrorAction SilentlyContinue)
            $listErr  = [string](Get-Content -LiteralPath $listErrFile -Raw -ErrorAction SilentlyContinue)
        }
        catch
        {
            $listErr = $_.Exception.Message
        }
        finally
        {
            Remove-Item -LiteralPath $listOutFile, $listErrFile -Force -ErrorAction SilentlyContinue
        }

        # Another vcpkg holding the lock is the ordinary case, not an error: a dependency install can run for an hour
        # and somebody will verify in the middle of one. Reporting every package as missing then would be a lie.
        if (($listText + "`n" + $listErr) -match 'waiting to take filesystem lock')
        {
            Add-Result -Group "packages" -Name "all packages" -State "skip" `
                -Detail "another vcpkg process holds the lock; run this again when it finishes"
        }
        elseif ($listCode -ne 0)
        {
            $firstErr = @(([string]$listErr -split "`r?`n") | Where-Object { $_.Trim() }) | Select-Object -First 1
            Add-Result -Group "packages" -Name "all packages" -State "skip" `
                -Detail ("vcpkg list exited {0}, so nothing could be compared{1}" -f $listCode, $(if ($firstErr) { ": $firstErr" } else { "" }))
        }
        else
        {
            $listed = $null
            try   { $listed = ConvertFrom-DrivEnvVcpkgListJson -Text $listText }
            catch
            {
                Add-Result -Group "packages" -Name "all packages" -State "skip" -Detail $_.Exception.Message
            }

            # Verdicts from Get-DrivEnvPackageResults: an empty listing ({}) means every package is missing; an
            # unparseable one is $null, already filed as not checked.
            foreach ($verdict in (Get-DrivEnvPackageResults -Listed $listed -Packages $Cfg.vcpkg.packages -DefaultTriplet $triplet))
            {
                Add-Result -Group "packages" -Name $verdict.Name -State $verdict.State -Detail $verdict.Detail
            }
        }
    }
}

# ====================================================================
# CHECK 2: every library and plugin can be LOADED
# ====================================================================
# A DLL that built is not a DLL that works (missing dependency, unresolved import). ffmpeg.exe was dead in two
# environments while every build reported success.

if ($checkDllLoad)
{
    Write-Info "CHECK: every installed library and plugin loads."

    $targets = @()
    foreach ($dir in @($binDir, $pluginDir))
    {
        if (Test-Path -LiteralPath $dir)
        {
            $targets += Get-ChildItem -LiteralPath $dir -Filter "*.dll" -File -ErrorAction SilentlyContinue
        }
    }

    # In a child process: LoadLibrary pins every DLL (no FreeLibrary, whose detach order breaks glib), and in-process
    # the handles were held for hours, blocking a later `vcpkg remove`. A library that faults takes down only the
    # child, and is reported. The list goes in a file (431 paths exceed a command line); PATH is inherited.
    $listFile  = [System.IO.Path]::GetTempFileName()
    $childFile = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".ps1")

    $childBody = @'
param ([string]$ListFile)

Add-Type -ErrorAction Stop @"
using System;
using System.Runtime.InteropServices;
public static class DevDriveLoader
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);

    // LOAD_WITH_ALTERED_SEARCH_PATH: resolve the dependencies of the DLL relative to ITS OWN directory, which is
    // how the programs that use it will resolve them. Anything weaker would pass a library no consumer can load.
    public const uint AlteredSearchPath = 0x00000008;
}
"@

foreach ($path in (Get-Content -LiteralPath $ListFile))
{
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    $handle = [DevDriveLoader]::LoadLibraryExW($path, [IntPtr]::Zero, [DevDriveLoader]::AlteredSearchPath)
    if ($handle -eq [IntPtr]::Zero)
    {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Output ("FAIL`t{0}`t{1}" -f (Split-Path -Leaf $path), $code)
    }
}

# The sentinel is the point: without it, a child that died halfway through would look like a clean sweep.
Write-Output "SWEPT"
exit 0
'@

    $failed = 0
    try
    {
        Set-Content -LiteralPath $listFile -Value ($targets | ForEach-Object { $_.FullName }) -Encoding UTF8
        Set-Content -LiteralPath $childFile -Value $childBody -Encoding UTF8

        $hostExe = (Get-Process -Id $PID).Path
        if ([string]::IsNullOrWhiteSpace($hostExe)) { $hostExe = "powershell.exe" }

        $childOut = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $childFile -ListFile $listFile 2>&1
        $childCode = $LASTEXITCODE

        $lines = @($childOut | ForEach-Object { [string]$_ })
        if ($lines -notcontains "SWEPT")
        {
            Add-Result -Group "load" -Name "the load sweep" -State "skip" `
                       -Detail ("the child process ended at exit code {0} without finishing; a library may have faulted while loading" -f $childCode)
        }

        foreach ($line in $lines)
        {
            if (-not $line.StartsWith("FAIL`t")) { continue }
            $parts = $line.Split("`t")
            if ($parts.Count -lt 3) { continue }

            $code = 0
            [void][int]::TryParse($parts[2], [ref]$code)

            # 126 is ERROR_MOD_NOT_FOUND: a dependency is missing, which is by far the common case and the one
            # worth naming in the report, because the DLL itself is usually fine.
            $why = switch ($code)
            {
                126 { "a dependency is missing (ERROR_MOD_NOT_FOUND)" }
                127 { "an imported symbol is missing (ERROR_PROC_NOT_FOUND)" }
                193 { "not a valid image for this architecture" }
                default { "win32 error $code" }
            }
            Add-Result -Group "load" -Name $parts[1] -State "fail" -Detail $why
            $failed++
        }
    }
    finally
    {
        Remove-Item -LiteralPath $listFile  -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $childFile -Force -ErrorAction SilentlyContinue
    }

    Write-Info "Libraries checked: $($targets.Count), failed to load: $failed"
    Set-GroupTotal -Group "load" -Total $targets.Count
    if ($failed -eq 0 -and $targets.Count -gt 0)
    {
        Add-Result -Group "load" -Name "$($targets.Count) libraries" -State "ok"
    }
}

# ====================================================================
# CHECK 3: the named tools are reachable
# ====================================================================

if ($checkTools.Count -gt 0)
{
    Write-Info "CHECK: named tools are on PATH."

    foreach ($tool in $checkTools)
    {
        $name = ([string]$tool).Trim()
        if (-not $name) { continue }

        # -CommandType Application: 5.1 aliases curl and wget to Invoke-WebRequest.
        $found = @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue) |
                 Select-Object -First 1
        if (-not $found)
        {
            Add-Result -Group "tools" -Name $name -State "fail" -Detail "not on the environment's PATH"
            continue
        }

        # And it must come from this toolchain, not Git for Windows on PATH nor the other toolchain on the drive.
        $src = [string]$found.Source
        $why = Get-ScopeViolation -Source $src
        if ($why)
        {
            Add-Result -Group "tools" -Name $name -State "fail" -Detail $why
            continue
        }

        Add-Result -Group "tools" -Name $name -State "ok" -Detail $src
    }
}

# ====================================================================
# CHECK 4: the named commands run and say what they should
# ====================================================================
# Running is not finding: ffmpeg.exe was on PATH and exited 0xC0000135 when run.

if ($checkCommands.Count -gt 0)
{
    Write-Info "CHECK: named commands run."

    foreach ($entry in $checkCommands)
    {
        $cmd = [string]$entry.run
        if (-not $cmd) { continue }
        $expect = [string]$entry.expect

        $parts   = $cmd.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        $exe     = $parts[0]
        $cmdArgs = @()
        if ($parts.Count -gt 1) { $cmdArgs = $parts[1..($parts.Count - 1)] }

        # Application only, as above: the curl alias would resolve to nothing runnable.
        $resolved = @(Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue) |
                    Select-Object -First 1
        if (-not $resolved)
        {
            Add-Result -Group "commands" -Name $cmd -State "fail" -Detail "$exe not on PATH"
            continue
        }

        # Held to this toolchain like the tools above: a command that runs from another toolchain's tree, or from
        # the system's, says nothing about this environment.
        $why = Get-ScopeViolation -Source ([string]$resolved.Source)
        if ($why)
        {
            Add-Result -Group "commands" -Name $cmd -State "fail" -Detail "$exe $why"
            continue
        }

        try
        {
            $out = & $resolved.Source @cmdArgs 2>&1
            $code = $LASTEXITCODE
        }
        catch
        {
            Add-Result -Group "commands" -Name $cmd -State "fail" -Detail $_.Exception.Message
            continue
        }

        if ($code -ne 0)
        {
            # A negative code here is almost always the loader rather than the program: 0xC0000135 is
            # STATUS_DLL_NOT_FOUND and 0xC0000139 STATUS_ENTRYPOINT_NOT_FOUND.
            $hint = switch ($code)
            {
                -1073741515 { " (0xC0000135, a DLL it needs is missing)" }
                -1073741511 { " (0xC0000139, an entry point is missing -- usually a MIXED environment)" }
                default { "" }
            }
            Add-Result -Group "commands" -Name $cmd -State "fail" -Detail "exit $code$hint"
            continue
        }

        if ($expect -and (($out -join "`n") -notmatch [regex]::Escape($expect)))
        {
            Add-Result -Group "commands" -Name $cmd -State "fail" -Detail "ran, but the output does not contain '$expect'"
            continue
        }

        Add-Result -Group "commands" -Name $cmd -State "ok"
    }
}

# ====================================================================
# CHECK 5: the gstreamer elements a feature implies really exist
# ====================================================================
# A feature reported as built is not proof: an element that is not registered was a silent skip.

if ($checkElements.Count -gt 0)
{
    Write-Info "CHECK: named gstreamer elements are registered."

    # Application only, and from this toolchain, for the reasons given in the tools check: another gstreamer's
    # gst-inspect lists ITS elements, so every element below would be judged against the wrong tree.
    $inspect = @(Get-Command "gst-inspect-1.0" -CommandType Application -ErrorAction SilentlyContinue) | Select-Object -First 1
    $inspectWhy = if ($inspect) { Get-ScopeViolation -Source ([string]$inspect.Source) } else { "" }
    if (-not $inspect)
    {
        Add-Result -Group "elements" -Name "gst-inspect-1.0" -State "fail" -Detail "not on PATH, cannot check elements"
    }
    elseif ($inspectWhy)
    {
        Add-Result -Group "elements" -Name "gst-inspect-1.0" -State "fail" -Detail "$inspectWhy, cannot check elements"
    }
    else
    {
        $registered = @{}
        $loadWarnings = @()
        foreach ($line in (& $inspect.Source 2>&1))
        {
            $text = [string]$line
            # "plugin:  element: Long Name"
            if ($text -match '^\s*\S+:\s+(\S+):\s') { $registered[$Matches[1]] = $true }
            # gst-inspect reports a plugin it could not load as a warning, and that is a finding in its own right.
            if ($text -match "Failed to load plugin '([^']+)'") { $loadWarnings += $Matches[1] }
        }

        Write-Info "Elements registered: $($registered.Count)"
        if ($registered.Count -eq 0)
        {
            Add-Result -Group "elements" -Name "any element at all" -State "fail" `
                -Detail "gstreamer registered NOTHING, which usually means GST_PLUGIN_PATH is unset"
        }

        foreach ($el in $checkElements)
        {
            $name = ([string]$el).Trim()
            if (-not $name) { continue }
            $ok = $registered.ContainsKey($name)
            Add-Result -Group "elements" -Name $name -State $(if ($ok) { "ok" } else { "fail" }) `
                -Detail $(if ($ok) { "" } else { "not registered" })
        }

        foreach ($plugin in ($loadWarnings | Sort-Object -Unique))
        {
            Add-Result -Group "elements" -Name (Split-Path -Leaf $plugin) -State "fail" `
                -Detail "plugin present but gstreamer could not load it"
        }
    }
}

# ====================================================================
# CHECK 6: the controlled patch to vcpkg's own scripts is still applied
# ====================================================================
# Step 3 patches vcpkg's build-retry list (openssl's rename race). A baseline bump can make the patch silently stop
# applying, and the failure then shows hours later as a "compiler problem" on one machine. This makes it visible.

Write-Info "CHECK: the controlled vcpkg script patch is in place."

$patchTarget = Join-Path (Join-Path (Join-Path $vcpkgRoot "scripts") "cmake") "vcpkg_execute_build_process.cmake"
$patchName   = "openssl serial-install retry"

if (-not (Test-Path -LiteralPath $patchTarget))
{
    # "skip", not "fail": with no file there is nothing to inspect, and a vcpkg tree missing its own scripts is a
    # different diagnosis, one the checks above will already have reached. Claiming the patch failed here would
    # point the reader at the wrong thing.
    Add-Result -Group "patches" -Name $patchName -State "skip" `
        -Detail "vcpkg_execute_build_process.cmake not found under $vcpkgRoot, so this cannot be determined"
}
# ReadAllText, not Get-Content -Raw. On a zero-byte file Get-Content -Raw emits NOTHING rather than an empty
# string, and casting that to [string] still leaves null, so .Contains() threw -- outside any try, which would
# have killed this script before it wrote its report. ReadAllText returns "" and the check simply says "fail".
elseif ([System.IO.File]::ReadAllText($patchTarget).Contains('"Trying to rename "'))
{
    Add-Result -Group "patches" -Name $patchName -State "ok"
}
else
{
    Add-Result -Group "patches" -Name $patchName -State "fail" `
        -Detail ("not applied, so openssl may fail during 'make install' with a rename 'Permission denied' on " +
                 "machines that lose the race. Re-run 3-Clone_VCPKG.ps1, or add the pattern by hand")
}

# The registry this run's gstreamer scan wrote is this run's alone; nothing reads it again.
if ($gstRegistryFile) { Remove-Item -LiteralPath $gstRegistryFile -Force -ErrorAction SilentlyContinue }

# ====================================================================
# REPORT
# ====================================================================

$failures = @($script:results | Where-Object { $_.State -eq "fail" })
$passes   = @($script:results | Where-Object { $_.State -eq "ok" })
$skipped  = @($script:results | Where-Object { $_.State -eq "skip" })

Write-NoFormat ""
Write-NoFormat "======================================================================"
Write-NoFormat " VERIFICATION SUMMARY"
Write-NoFormat "======================================================================"

$totalChecked = 0
foreach ($group in ($script:results | Select-Object -ExpandProperty Group -Unique))
{
    $inGroup    = @($script:results | Where-Object { $_.Group -eq $group })
    $badInGroup = @($inGroup | Where-Object { $_.State -eq "fail" })
    $skipInGrp  = @($inGroup | Where-Object { $_.State -eq "skip" })
    $extra = if ($skipInGrp.Count -gt 0) { ", {0} not checked" -f $skipInGrp.Count } else { "" }

    $shown = $inGroup.Count
    if ($script:groupTotals.ContainsKey($group)) { $shown = $script:groupTotals[$group] }
    $totalChecked += $shown

    Write-NoFormat (" {0,-10} {1} checked, {2} failed{3}" -f $group, $shown, $badInGroup.Count, $extra)
}

if ($skipped.Count -gt 0)
{
    Write-NoFormat ""
    Write-NoFormat " NOT CHECKED"
    Write-NoFormat " -----------"
    foreach ($k in $skipped)
    {
        Write-NoFormat ("  [{0}] {1}{2}" -f $k.Group, $k.Name, $(if ($k.Detail) { " -- " + $k.Detail } else { "" }))
    }
}

if ($failures.Count -gt 0)
{
    Write-NoFormat ""
    Write-NoFormat " FAILURES"
    Write-NoFormat " --------"
    foreach ($f in $failures)
    {
        Write-NoFormat ("  [{0}] {1}{2}" -f $f.Group, $f.Name, $(if ($f.Detail) { " -- " + $f.Detail } else { "" }))
    }
}

Write-NoFormat "======================================================================"
Write-NoFormat ""

# The record goes next to the generated inventory, because "what this environment is" and "whether it works" are the
# same question asked twice.
$inventoryDir = "${driveLetter}:/installation"
if (Test-Path -LiteralPath $inventoryDir)
{
    $reportLines = @(
        "=======================================================================",
        "ENVIRONMENT VERIFICATION",
        "=======================================================================",
        ("Run on {0}. Toolchain {1}, triplet {2}." -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $names.Key, $triplet),
        ("{0} checks, {1} failed, {2} not checked." -f $totalChecked, $failures.Count, $skipped.Count),
        ""
    )
    foreach ($r in $script:results)
    {
        $label = switch ($r.State) { "ok" { "ok" } "skip" { "SKIP" } default { "FAIL" } }
        $reportLines += ("{0,-6} [{1}] {2}{3}" -f $label, $r.Group, $r.Name,
                         $(if ($r.Detail) { " -- " + $r.Detail } else { "" }))
    }

    # One report per toolchain: installation/ is the drive's, and a fixed name kept only the last toolchain's verdict.
    $dest = Join-Path $inventoryDir (Get-DrivEnvRecordName -Name "verification.txt" -Key $names.Key)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($dest, $reportLines, $utf8NoBom)
    Write-Info "Report written to $dest"
}

$elapsed = (Get-Date) - $scriptStart
# Derived from $totalChecked rather than counted from the results, so this line cannot disagree with the per-group
# lines printed a moment ago.
$totalPassed = $totalChecked - $failures.Count - $skipped.Count
Write-Info ("{0} checks, {1} passed, {2} failed, {3} not checked, in {4:N1} s" -f $totalChecked,
            $totalPassed, $failures.Count, $skipped.Count, $elapsed.TotalSeconds)

$host.UI.RawUI.WindowTitle = $originalTitle

# The final word must match the findings even when -NoFail suppresses the exit code, or the summary contradicts the
# list printed immediately above it -- which the first version of this script did, cheerfully reporting "OK" under
# thirty-nine failures.
if ($failures.Count -gt 0)
{
    Write-Error ("Verification found {0} problem(s)." -f $failures.Count)

    # ABOVE the -NoFail branch, not below it. That branch exits inline, so a copy placed after it runs only in
    # the -NoFail case -- which is the case where verification was told not to matter. The log worth keeping is
    # the other one.
    if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }

    if (-not $NoFail) { exit 1 }
    exit 0
}

if ($skipped.Count -gt 0)
{
    Write-Warn ("No failures, but {0} check(s) could not be carried out." -f $skipped.Count)
    if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }
    exit 0
}

Write-Info "Verification OK."
if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }
exit 0
