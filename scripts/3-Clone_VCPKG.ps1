# ====================================================================
# VCPKG CLONE SETUP SCRIPT
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
#          David Abuin Sanchez
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Needs steps 1 and 2 for this toolchain: reads the env file step 2 wrote
# (<drive>:\env\<prefix>_<subsystem>_env_variables.env) for the MSYS2 layout.
# ====================================================================

# FUNCTIONS
# --------------------------------------------------------------------

param
(
    # @brief JSON configuration. A bare name resolves against config/. Every step must get the same file.
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief Toolchain id of a configuration with 'toolchains', e.g. -Toolchain ucrt. Empty for a single-toolchain
    # configuration. Resolved once below, so the rest of the script sees one subsystem and one triplet.
    [string]$Toolchain = "",

    # @brief Validate the configuration and stop, changing nothing.
    [switch]$ValidateOnly
)

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
    $line = "[$ts][ERROR][Setup failed!]"
    Write-Host $line
    if ($globalLogFile){Add-Content -Path $globalLogFile -Value $line}

    # UserInteractive is also True with stdin redirected, where ReadKey throws: check both.
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

function Test-IsAdministrator
{
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScriptDirectory
{
    if ($PSScriptRoot) { return $PSScriptRoot }
    else { return Split-Path -Parent (Convert-Path -LiteralPath ([System.Environment]::GetCommandLineArgs()[0])) }
}

function Convert-ToMSYSPath($winPath)
{
    return $winPath -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
}

function Convert-ToDriveStylePath($winPath)
{
    # @brief Normalize a Windows path to the forward-slash drive style used by the .env files
    #        written by the previous steps (e.g. "X:\vcpkg" -> "X:/vcpkg").
    return ([string]$winPath) -replace '\\', '/'
}

function Convert-ToWinPath($anyPath)
{
    # @brief Normalize a value coming from the .env file (forward slashes) to a Windows path.
    return ([string]$anyPath) -replace '/', '\'
}

function Invoke-Native
{
    # @brief Run a native executable, mirroring stdout/stderr into the log. Returns the exit code.
    param
    (
        [string]  $FilePath,
        [string[]]$Arguments = @(),
        [string]  $WorkingDirectory = ""
    )

    $pushed = $false
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory))
    {
        Push-Location -LiteralPath $WorkingDirectory
        $pushed = $true
    }

    try
    {
        & $FilePath @Arguments 2>&1 | ForEach-Object { Write-NoFormat ("    | " + $_) }
        return $LASTEXITCODE
    }
    finally
    {
        if ($pushed) { Pop-Location }
    }
}

function Get-NativeOutput
{
    # @brief Run a native executable quietly and capture its output. Returns @{ExitCode; Output}.
    param
    (
        [string]  $FilePath,
        [string[]]$Arguments = @()
    )

    $out = & $FilePath @Arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = @($out) }
}

function Read-EnvFile
{
    # @brief Parse a KEY=VALUE environment file into a hashtable. Values are kept verbatim.
    param ([string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }

    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8))
    {
        $line = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith("#")) { continue }

        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }

        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        $map[$key] = $val
    }

    return $map
}

function Test-EnvFileDefines
{
    # @brief Whether the env file already carries a KEY= line for this name, i.e. an earlier step defined it.
    param
    (
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8))
    {
        $line = [string]$raw
        $idx  = $line.IndexOf("=")
        if ($idx -gt 0 -and $line.Substring(0, $idx).Trim() -eq $Name) { return $true }
    }
    return $false
}

function Get-TextFileHash
{
    # @brief SHA256 of a text file's content with line endings normalised to LF and the BOM removed. Not Get-FileHash:
    # with core.autocrlf=true git checks the triplets out as CRLF, and a raw-byte hash then differs between machines.
    # .gitattributes keeps them byte-stable too; this covers older clones and hand-converted copies.
    param ([string]$Path)

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text = $text -replace "`r`n", "`n"

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try   { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) }
    finally { $sha.Dispose() }

    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToUpperInvariant()
}

function Update-VcpkgScriptPatches
{
    # @brief Add openssl's concurrent-rename failure to vcpkg's build-retry list. Returns $true on success.
    # openssl's 'make install' runs three sub-makes that each run util/add-depends.pl in one directory; on Windows the
    # rename over Makefile fails ("Trying to rename Makefile-NNNN -> Makefile: Permission denied", Error 13). Lower
    # concurrency does not help (they overlap at any -j above 1). vcpkg already re-runs the serial command when the log
    # matches Z_VCPKG_EXECUTE_BUILD_PROCESS_RETRY_ERROR_MESSAGES; the retry reuses the built tree, so it is nearly free.
    # Not fatal (a missing anchor means the baseline moved: warn) and idempotent.
    param ([string]$VcpkgRoot)

    $target = Join-Path (Join-Path (Join-Path $VcpkgRoot "scripts") "cmake") "vcpkg_execute_build_process.cmake"

    if (-not (Test-Path -LiteralPath $target))
    {
        Write-Warn "vcpkg_execute_build_process.cmake not found, so the openssl retry patch was not applied."
        return $false
    }

    $content = Get-Content -LiteralPath $target -Raw
    $marker  = '"Trying to rename "'

    if ($content.Contains($marker))
    {
        Write-Info "vcpkg's retry list already covers openssl's rename race; nothing to patch."
        return $true
    }

    # The last entry of the existing concurrency group, so the addition lands with its own kind.
    $anchor = '    "mkdir [^:]*: File exists"'

    if (-not $content.Contains($anchor))
    {
        Write-Warn "Could not find the anchor in vcpkg_execute_build_process.cmake, so the openssl rename patch"
        Write-Warn "was NOT applied. The pinned baseline has most likely moved. openssl can then fail during"
        Write-Warn "'make install' on machines that lose the add-depends.pl race, with 'Permission denied' on a"
        Write-Warn "rename; see the comment on Update-VcpkgScriptPatches in this script for the full mechanism."
        return $false
    }

    $additionLines = @(
        "    # openssl's util/add-depends.pl writes Makefile-<pid> and renames it over Makefile. 'make install'",
        "    # reaches build_libs, build_modules and build_inst_programs, each of which runs its own sub-make of",
        "    # 'depend', so three copies of that script race on the same file at any -j above 1. Windows fails",
        "    # that rename with EACCES. The serial retry cannot lose the race: it never runs two of them at once.",
        '    "Trying to rename "'
    )

    # Match the file's own line endings rather than imposing ours. A git clone on Windows may hold either,
    # depending on core.autocrlf, and a file with mixed endings is a needless thing to hand to a diff.
    $newline = "`n"
    if ($content.Contains("`r`n")) { $newline = "`r`n" }

    $patched = $content.Replace($anchor, ($anchor + $newline + ($additionLines -join $newline)))

    # WriteAllText, not Set-Content: PowerShell 5.1's -Encoding UTF8 prepends a BOM, and .NET's default here is
    # UTF-8 without one, which is what the file already is.
    [System.IO.File]::WriteAllText($target, $patched)

    # Read it back. This is a file inside a pinned clone that nothing else verifies, and a patch which silently
    # failed to apply is precisely the failure mode that had somebody chasing a compiler bug for two days.
    if ((Get-Content -LiteralPath $target -Raw).Contains($marker))
    {
        Write-Info "Patched vcpkg's build-retry list: an openssl rename race now falls back to a serial install."
        return $true
    }

    Write-Warn "Wrote the openssl retry patch but could not read it back; check $target by hand."
    return $false
}

