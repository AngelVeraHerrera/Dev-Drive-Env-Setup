# ====================================================================
# ENVIRONMENT VERIFICATION SCRIPT
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
# Updated: 26/08/2026
# Version: 1.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Prerequisites: steps 1 to 4 must have completed.
#
# WHY THIS STEP EXISTS
#
# Because step 4 exits zero on a broken environment. Every failure this
# tooling has actually hit was SILENT:
#
#   * DirectXMath was missing, so gstreamer's d3d11 subdirectory called
#     subdir_done() without a word, taking d3d12, gstcuda and nvcodec
#     with it. The first complaint came three layers away, about CUDA.
#   * GstWinRt is MSVC-only upstream, so mediafoundation skipped itself
#     the same silent way and every mf* encoder simply did not exist.
#   * The "gl" feature was not requested, so glupload did not exist --
#     indistinguishable, from the outside, from the two cases above.
#   * The vcpkg tools directories were on no PATH, so gst-inspect-1.0
#     could not be run at all.
#   * GST_PLUGIN_PATH was unset, and gstreamer then finds NOT ONE
#     plugin, which reads as a build that produced nothing.
#   * svt-av1 links fastfeat.dll while the port installs the file as
#     libfastfeat.dll, so libSvtAv1Enc could never load, so avcodec
#     could never load -- which killed ffmpeg.exe outright AND the
#     gstreamer libav plugin. That one went unnoticed in two separate
#     environments.
#
# Not one of those made any step fail. A build system reporting success
# is a statement about compilation, not about the environment being
# usable, and the gap between the two is where whole days go.
#
# So this step asserts the things that are actually wanted: the packages
# are installed, every library can be LOADED rather than merely built,
# the tools are reachable, the commands run, and the elements a requested
# feature implies are really there.
#
# It changes nothing. It reads, it runs read-only commands, and it exits
# non-zero when something is wrong.
#
# ====================================================================