function Resolve-GitExecutable
{
    # @brief Locate git.exe in the drive's MSYS2: <toolchain root>\bin (mingw git), usr\bin (msys git), or the login shell.
    param
    (
        [string]$ToolchainRoot,
        [string]$Msys2Root,
        [string]$BashPath
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ToolchainRoot)) { $candidates += (Join-Path (Convert-ToWinPath $ToolchainRoot) "bin\git.exe") }
    if (-not [string]::IsNullOrWhiteSpace($Msys2Root)) { $candidates += (Join-Path (Convert-ToWinPath $Msys2Root) "usr\bin\git.exe") }

    foreach ($candidate in $candidates)
    {
        if (Test-Path -LiteralPath $candidate)
        {
            Write-Info "Git found at: $candidate"
            return $candidate
        }
        Write-Info "Git not present at: $candidate"
    }

    if (-not [string]::IsNullOrWhiteSpace($BashPath) -and (Test-Path -LiteralPath $BashPath))
    {
        Write-Info "Asking the MSYS2 login shell for the git location..."

        $probe = Get-NativeOutput $BashPath @("-lc", "command -v git")
        if ($probe.ExitCode -eq 0 -and $probe.Output.Count -gt 0)
        {
            $posix = ([string]$probe.Output[0]).Trim()
            if (-not [string]::IsNullOrWhiteSpace($posix))
            {
                $conv = Get-NativeOutput $BashPath @("-lc", "cygpath -w '$posix'")
                if ($conv.ExitCode -eq 0 -and $conv.Output.Count -gt 0)
                {
                    $winPath = ([string]$conv.Output[0]).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($winPath) -and (Test-Path -LiteralPath $winPath))
                    {
                        Write-Info "Git found via MSYS2 login shell at: $winPath"
                        return $winPath
                    }
                }
            }
        }
    }

    return $null
}

# CONFIGURATION
# --------------------------------------------------------------------

# A relative -ConfigFile resolves against config/, never the caller's working directory.
$ConfigPath = if ([System.IO.Path]::IsPathRooted($ConfigFile))
{
    $ConfigFile
}
else
{
    Join-Path (Join-Path (Split-Path -Parent (Get-ScriptDirectory)) "config") $ConfigFile
}

if (-not (Test-Path $ConfigPath))
{
    Write-Error "Configuration file missing: $ConfigPath"
    Abort-WithError
}