param
(
    # @brief Path to the JSON configuration driving this run.
    #
    # A bare file name or a relative path resolves against THIS SCRIPT'S directory. Must be the SAME file the other
    # steps were given: this one reads what they wrote.
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief Report problems and still exit zero.
    #
    # For a run whose purpose is to look, not to gate. Without it a failure exits 1, which is what makes this usable
    # from a script or a scheduled check.
    [switch]$NoFail,

    # @brief Validate the configuration and stop, changing nothing.
    #
    # The validation runs on every invocation regardless; this switch only stops the script afterwards. Useful for
    # checking an edited configuration in a second, and for checking one BEFORE a step that takes an hour.
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
    foreach ($raw in (Get-Content -LiteralPath $Path))
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
    # @brief Every installed/<triplet>/tools directory that actually holds executables.
    # @note TWO levels, and measured rather than assumed: most ports put their .exe straight into tools/<port>/,
    #       while Qt6, icu, hwloc and libiconv put theirs in tools/<port>/bin/. The launcher does the same scan; if
    #       these two ever disagree, this step is checking a PATH nobody actually gets.
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
# Collected rather than printed as they happen, so the summary can be
# read without scrolling and so the same list can be written to the
# installation record.

$script:results = @()

function Add-Result
{
    # @param State One of "ok", "fail" or "skip".
    # @note THREE states, not two, and the third one earns its keep. A check that could not be carried out is not a
    #       check that failed: the first run of this step reported twenty-seven packages as missing when the truth was
    #       that another vcpkg process held the filesystem lock and the query returned nothing. A verification tool
    #       that cries wolf gets switched off, so "I could not tell" has to be sayable.
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
    # @brief Records how many things a group actually examined, when that differs from the number of results it filed.
    #
    # The load check walks every installed library and files ONE result, because four hundred lines of "ok" is not a
    # report. But then the summary counted results and printed "load 1 checked" directly underneath its own
    # "Libraries checked: 445" -- two numbers for the same work, in the same output, contradicting each other. The
    # summary uses this instead where it is set, so the headline matches the detail.
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
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir   = Join-Path $scriptDir "install_logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }
$globalLogFile = Join-Path $logsDir "${timestamp}_generic_devdrive-verify.log"

Write-Info "ENVIRONMENT VERIFICATION"

# --------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------

if ([System.IO.Path]::IsPathRooted($ConfigFile)) { $cfgPath = $ConfigFile }
else { $cfgPath = Join-Path $scriptDir $ConfigFile }

if (-not (Test-Path -LiteralPath $cfgPath))
{
    Write-Error "Configuration not found: $cfgPath"
    Abort-WithError
}

try { $Cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json }
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

if ($ValidateOnly)
{
    Write-Info "-ValidateOnly was given, so nothing further will run."
    if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }
    exit 0
}
$driveLetter = ([string]$Cfg.environment.dev_drive_letter).Trim().TrimEnd(':').ToUpperInvariant()
$devEnvName  = ([string]$Cfg.environment.dev_env_name).Trim()
$envFilePath = Join-Path "$driveLetter`:" (("env/{0}_env_variables.env" -f $devEnvName).ToLower())

if (-not (Test-Path -LiteralPath $envFilePath))
{
    Write-Error "No generated environment file at $envFilePath. Run steps 1 to 4 first."
    Abort-WithError
}

$envMap  = Read-EnvFile -Path $envFilePath
$vcpkgRoot = [string]$envMap["VCPKG_ROOT"]
$triplet   = [string]$envMap["VCPKG_DEFAULT_TRIPLET"]
$mingwRoot = [string]$envMap["MINGW_ROOT"]

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

Write-Info "Drive     : ${driveLetter}:"
Write-Info "Triplet   : $triplet"
Write-Info "Installed : $installedRoot"

# --------------------------------------------------------------------
# What to check
# --------------------------------------------------------------------
# Every check is a configuration choice, because what an environment is
# FOR decides what "working" means: a drive built for gstreamer wants its
# elements asserted, one built for a database does not.
#
# Absent block, or absent key, means: run the two checks that need no
# naming (packages and library loading) and skip the lists.

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
$checkTools    = Get-VerifyList -Name "check_tools"
$checkCommands = Get-VerifyList -Name "check_commands"
$checkElements = Get-VerifyList -Name "check_gstreamer_elements"

# --------------------------------------------------------------------
# The environment this verification runs in
# --------------------------------------------------------------------
# Built from scratch rather than inherited. A PATH carrying ANOTHER
# environment resolves a DLL from that one, and the failure is
# spectacular and misleading: exit 0xC0000139, "entry point not found",
# which reads as a broken build rather than a mixed one.

# Assembled to MIRROR the launcher, component for component, and deliberately not improved on. If this step ran with
# a better PATH than the launcher provides, it would pass while the environment people actually use fails -- so
# VCPKG_ROOT is here because the launcher puts it there (it carries vcpkg.exe itself), and PKG_CONFIG_PATH is NOT set
# because the launcher does not set it either. That the environment leaves 410 .pc files unreachable to a hand-run
# pkgconf is a real gap, but it is the environment's gap to close, not this script's to paper over.
$toolDirs = Get-VcpkgToolDirectories -ToolsRoot $toolsRoot
$pathParts = @()
$pathParts += $toolDirs
$pathParts += $binDir
$pathParts += $vcpkgRoot
if ($mingwRoot) { $pathParts += (Join-Path $mingwRoot "bin") }
$pathParts += @("$env:SystemRoot\System32", "$env:SystemRoot")

$env:PATH = ($pathParts -join ';')
if (Test-Path -LiteralPath $pluginDir) { $env:GST_PLUGIN_PATH = $pluginDir }

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
        $listOut  = & $vcpkgExe list 2>&1
        $listCode = $LASTEXITCODE
        $listText = ($listOut -join "`n")

        # Another vcpkg holding the lock is the ordinary case, not an error: a dependency install can run for an hour
        # and somebody will verify in the middle of one. Reporting every package as missing then would be a lie.
        if ($listText -match 'waiting to take filesystem lock')
        {
            Add-Result -Group "packages" -Name "all packages" -State "skip" `
                -Detail "another vcpkg process holds the lock; run this again when it finishes"
        }
        elseif ($listCode -ne 0)
        {
            Add-Result -Group "packages" -Name "all packages" -State "skip" `
                -Detail "vcpkg list exited $listCode, so nothing could be compared"
        }
        else
        {
            $listed = @{}
            foreach ($line in $listOut)
            {
                # "name:triplet   version   description"; feature rows are "name[feature]:triplet".
                if ([string]$line -match '^([A-Za-z0-9_.\-]+)(\[[^\]]*\])?:') { $listed[$Matches[1]] = $true }
            }

            if ($listed.Count -eq 0)
            {
                Add-Result -Group "packages" -Name "all packages" -State "skip" `
                    -Detail "vcpkg list produced no recognisable rows"
            }
            else
            {
                foreach ($pkg in @($Cfg.vcpkg.packages))
                {
                    $name = [string]$pkg.name
                    if (-not $name) { continue }
                    $ok = $listed.ContainsKey($name)
                    Add-Result -Group "packages" -Name $name -State $(if ($ok) { "ok" } else { "fail" }) `
                        -Detail $(if ($ok) { "" } else { "not installed" })
                }
            }
        }
    }
}

# ====================================================================
# CHECK 2: every library and plugin can be LOADED
# ====================================================================
# The check that matters most, and the cheapest one nobody runs. A DLL
# that built is not a DLL that works: it can be missing a dependency, or
# importing a name nothing provides, and neither shows up until something
# tries to load it. That is how ffmpeg.exe came to be dead in two
# environments while every build reported success.