try
{
    $Cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch
{
    Write-Error "Invalid JSON in $ConfigPath"
    Abort-WithError
}

# Validate the whole configuration before anything reads a value out of it. An unknown key is an ERROR here rather
# than a silent fall-back to a default; the head of DrivEnvConfig.ps1 explains why that distinction earns a file.
. (Join-Path $PSScriptRoot "DrivEnvConfig.ps1")
. (Join-Path $PSScriptRoot "DrivEnvLogs.ps1")
Enable-DrivEnvGitTrust   # the drive's repositories may belong to another account (an imported drive)

$cfgProblems = @(Test-DrivEnvConfig -Config $Cfg)
if ($cfgProblems.Count -gt 0)
{
    Write-Error ("Configuration has {0} problem(s): {1}" -f $cfgProblems.Count, $ConfigPath)
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

# The configuration as read, kept for the one thing that is the DRIVE's and not this toolchain's: the vcpkg baseline
# every toolchain shares, which STEP 2 below may take from the toolchain that resolved it first. Read-only.
$CfgFull = $Cfg

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

# One baseline per drive: decided against what every other declared toolchain recorded (Get-DrivEnvBaselineDecision).
# Not wrapped in @(): Get-DrivEnvDeclaredTargets comma-returns.
$baselineSiblings = @()
foreach ($t in (Get-DrivEnvDeclaredTargets -Cfg $CfgFull))
{
    if ($t.Key -ieq $names.Key) { continue }
    $tn = Get-DrivEnvToolchainNames -Cfg $t.Cfg
    if ($null -ne $tn) { $baselineSiblings += [pscustomobject]@{ Id = $(if ($t.Id) { $t.Id } else { $t.Key }); EnvFile = $tn.EnvFile } }
}

# The one variable every read of the env file below goes through, assigned once, here, and printed under -ValidateOnly
# AS IT IS -- so what the tests see is what the step opens.
$envFilePath = $names.EnvFile

if ($ValidateOnly)
{
    Write-Info ("Env file for this toolchain: {0}" -f $envFilePath)
    foreach ($s in $baselineSiblings) { Write-Info ("The vcpkg baseline also consults: {0} (toolchain '{1}')" -f $s.EnvFile, $s.Id) }
    Write-Info "-ValidateOnly was given, so nothing further will run."
    exit 0
}
if (-not $Cfg.environment)   { Write-Error "Missing 'environment' object in config JSON: $ConfigPath";  Abort-WithError }
if (-not $Cfg.vcpkg)         { Write-Error "Missing 'vcpkg' object in config JSON: $ConfigPath";        Abort-WithError }
if (-not $Cfg.vcpkg.source)  { Write-Error "Missing 'vcpkg.source' object in config JSON: $ConfigPath"; Abort-WithError }
if (-not $Cfg.vcpkg.target)  { Write-Error "Missing 'vcpkg.target' object in config JSON: $ConfigPath"; Abort-WithError }

# Environment section
$driveLetter = [string]$Cfg.environment.dev_drive_letter
$devEnvName  = [string]$Cfg.environment.dev_env_name

if ([string]::IsNullOrWhiteSpace($driveLetter)) { Write-Error "Missing environment.dev_drive_letter"; Abort-WithError }
if ([string]::IsNullOrWhiteSpace($devEnvName))  { Write-Error "Missing environment.dev_env_name";     Abort-WithError }

$driveLetter = $driveLetter.Trim().TrimEnd(':').ToUpperInvariant()
if ($driveLetter -notmatch '^[A-Z]$')
{
    Write-Error "Invalid environment.dev_drive_letter (expected a single letter): $driveLetter"
    Abort-WithError
}

$devDrive = "{0}:\" -f $driveLetter

# VCPKG source section
$vcpkgGitUrl   = [string]$Cfg.vcpkg.source.repository_url
$baselineMode  = [string]$Cfg.vcpkg.source.baseline_mode
$baselineFixed = [string]$Cfg.vcpkg.source.baseline_commit

if ([string]::IsNullOrWhiteSpace($vcpkgGitUrl))
{
    Write-Error "Missing vcpkg.source.repository_url in config JSON: $ConfigPath"
    Abort-WithError
}

if ([string]::IsNullOrWhiteSpace($baselineMode))
{
    Write-Error "Missing vcpkg.source.baseline_mode in config JSON (expected 'fixed' or 'latest')"
    Abort-WithError
}

$baselineMode = $baselineMode.Trim().ToLowerInvariant()
if ($baselineMode -ne "fixed" -and $baselineMode -ne "latest")
{
    Write-Error ("Invalid vcpkg.source.baseline_mode: '{0}' (expected 'fixed' or 'latest')" -f $baselineMode)
    Abort-WithError
}

if ($baselineMode -eq "fixed")
{
    if ([string]::IsNullOrWhiteSpace($baselineFixed))
    {
        Write-Error "vcpkg.source.baseline_mode is 'fixed' but vcpkg.source.baseline_commit is empty"
        Abort-WithError
    }

    $baselineFixed = $baselineFixed.Trim()
    if ($baselineFixed -notmatch '^[0-9a-fA-F]{7,40}$')
    {
        Write-Error ("Invalid vcpkg.source.baseline_commit (expected a 7-40 char hex commit id): '{0}'" -f $baselineFixed)
        Abort-WithError
    }
}

# VCPKG target section
$vcpkgTriplet = [string]$Cfg.vcpkg.target.triplet
if ([string]::IsNullOrWhiteSpace($vcpkgTriplet))
{
    Write-Error "Missing vcpkg.target.triplet in config JSON: $ConfigPath"
    Abort-WithError
}

$vcpkgTriplet = $vcpkgTriplet.Trim()
if ($vcpkgTriplet -notmatch '^[A-Za-z0-9._-]+$')
{
    Write-Error ("Invalid vcpkg.target.triplet: '{0}'" -f $vcpkgTriplet)
    Abort-WithError
}

# Dev drive layout (a project convention, mirroring the 'msys64' root fixed by step 2)
$vcpkgRootWin       = Join-Path $devDrive "vcpkg"
$overlayPortsWin    = Join-Path $devDrive "overlays\ports"
$overlayTripletsWin = Join-Path $devDrive "overlays\triplets"
$binaryCacheWin     = Join-Path $devDrive "packages\vcpkg"
$vcpkgExeWin        = Join-Path $vcpkgRootWin "vcpkg.exe"


# INITIAL PREPARATION
# --------------------------------------------------------------------

$scriptStart = Get-Date
$scriptDir   = Get-ScriptDirectory
# The steps live in scripts/. Everything they read out of the generator or write back into it -- the
# configuration, the overlay ports and triplets, the MSYS2 package cache, the launcher templates and these
# logs -- sits one level up beside that directory, so it is all named from the root and not from here.
$drivEnvRoot = Split-Path -Parent $scriptDir

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir = Join-Path $drivEnvRoot "logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile = Join-Path $logsDir (Get-DrivEnvLogName -Timestamp $timestamp -Role "vcpkg-clone-setup" -Key $names.Key)
$globalLogFileUnix = Convert-ToMSYSPath $globalLogFile

$originalTitle = $host.UI.RawUI.WindowTitle
$host.UI.RawUI.WindowTitle = "GENERIC VCPKG CLONE SETUP SCRIPT"

# SCRIPT STARTUP HEADER
# --------------------------------------------------------------------

if ($baselineMode -eq "fixed") { $baselineDisplay = $baselineFixed }
else                           { $baselineDisplay = "(resolved from remote HEAD)" }

Write-NoFormat "================================================================="
Write-NoFormat "  VCPKG CLONE SETUP SCRIPT"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "  Authors: Angel Vera Herrera"
Write-NoFormat "           David Abuin Sanchez"
Write-NoFormat "  Updated: 20/10/2026"
Write-NoFormat "  Version: 3.0.0"
Write-NoFormat "================================================================="
Write-NoFormat "Parameters (Loaded from JSON):"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "Drive Letter     = $devDrive"
Write-NoFormat "Dev Env Name     = $devEnvName"
Write-NoFormat "Env File         = $envFilePath"
Write-NoFormat "VCPKG Repository = $vcpkgGitUrl"
Write-NoFormat "VCPKG Root       = $vcpkgRootWin"
Write-NoFormat "VCPKG Triplet    = $vcpkgTriplet"
Write-NoFormat "Baseline Mode    = $baselineMode"
Write-NoFormat "Baseline Commit  = $baselineDisplay"
Write-NoFormat "Current Path     = $scriptDir"
Write-NoFormat "================================================================="

# STEP 1: Initial checks and preparations.
# --------------------------------------------------------------------

Write-Info "STEP 1: Initial checks and preparations."

Write-Info "Checking permissions..."
# No elevation needed: this step only writes to the drive and TEMP. Running elevated is worse than unnecessary: every
# directory vcpkg creates would be owned by BUILTIN\Administrators instead of the user.
if (Test-IsAdministrator)
{
    Write-Warn "Running elevated. Nothing in this step needs it, and what it creates belongs to Administrators until"
    Write-Warn "Generate-DrivEnv.ps1, run elevated, hands the drive to environment.owner at its end. Run alone, start it"
    Write-Warn "from an ordinary terminal, as Generate-DrivEnv.ps1 itself can be (step 1 asks for elevation by itself)."
}

Write-Info "Checking if Dev Drive exists..."
try
{
    $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    Write-Info "Dev Drive detected at $devDrive"
}
catch
{
    Write-Error "Dev Drive '$devDrive' is not available or not mounted. Run 1-Setup_DevDrive.ps1 first."
    Abort-WithError
}

Write-Info "Reading environment file produced by the previous steps..."
if (-not (Test-Path -LiteralPath $envFilePath))
{
    Write-Error "Environment file not found: $envFilePath"
    Write-Error "Run 1-Setup_DevDrive.ps1 and 2-Setup_MSYS2.ps1 for this toolchain before this script."
    $legacy = Get-DrivEnvLegacyEnvFile -Cfg $Cfg
    if ($legacy -and (Test-Path -LiteralPath $legacy))
    {
        Write-Error "This drive has $legacy, the single env file of a drive generated before 3.0.0 named one per toolchain."
    }
    Abort-WithError
}

$envMap = Read-EnvFile $envFilePath

# THE FILE IS THIS TOOLCHAIN'S, by its contents as well as by its name: see Get-DrivEnvEnvFileProblem.
$identity = Get-DrivEnvEnvFileProblem -EnvMap $envMap -Key $names.Key -Path $envFilePath
if ($identity)
{
    Write-Error $identity
    Abort-WithError
}

$msys2Root = [string]$envMap["MSYS2_ROOT"]
$msys2Bash = [string]$envMap["MSYS2_BASH"]
# Checked equal to the toolchain key just above, so it needs no fallback of its own.
$msys2Env  = [string]$envMap["MSYS2_ENV"]

# Fall back to the layout conventions of step 2 if the file predates them.
if ([string]::IsNullOrWhiteSpace($msys2Root))
{
    $msys2Root = "{0}:/msys64" -f $driveLetter
    Write-Warn "MSYS2_ROOT missing from the environment file, assuming: $msys2Root"
}
$toolchainRoot = Get-DrivEnvToolchainRoot -EnvMap $envMap -Msys2Root $msys2Root -Msys2Env $msys2Env `
                                          -Warn { param($m) Write-Warn $m }
if ([string]::IsNullOrWhiteSpace($msys2Bash))
{
    $msys2Bash = "{0}/usr/bin/bash.exe" -f $msys2Root
    Write-Warn "MSYS2_BASH missing from the environment file, assuming: $msys2Bash"
}

$msys2RootWin = Convert-ToWinPath $msys2Root
$toolchainRootWin = Convert-ToWinPath $toolchainRoot
$msys2BashWin = Convert-ToWinPath $msys2Bash

Write-Info "MSYS2_ROOT = $msys2RootWin"
Write-Info "DEVSYSTEM_TOOLCHAIN_ROOT = $toolchainRootWin"
Write-Info "MSYS2_ENV  = $msys2Env"

Write-Info "Checking if msys2 bash exists..."
if (-not (Test-Path -LiteralPath $msys2BashWin))
{
    Write-Error "Bash not found at expected MSYS2 path: $msys2BashWin"
    Write-Error "Run 2-Setup_MSYS2.ps1 before this script."
    Abort-WithError
}

Write-Info "Checking if git tool exists..."
$gitExe = Resolve-GitExecutable -ToolchainRoot $toolchainRoot -Msys2Root $msys2Root -BashPath $msys2BashWin
if (-not $gitExe)
{
    Write-Error "Git was not found inside the generated MSYS2 installation."
    Write-Error "Looked under '$toolchainRootWin\bin' and '$msys2RootWin\usr\bin', and asked the MSYS2 login shell."
    Write-Error "Re-run 2-Setup_MSYS2.ps1, which installs the git package."
    Abort-WithError
}

# MSYS2 runtime DLLs must be reachable for git and its helper processes.
$env:PATH = "{0}\bin;{1}\usr\bin;{2}" -f $toolchainRootWin, $msys2RootWin, $env:PATH

# Windows system directories at the tail: bootstrap-vcpkg.bat calls powershell.exe by name (Add-DrivEnvWindowsSystemPath).
[void](Add-DrivEnvWindowsSystemPath -Report { param($m) Write-Info $m })

$gitVersion = Get-NativeOutput $gitExe @("--version")
if ($gitVersion.ExitCode -ne 0)
{
    Write-Error "Git was found at '$gitExe' but failed to run (ExitCode=$($gitVersion.ExitCode))."
    foreach ($line in $gitVersion.Output) { Write-Error ("    | " + $line) }
    Abort-WithError
}
Write-Info ("Using git: " + ([string]$gitVersion.Output[0]).Trim())

Write-Info "STEP 1: OK"

# STEP 2: Resolve the vcpkg baseline commit.
# --------------------------------------------------------------------

Write-Info "STEP 2: Resolve the vcpkg baseline commit."

# What every other toolchain of the drive recorded, for those that have run.
foreach ($s in $baselineSiblings)
{
    $recorded = ""
    if (Test-Path -LiteralPath $s.EnvFile) { $recorded = ([string](Read-EnvFile $s.EnvFile)["VCPKG_BASELINE"]).Trim() }
    Add-Member -InputObject $s -MemberType NoteProperty -Name Baseline -Value $recorded -Force
}

$decision = Get-DrivEnvBaselineDecision -Mode $baselineMode -Fixed $baselineFixed -Siblings $baselineSiblings
foreach ($w in $decision.Warnings) { Write-Warn $w }

if ($decision.Action -eq "fixed")
{
    $vcpkgBaseline = $decision.Commit
    Write-Info "Baseline mode 'fixed': using configured commit $vcpkgBaseline"
}
elseif ($decision.Action -eq "reuse")
{
    $vcpkgBaseline = $decision.Commit
    Write-Info ("Baseline mode 'latest': reusing commit {0}, which toolchain '{1}' recorded. One drive, one vcpkg clone, one baseline." -f
                $vcpkgBaseline, $decision.From)
    Write-Info "To move a drive holding more than one toolchain to a newer vcpkg: generate a new drive, or set baseline_mode 'fixed' with the new commit and, for every toolchain, remove its ports from its own shell and run steps 3 and 4 -- in classic mode step 4 does not rebuild what is already installed."
}
else
{
    Write-Info "Baseline mode 'latest': querying remote HEAD of $vcpkgGitUrl ..."

    $lsRemote = Get-NativeOutput $gitExe @("ls-remote", "--", $vcpkgGitUrl, "HEAD")
    if ($lsRemote.ExitCode -ne 0)
    {
        Write-Error "Failed to query the remote HEAD (ExitCode=$($lsRemote.ExitCode))."
        foreach ($line in $lsRemote.Output) { Write-Error ("    | " + $line) }
        Abort-WithError
    }

    $vcpkgBaseline = ""
    foreach ($line in $lsRemote.Output)
    {
        if (([string]$line) -match '^([0-9a-fA-F]{40})\s') { $vcpkgBaseline = $matches[1]; break }
    }

    if ([string]::IsNullOrWhiteSpace($vcpkgBaseline))
    {
        Write-Error "Could not parse a commit id from the 'git ls-remote' output."
        foreach ($line in $lsRemote.Output) { Write-Error ("    | " + $line) }
        Abort-WithError
    }

    Write-Info "Resolved remote HEAD to commit $vcpkgBaseline"
}

Write-Info "STEP 2: OK"

# STEP 3: Clone the vcpkg repository.
# --------------------------------------------------------------------

Write-Info "STEP 3: Clone the vcpkg repository."

$needClone = $true

if (Test-Path -LiteralPath $vcpkgRootWin)
{
    if (Test-Path -LiteralPath (Join-Path $vcpkgRootWin ".git"))
    {
        $probe = Get-NativeOutput $gitExe @("-C", $vcpkgRootWin, "rev-parse", "--is-inside-work-tree")
        if ($probe.ExitCode -ne 0)
        {
            Write-Error "'$vcpkgRootWin' contains a .git entry but is not a usable git work tree."
            Write-Error "Delete the folder and re-run this script to obtain a clean clone."
            foreach ($line in $probe.Output) { Write-Error ("    | " + $line) }
            Abort-WithError
        }

        Write-Info "Existing vcpkg repository detected at $vcpkgRootWin"
        $needClone = $false
    }
    else
    {
        $entries = @(Get-ChildItem -LiteralPath $vcpkgRootWin -Force -ErrorAction SilentlyContinue)
        if ($entries.Count -eq 0)
        {
            Write-Info "Removing empty '$vcpkgRootWin' before cloning."
            Remove-Item -LiteralPath $vcpkgRootWin -Force -Recurse
        }
        else
        {
            Write-Error "'$vcpkgRootWin' exists, is not empty and is not a git repository (incomplete clone?)."
            Write-Error "Delete the folder and re-run this script to obtain a clean clone."
            Abort-WithError
        }
    }
}

if ($needClone)
{
    Write-Info "Cloning $vcpkgGitUrl into $vcpkgRootWin ..."

    $code = Invoke-Native $gitExe @("clone", "--", $vcpkgGitUrl, $vcpkgRootWin)
    if ($code -ne 0)
    {
        Write-Error "Failed to clone the vcpkg repository (ExitCode=$code)."
        Abort-WithError
    }

    if (-not (Test-Path -LiteralPath (Join-Path $vcpkgRootWin ".git")))
    {
        Write-Error "The vcpkg repository was not properly cloned (missing .git directory)."
        Abort-WithError
    }

    Write-Info "Clone completed."
}

Write-Info "STEP 3: OK"

# STEP 4: Check out the baseline commit.
# --------------------------------------------------------------------

Write-Info "STEP 4: Check out the baseline commit."

$headBefore = ""
$revBefore = Get-NativeOutput $gitExe @("-C", $vcpkgRootWin, "rev-parse", "HEAD")
if ($revBefore.ExitCode -eq 0 -and $revBefore.Output.Count -gt 0)
{
    $headBefore = ([string]$revBefore.Output[0]).Trim()
    Write-Info "Current HEAD: $headBefore"
}

# Files this script modifies inside the vcpkg clone on purpose. Without this list every re-run would warn
# that the work tree is dirty and that "the checkout may fail", pointing at a change we made ourselves two
# steps later -- which trains the reader to ignore the one warning that would matter if it named another file.
$managedVcpkgFiles = @("scripts/cmake/vcpkg_execute_build_process.cmake")

$dirty = Get-NativeOutput $gitExe @("-C", $vcpkgRootWin, "status", "--porcelain")
if ($dirty.ExitCode -eq 0 -and $dirty.Output.Count -gt 0)
{
    $unexpected = @()

    foreach ($line in $dirty.Output)
    {
        # Porcelain format is two status characters, a space, then the path.
        $entry = ([string]$line)
        $path  = if ($entry.Length -gt 3) { $entry.Substring(3).Trim().Trim('"') } else { "" }

        if ($managedVcpkgFiles -contains $path) { Write-Info ("Expected local change, applied by this script: " + $path) }
        else { $unexpected += $entry }
    }

    if ($unexpected.Count -gt 0)
    {
        Write-Warn "The vcpkg work tree has unexpected local modifications; the checkout may fail."
        foreach ($line in $unexpected) { Write-Warn ("    | " + $line) }
    }
}

# Fetch only when the requested commit is not already present locally.
$hasCommit = Get-NativeOutput $gitExe @("-C", $vcpkgRootWin, "rev-parse", "--verify", "--quiet", ($vcpkgBaseline + "^{commit}"))
if ($hasCommit.ExitCode -ne 0)
{
    Write-Info "Baseline commit not present locally, fetching from origin..."

    $code = Invoke-Native $gitExe @("-C", $vcpkgRootWin, "fetch", "--tags", "origin")
    if ($code -ne 0)
    {
        Write-Error "Failed to fetch from origin (ExitCode=$code)."
        Abort-WithError
    }

    $hasCommit = Get-NativeOutput $gitExe @("-C", $vcpkgRootWin, "rev-parse", "--verify", "--quiet", ($vcpkgBaseline + "^{commit}"))
    if ($hasCommit.ExitCode -ne 0)
    {
        Write-Error "Baseline commit '$vcpkgBaseline' does not exist in $vcpkgGitUrl after fetching."
        Write-Error "Check vcpkg.source.baseline_commit in the configuration file."
        Abort-WithError
    }
}

Write-Info "Checking out baseline commit $vcpkgBaseline ..."
$code = Invoke-Native $gitExe @("-C", $vcpkgRootWin, "checkout", "--detach", $vcpkgBaseline)
if ($code -ne 0)
{
    Write-Error "Failed to checkout vcpkg commit $vcpkgBaseline (ExitCode=$code)."
    Abort-WithError
}

$headAfter = ""
$revAfter = Get-NativeOutput $gitExe @("-C", $vcpkgRootWin, "rev-parse", "HEAD")
if ($revAfter.ExitCode -eq 0 -and $revAfter.Output.Count -gt 0)
{
    $headAfter = ([string]$revAfter.Output[0]).Trim()
}

if ([string]::IsNullOrWhiteSpace($headAfter))
{
    Write-Error "Could not read HEAD after the checkout."
    Abort-WithError
}

$headChanged = ($headBefore -ne $headAfter)
Write-Info "vcpkg checked out to baseline $headAfter"

Write-Info "STEP 4: OK"

# STEP 5: Apply the controlled patches to the checked-out vcpkg scripts.
# --------------------------------------------------------------------

Write-Info "STEP 5: Apply the controlled patches to the vcpkg scripts."

# After the checkout, before the bootstrap: patch vcpkg's retry list (never fatal; see Update-VcpkgScriptPatches).
[void](Update-VcpkgScriptPatches -VcpkgRoot $vcpkgRootWin)

Write-Info "STEP 5: OK"


# STEP 6: Bootstrap vcpkg.
# --------------------------------------------------------------------

Write-Info "STEP 6: Bootstrap vcpkg."

$bootstrapNeeded = $true

if (Test-Path -LiteralPath $vcpkgExeWin)
{
    if ($headChanged)
    {
        Write-Info "vcpkg.exe exists but the baseline changed; bootstrapping again."
    }
    else
    {
        Write-Info "Already bootstrapped. Skipping."
        $bootstrapNeeded = $false
    }
}

if ($bootstrapNeeded)
{
    $bootstrapBat = Join-Path $vcpkgRootWin "bootstrap-vcpkg.bat"
    if (-not (Test-Path -LiteralPath $bootstrapBat))
    {
        Write-Error "Bootstrap script not found: $bootstrapBat"
        Abort-WithError
    }

    Write-Info "Running $bootstrapBat ..."
    $code = Invoke-Native $bootstrapBat @("-disableMetrics") $vcpkgRootWin
    if ($code -ne 0)
    {
        Write-Error "vcpkg bootstrap process failed (ExitCode=$code)."
        Abort-WithError
    }

    if (-not (Test-Path -LiteralPath $vcpkgExeWin))
    {
        Write-Error "vcpkg.exe was not found after bootstrapping: $vcpkgExeWin"
        Abort-WithError
    }

    Write-Info "Bootstrap completed. vcpkg.exe located at: $vcpkgExeWin"
}

Write-Info "Querying vcpkg version..."
$code = Invoke-Native $vcpkgExeWin @("version") $vcpkgRootWin
if ($code -ne 0)
{
    Write-Error "Failed to retrieve the vcpkg version (ExitCode=$code)."
    Abort-WithError
}

Write-Info "STEP 6: OK"

# STEP 7: Install the controlled overlay triplet.
# --------------------------------------------------------------------

Write-Info "STEP 7: Install the controlled overlay triplet '$vcpkgTriplet'."

$tripletFileName = "{0}.cmake"  -f $vcpkgTriplet
$tripletHashName = "{0}.sha256" -f $vcpkgTriplet

$tripletSrc     = Join-Path $drivEnvRoot ("vcpkg_overlays\triplets\{0}" -f $tripletFileName)
$tripletHashSrc = Join-Path $drivEnvRoot ("vcpkg_overlays\triplets\{0}" -f $tripletHashName)
$tripletDst     = Join-Path $overlayTripletsWin $tripletFileName

if (-not (Test-Path -LiteralPath $tripletSrc))
{
    Write-Error "Source triplet file missing: $tripletSrc"
    Write-Error "Check vcpkg.target.triplet in the configuration file, or add the triplet to vcpkg_overlays\triplets."
    Abort-WithError
}

if (-not (Test-Path -LiteralPath $tripletHashSrc))
{
    Write-Error "Controlled triplet hash file not found: $tripletHashSrc"
    Write-Error "Regenerate it with vcpkg_overlays\triplets\Utility-Hash_Generator.bat."
    Abort-WithError
}

# Integrity of the shipped triplet.
$expectedHash = ((Get-Content -Path $tripletHashSrc -Raw).Split(" ")[0]).Trim().ToUpperInvariant()
$sourceHash   = Get-TextFileHash -Path $tripletSrc

if ($sourceHash -ne $expectedHash)
{
    Write-Error "Triplet integrity check failed for: $tripletSrc"
    Write-Error "Expected SHA256 $expectedHash but found $sourceHash"
    Write-Error "The hash ignores line endings, so this means the CONTENT differs. Read the diff before"
    Write-Error "regenerating the hash: a mismatch is the check working, not the check being wrong."
    Abort-WithError
}

Write-Info "Triplet integrity verified (SHA256 $expectedHash)."

if (-not (Test-Path -LiteralPath $overlayTripletsWin))
{
    New-Item -ItemType Directory -Path $overlayTripletsWin -Force | Out-Null
    Write-Info "Created overlay triplets directory: $overlayTripletsWin"
}

$currentHash = ""
if (Test-Path -LiteralPath $tripletDst)
{
    $currentHash = Get-TextFileHash -Path $tripletDst
}

if ($currentHash -eq $expectedHash)
{
    Write-Info "Triplet is already up to date at: $tripletDst"
}
else
{
    Copy-Item -LiteralPath $tripletSrc -Destination $tripletDst -Force
    Write-Info "Triplet installed into overlay: $tripletDst"
}

# Every other triplet in the overlay directory is installed and verified too; only the configured one is mandatory.
# The static triplets (ucrt and clang) are kept as a capability; nothing uses them (see vcpkg_overlays/README.md).
$tripletSrcDir = Split-Path -Parent $tripletSrc
$extraTriplets = @(Get-ChildItem -LiteralPath $tripletSrcDir -Filter "*.cmake" -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -ne $tripletFileName })

foreach ($extraTriplet in $extraTriplets)
{
    $extraHashSrc = Join-Path $tripletSrcDir ($extraTriplet.BaseName + ".sha256")

    # No hash, no install. The configured triplet aborts the run when its hash is missing; an alternative only
    # declines to travel, because refusing to generate a whole drive over a triplet nobody asked for would be worse.
    if (-not (Test-Path -LiteralPath $extraHashSrc))
    {
        Write-Warn ("Additional triplet '{0}' has no .sha256 and was NOT installed." -f $extraTriplet.Name)
        Write-Warn  "Regenerate the hashes with Utility-Hash_Generator.bat in the triplets directory."
        continue
    }

    $extraExpected = ((Get-Content -Path $extraHashSrc -Raw).Split(" ")[0]).Trim().ToUpperInvariant()
    $extraActual   = Get-TextFileHash -Path $extraTriplet.FullName

    if ($extraActual -ne $extraExpected)
    {
        Write-Error ("Triplet integrity check failed for: {0}" -f $extraTriplet.FullName)
        Write-Error ("Expected SHA256 {0} but found {1}" -f $extraExpected, $extraActual)
        Abort-WithError
    }

    $extraDst = Join-Path $overlayTripletsWin $extraTriplet.Name
    Copy-Item -LiteralPath $extraTriplet.FullName -Destination $extraDst -Force
    Write-Info ("Additional triplet installed: {0}" -f $extraDst)
}

Write-Info "STEP 7: OK"

# STEP 8: Install the controlled overlay ports.
# --------------------------------------------------------------------

Write-Info "STEP 8: Install the controlled overlay ports."

# Overlay ports are layered: vcpkg takes the first layer of a triplet's list that holds a port, chosen per
# invocation, so triplets can differ. Every layer any triplet asks for is installed; "ports" always, empty without
# a vcpkg.overlay_root (the set the layers come from), so the path vcpkg is given exists either way.
$overlaySrcRoot = $null
$overlayRootCfg = ([string]$Cfg.vcpkg.overlay_root).Trim()
if ($overlayRootCfg)
{
    # Relative to the generator (vcpkg_overlays/degoras), or absolute: a set kept elsewhere, beside its configuration.
    $overlaySrcRoot = if ([System.IO.Path]::IsPathRooted($overlayRootCfg)) { $overlayRootCfg } else { Join-Path $drivEnvRoot $overlayRootCfg }
    if (-not (Test-Path -LiteralPath $overlaySrcRoot -PathType Container))
    {
        Write-Error "vcpkg.overlay_root: '$overlaySrcRoot' does not exist."
        Abort-WithError
    }
    Write-Info "Overlay ports from: $overlaySrcRoot"
}
else
{
    Write-Info "No vcpkg.overlay_root: no overlay ports, every package comes from the vcpkg registry as published."
}

$overlayLayerNames = @("ports")
foreach ($entry in @($Cfg.vcpkg.overlay_ports))
{
    foreach ($layer in @($entry.layers))
    {
        # -replace rather than a chain of Trim() calls: Trim takes a char array, so trimming both slash kinds
        # means Trim([char]'/', [char]'\') and getting that wrong throws a conversion error at runtime rather
        # than quietly doing nothing.
        $trimmedLayer = ([string]$layer).Trim() -replace '^[\\/]+', '' -replace '[\\/]+$', ''
        if ([string]::IsNullOrWhiteSpace($trimmedLayer)) { continue }

        # A layer name is a single directory under vcpkg.overlay_root, not a path: anything else would reach outside
        # the set, and the reconcile below deletes whatever it finds in the destination.
        if ($trimmedLayer -match '[\\/]' -or $trimmedLayer -match '\.\.')
        {
            Write-Error "vcpkg.overlay_ports: '$trimmedLayer' must be a single directory name under vcpkg.overlay_root."
            Abort-WithError
        }

        if ($overlayLayerNames -notcontains $trimmedLayer) { $overlayLayerNames += $trimmedLayer }
    }
}

Write-Info ("Overlay port layers to install: {0}" -f ($overlayLayerNames -join ', '))

$overlayRootWin = Join-Path $devDrive "overlays"
if (-not (Test-Path -LiteralPath $overlayRootWin))
{
    New-Item -ItemType Directory -Path $overlayRootWin -Force | Out-Null
}

# A layer directory that no configuration references any more is removed, for the same reason a retired port is:
# an overlay outranks the builtin registry, so anything left behind keeps shadowing upstream silently. Only
# directories whose name looks like a ports layer are considered, so "triplets" is never touched.
foreach ($staleLayer in @(Get-ChildItem -LiteralPath $overlayRootWin -Directory -ErrorAction SilentlyContinue))
{
    if ($staleLayer.Name -ne "ports" -and -not $staleLayer.Name.StartsWith("ports.")) { continue }
    if ($overlayLayerNames -contains $staleLayer.Name) { continue }

    Write-Info "Removing retired overlay layer: $($staleLayer.Name)"
    Remove-Item -LiteralPath $staleLayer.FullName -Recurse -Force -ErrorAction Stop
}

$totalPorts = 0

foreach ($layerName in $overlayLayerNames)
{
    $layerSrc = if ($overlaySrcRoot) { Join-Path $overlaySrcRoot $layerName } else { $null }
    $layerDst = Join-Path $overlayRootWin $layerName

    $srcPortDirs = @()
    if ($layerSrc -and (Test-Path -LiteralPath $layerSrc))
    {
        $srcPortDirs = @(Get-ChildItem -LiteralPath $layerSrc -Directory)
    }
    elseif ($layerName -ne "ports")
    {
        # A named layer that does not exist is a configuration error, not an empty layer: silently treating it as
        # empty would mean a port the configuration expects to be overridden quietly comes from upstream instead.
        # "ports" is the implicit one, empty when the set has none.
        Write-Error "vcpkg.overlay_ports names layer '$layerName', but vcpkg.overlay_root holds no such folder ($layerSrc)."
        Abort-WithError
    }

    if (-not (Test-Path -LiteralPath $layerDst))
    {
        New-Item -ItemType Directory -Path $layerDst -Force | Out-Null
        Write-Info "Created overlay layer directory: $layerDst"
    }

    # Reconcile, do not merely add: a port removed from the repository must disappear from the drive too.
    foreach ($stale in @(Get-ChildItem -LiteralPath $layerDst -Directory))
    {
        if ($srcPortDirs.Name -notcontains $stale.Name)
        {
            Write-Info "Removing retired overlay port: $layerName/$($stale.Name)"
            Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction Stop
        }
    }

    foreach ($dir in $srcPortDirs)
    {
        $dstPath = Join-Path $layerDst $dir.Name

        Write-Info "Installing overlay port: $layerName/$($dir.Name) -> $dstPath"
        try
        {
            if (Test-Path -LiteralPath $dstPath)
            {
                Remove-Item -LiteralPath $dstPath -Recurse -Force
            }
            # -ErrorAction Stop or the catch never fires: Copy-Item's errors are non-terminating by default, so a
            # failed copy logged "Overlay port installed" right after the destination had already been deleted.
            Copy-Item -LiteralPath $dir.FullName -Destination $dstPath -Recurse -Force -ErrorAction Stop
        }
        catch
        {
            Write-Error "Failed to install overlay port $layerName/$($dir.Name): $_"
            Abort-WithError
        }
    }

    Write-Info ("Layer '{0}': {1} port(s) installed." -f $layerName, $srcPortDirs.Count)
    $totalPorts += $srcPortDirs.Count
}

Write-Info ("Installed {0} overlay port(s) across {1} layer(s)." -f $totalPorts, $overlayLayerNames.Count)

Write-Info "STEP 8: OK"

# STEP 9: Setup environment variables.
# --------------------------------------------------------------------

Write-Info "STEP 9: Setup environment variables."

if (-not (Test-Path -LiteralPath $binaryCacheWin))
{
    New-Item -ItemType Directory -Path $binaryCacheWin -Force | Out-Null
    Write-Info "Created vcpkg binary cache directory: $binaryCacheWin"
}

# DEVSYSTEM_BUILDTREES = <drive>/<buildtrees_root>/<triplet>: one tree per toolchain for the user's builds. Written
# after VCPKG_DEFAULT_TRIPLET, which it references. Step 4's cleanup leaves it alone (no vcpkg stamp).
$buildtrees = Resolve-DrivEnvBuildtreesRoot -Cfg $Cfg -DriveLetter $driveLetter -Triplet $vcpkgTriplet `
                                            -Warn { param($m) Write-Warn $m }
$toolchainBuildtreesWin = Convert-ToWinPath $buildtrees.ToolchainWindows
if (-not (Test-Path -LiteralPath $toolchainBuildtreesWin))
{
    New-Item -ItemType Directory -Path $toolchainBuildtreesWin -Force | Out-Null
    Write-Info "Created this toolchain's build trees directory: $toolchainBuildtreesWin"
}

# THIS TOOLCHAIN'S CUSTOM FOLDERS: the entries of environment.custom_folders that carry ${DEVSYSTEM_TOOLCHAIN_ID},
# with it replaced by this toolchain's key. Step 1 creates the others; it cannot create these, because it is the
# drive's step and knows no toolchain. Rooted paths and '..' were refused by the validator.
$toolchainKey = Get-DrivEnvToolchainKey -Cfg $Cfg
foreach ($rel in (Get-DrivEnvCustomFolders -Cfg $Cfg -ToolchainKey $toolchainKey))
{
    $folderWin = Join-Path $devDrive ($rel.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $folderWin))
    {
        New-Item -ItemType Directory -Path $folderWin -Force | Out-Null
        Write-Info "Created folder: $folderWin"
    }
}

# Values keep the forward-slash drive style used by the previous steps. VCPKG_BIN and PATH are
# written as references so the launcher bootstrap resolves them after its own path conversions.
$vcpkgEnvValues = [ordered]@{
    "VCPKG_ROOT"                 = (Convert-ToDriveStylePath $vcpkgRootWin)
    "VCPKG_DEFAULT_BINARY_CACHE" = (Convert-ToDriveStylePath $binaryCacheWin)
    "VCPKG_OVERLAY_PORTS"        = (Convert-ToDriveStylePath $overlayPortsWin)
    "VCPKG_OVERLAY_TRIPLETS"     = (Convert-ToDriveStylePath $overlayTripletsWin)
    "VCPKG_DEFAULT_TRIPLET"      = $vcpkgTriplet
    "VCPKG_DEFAULT_HOST_TRIPLET" = $vcpkgTriplet
    "VCPKG_BASELINE"             = $headAfter
    "VCPKG_BIN"                  = '${VCPKG_ROOT}/installed/${VCPKG_DEFAULT_TRIPLET}/bin'
    "DEVSYSTEM_BUILDTREES"       = $buildtrees.EnvValue
}

# -- Custom variables and custom PATH entries --------------------------------------------------------------------------
# custom_variables: extra KEY=VALUE lines. custom_path_entries: extra PATH components, literal or ${REFERENCE}.
# Written here, not in step 2: PATH must be the last assignment and every reference defined above it (the launcher
# expands line by line; a forward reference becomes an empty component, which means "current directory").
$customVarNames = @()
if ($Cfg.environment.custom_variables)
{
    foreach ($prop in $Cfg.environment.custom_variables.PSObject.Properties)
    {
        $name = [string]$prop.Name
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$')
        {
            Write-Error "environment.custom_variables: '$name' is not a usable variable name."
            Abort-WithError
        }

        $value = [string]$prop.Value

        # Quoted only when it needs to be. The bootstrap strips one layer of surrounding quotes, and the .bat launcher
        # splits on the FIRST '=' only, so a value containing spaces survives either way -- but quoting makes the
        # intent obvious in a file people read and hand-edit.
        if ($value -match '\s') { $value = '"' + $value + '"' }

        # Every ${REFERENCE} must already be defined: an undefined one expands to empty (GST_PLUGIN_PATH empty = no plugins).
        foreach ($m in [regex]::Matches($value, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}'))
        {
            $ref = $m.Groups[1].Value
            if (-not $vcpkgEnvValues.Contains($ref) -and $customVarNames -notcontains $ref -and
                -not (Test-EnvFileDefines -Path $envFilePath -Name $ref))
            {
                Write-Error ("environment.custom_variables: '{0}' references `${{{1}}}, which nothing defines yet. Variables are expanded in order, so it must be a drive/MSYS2 variable from an earlier step or an earlier entry of custom_variables." -f $name, $ref)
                Abort-WithError
            }
        }

        $vcpkgEnvValues[$name] = $value
        $customVarNames += $name
    }
}

$customPathEntries = @()
foreach ($entry in @($Cfg.environment.custom_path_entries))
{
    $entry = ([string]$entry).Trim()
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    $customPathEntries += $entry
}

# Same for the custom PATH entries: an empty component would let the current directory shadow gcc, make or ninja.
# Only custom entries are checked; VCPKG_BIN and BASE_PATH are the generator's own.
$definedKeys = @($vcpkgEnvValues.Keys) + @("BASE_PATH")
if (Test-Path -LiteralPath $envFilePath)
{
    foreach ($raw in (Get-Content -LiteralPath $envFilePath -Encoding UTF8))
    {
        $idx = ([string]$raw).IndexOf("=")
        if ($idx -gt 0) { $definedKeys += ([string]$raw).Substring(0, $idx).Trim() }
    }
}

foreach ($part in $customPathEntries)
{
    foreach ($m in [regex]::Matches($part, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}'))
    {
        $ref = $m.Groups[1].Value
        if ($definedKeys -notcontains $ref)
        {
            Write-Error ("environment.custom_path_entries references `${{{0}}}, which nothing defines. Add {0} to environment.custom_variables, or use a literal path instead." -f $ref)
            Abort-WithError
        }
    }
}

$pathParts = @('${VCPKG_BIN}', '${VCPKG_ROOT}') + $customPathEntries + @('${BASE_PATH}')

# ${VCPKG_ROOT} carries vcpkg.exe itself, which the previous composition omitted: the tool was reachable only because
# someone had hand-edited the generated file. Everything is prepended ahead of BASE_PATH so the environment's own
# toolchain and packages win over anything inherited.
$vcpkgEnvValues["PATH"] = ($pathParts -join ':')

foreach ($key in $vcpkgEnvValues.Keys)
{
    Write-Info ("{0}={1}" -f $key, $vcpkgEnvValues[$key])
}

Write-Info "Updating environment variables in $envFilePath"
Set-DrivEnvFileValues -Path $envFilePath -Values $vcpkgEnvValues -Section "vcpkg"

Write-Info "STEP 9: OK"

# FINALIZATION
# --------------------------------------------------------------------

$scriptEnd = Get-Date
$elapsed = $scriptEnd - $scriptStart
$elapsedStr = ("{0:hh\:mm\:ss}" -f $elapsed)

Write-Info "VCPKG clone setup completed successfully."
Write-Info "Next step: 4-Deps_VCPKG.ps1 (installs the ports listed in vcpkg.packages)."
Write-Info "TOTAL EXECUTION TIME: $($elapsed.TotalSeconds) seconds  ($elapsedStr)"

# ABOVE the prompt below, not after it: UserInteractive is True even with stdin redirected, and ReadKey then
# throws instead of waiting -- the trap Abort-WithError already documents. Anything after the prompt is
# skipped in precisely the non-interactive case where this copy is the only record anybody will have.
if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }

# The SAME guard as Abort-WithError, and for the same measured reason: UserInteractive is True even with
# stdin redirected, and ReadKey then THROWS instead of waiting. Unguarded, a step that did everything it
# was asked to would die here on its very last statement and report failure to whatever drove it.
if ([Environment]::UserInteractive -and -not [System.Console]::IsInputRedirected) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
}
$host.UI.RawUI.WindowTitle = $originalTitle

# --------------------------------------------------------------------