if ($checkDllLoad)
{
    Write-Info "CHECK: every installed library and plugin loads."

    Add-Type -ErrorAction Stop @'
using System;
using System.Runtime.InteropServices;
public static class DevDriveLoader
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);

    // LOAD_WITH_ALTERED_SEARCH_PATH: resolve the dependencies of the DLL relative to ITS OWN directory, which is how
    // the programs that use it will resolve them. Anything weaker would pass a library that no consumer can load.
    public const uint AlteredSearchPath = 0x00000008;
}
'@

    $targets = @()
    foreach ($dir in @($binDir, $pluginDir))
    {
        if (Test-Path -LiteralPath $dir)
        {
            $targets += Get-ChildItem -LiteralPath $dir -Filter "*.dll" -File -ErrorAction SilentlyContinue
        }
    }

    $failed = 0
    foreach ($dll in $targets)
    {
        $handle = [DevDriveLoader]::LoadLibraryExW($dll.FullName, [IntPtr]::Zero,
                                                   [DevDriveLoader]::AlteredSearchPath)
        if ($handle -eq [IntPtr]::Zero)
        {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            # 126 is ERROR_MOD_NOT_FOUND: a dependency is missing, which is by far the common case and the one worth
            # naming in the report, because the DLL itself is usually fine.
            $why = switch ($code)
            {
                126 { "a dependency is missing (ERROR_MOD_NOT_FOUND)" }
                127 { "an imported symbol is missing (ERROR_PROC_NOT_FOUND)" }
                193 { "not a valid image for this architecture" }
                default { "win32 error $code" }
            }
            Add-Result -Group "load" -Name $dll.Name -State "fail" -Detail $why
            $failed++
        }
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

        $found = Get-Command $name -ErrorAction SilentlyContinue
        if ($found)
        {
            Add-Result -Group "tools" -Name $name -State "ok" -Detail $found.Source
        }
        else
        {
            Add-Result -Group "tools" -Name $name -State "fail" -Detail "not on the environment's PATH"
        }
    }
}

# ====================================================================
# CHECK 4: the named commands run and say what they should
# ====================================================================
# Running a tool is a different question from finding it: ffmpeg.exe was
# on PATH and exited 0xC0000135 the moment it was invoked.

if ($checkCommands.Count -gt 0)
{
    Write-Info "CHECK: named commands run."

    foreach ($entry in $checkCommands)
    {
        $cmd = [string]$entry.run
        if (-not $cmd) { continue }
        $expect = [string]$entry.expect

        $parts = $cmd.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
        $exe   = $parts[0]
        $args  = @()
        if ($parts.Count -gt 1) { $args = $parts[1..($parts.Count - 1)] }

        $resolved = Get-Command $exe -ErrorAction SilentlyContinue
        if (-not $resolved)
        {
            Add-Result -Group "commands" -Name $cmd -State "fail" -Detail "$exe not on PATH"
            continue
        }

        try
        {
            $out = & $resolved.Source @args 2>&1
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
# The whole point: asking for a feature and being told yes is not the
# same as getting it. Every silent skip in the history above ends here,
# as an element that is simply not registered.

if ($checkElements.Count -gt 0)
{
    Write-Info "CHECK: named gstreamer elements are registered."

    $inspect = Get-Command "gst-inspect-1.0" -ErrorAction SilentlyContinue
    if (-not $inspect)
    {
        Add-Result -Group "elements" -Name "gst-inspect-1.0" -State "fail" -Detail "not on PATH, cannot check elements"
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
# Every check above verifies what vcpkg PRODUCED. This one verifies vcpkg itself, because step 3 modifies one file
# inside the pinned clone and nothing else would notice if that modification stopped taking effect.
#
# The patch adds openssl's rename failure to vcpkg's build-retry list, so an install that loses the
# add-depends.pl race falls back to a serial make instead of failing the port outright. It applies by anchoring on
# a neighbouring entry in that list, which means a baseline bump that reworks the list leaves the patch silently
# doing nothing. Step 3 warns at the moment it happens -- and that warning scrolls past, while the consequence
# turns up hours later, in a different step, on one machine out of two, looking for all the world like a compiler
# problem. Somebody spent two days on exactly that. This check is what makes the state visible on demand.

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
        ("Run on {0}. Triplet {1}." -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $triplet),
        ("{0} checks, {1} failed, {2} not checked." -f $totalChecked, $failures.Count, $skipped.Count),
        ""
    )
    foreach ($r in $script:results)
    {
        $label = switch ($r.State) { "ok" { "ok" } "skip" { "SKIP" } default { "FAIL" } }
        $reportLines += ("{0,-6} [{1}] {2}{3}" -f $label, $r.Group, $r.Name,
                         $(if ($r.Detail) { " -- " + $r.Detail } else { "" }))
    }

    $dest = Join-Path $inventoryDir "verification.txt"
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
