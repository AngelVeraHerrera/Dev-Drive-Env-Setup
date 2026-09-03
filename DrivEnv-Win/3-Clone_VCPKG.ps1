# ====================================================================
# VCPKG CLONE SETUP SCRIPT
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
#          David Abuin Sanchez
# Updated: 26/08/2026
# Version: 1.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Prerequisites: 1-Setup_DevDrive.ps1 and 2-Setup_MSYS2.ps1 must have
# completed. This script reads the environment file they produced
# (<drive>:\env\<dev_env_name>_env_variables.env) as the source of truth
# for the MSYS2 layout instead of re-deriving it from convention.
#
# ====================================================================

# FUNCTIONS
# --------------------------------------------------------------------

param
(
    # @brief Path to the JSON configuration driving this run.
    #
    # A bare file name or a relative path resolves against THIS SCRIPT'S directory, so the common case -- a config
    # sitting beside the scripts -- needs no path at all. An absolute path is taken as given, which is what lets a
    # config live outside the repository. Omit it entirely for the generic configuration.
    #
    # All four scripts take the same switch and must be given the SAME file: they hand state to each other through
    # the generated .env on the dev drive, and mixing configs between steps produces an environment that matches
    # neither.
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief Validate the configuration and stop, changing nothing.
    #
    # The validation runs on every invocation regardless; this switch only stops the script afterwards. Useful for
    # checking an edited configuration in a second, and for checking one BEFORE a step that takes an hour.
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

    # UserInteractive alone is NOT enough. It reports True for any process in a normal user session, including one
    # launched from another script with its input redirected -- and there ReadKey THROWS instead of waiting, so the
    # lines below never run: the window title is left changed and the deliberate `exit 1` becomes an unhandled
    # PowerShell error. Verified on this machine: UserInteractive=True with stdin redirected, ReadKey throws.
    if ([Environment]::UserInteractive -and -not [System.Console]::IsInputRedirected) {
        Write-Host ""
        Write-Host "Press any key to exit..."
        [void][System.Console]::ReadKey($true)
    }

    if ($originalTitle) { $host.UI.RawUI.WindowTitle = $originalTitle }
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

    foreach ($raw in (Get-Content -LiteralPath $Path))
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

function Set-EnvFileValues
{
    # @brief Idempotently write KEY=VALUE entries: existing lines for the managed keys are
    #        dropped and the new block is appended, so re-running never duplicates entries.
    param
    (
        [string]$Path,
                $Values
    )

    $kept = @()
    if (Test-Path -LiteralPath $Path)
    {
        foreach ($raw in (Get-Content -LiteralPath $Path))
        {
            $line = [string]$raw
            $idx  = $line.IndexOf("=")
            if ($idx -gt 0)
            {
                $key = $line.Substring(0, $idx).Trim()
                if ($Values.Contains($key)) { continue }
            }
            $kept += $line
        }
    }

    $out = @()
    $out += $kept
    foreach ($key in $Values.Keys) { $out += ("{0}={1}" -f $key, $Values[$key]) }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir))
    {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $out, $utf8NoBom)
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
    foreach ($raw in (Get-Content -LiteralPath $Path))
    {
        $line = [string]$raw
        $idx  = $line.IndexOf("=")
        if ($idx -gt 0 -and $line.Substring(0, $idx).Trim() -eq $Name) { return $true }
    }
    return $false
}

function Get-TextFileHash
{
    # @brief SHA256 of a TEXT file's content, with line endings normalised to LF and any BOM removed first.
    #
    # Not Get-FileHash, and the difference is not academic. The triplets are text files living in a git repository,
    # and git is allowed to rewrite their line endings on checkout: with core.autocrlf=true -- the Windows default,
    # and what a normal clone of this repository uses -- a file stored with LF arrives on disk with CRLF. A hash of
    # the raw bytes therefore measures the developer's git configuration rather than the file's content, and the
    # integrity check fails on a machine that did nothing wrong.
    #
    # That is not hypothetical. A hash generated here over the LF working copy
    #     910B5E890CD9F3D351E8BF44511B340E91792A822F75A816375B5BEF1EC4608F
    # failed on a second machine holding the byte-identical file as CRLF
    #     8BAE34F2C2C33567A6166ED63C0C1F18492B634A60C33CAD71C8FA37C2A0DEC2
    # and regenerating it there fixed it there and broke it here. A check that ping-pongs between machines is worse
    # than no check, because the first thing anybody learns is to regenerate the hash without reading the file.
    #
    # Line endings do not change a single thing CMake reads, so CONTENT is the right thing to hash. Byte stability
    # is separately protected by .gitattributes, which marks these files -text so git stops touching them; this
    # function is what makes the check survive a clone that predates that, or a working copy converted by hand.
    param ([string]$Path)

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text = $text -replace "`r`n", "`n"

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try   { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) }
    finally { $sha.Dispose() }

    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToUpperInvariant()
}

function Resolve-GitExecutable
{
    # @brief Locate git.exe inside the generated MSYS2 installation.
    #
    # Step 2 installs the MinGW flavour of git (mingw-w64-<profile>-<arch>-git), which lands in
    # <MINGW_ROOT>\bin, not in <MSYS2_ROOT>\usr\bin. The plain MSYS package would land in usr\bin.
    # Both layouts are accepted, and the login shell is used as a last resort so a different
    # profile (mingw64, clang64, ...) still resolves.
    param
    (
        [string]$MingwRoot,
        [string]$Msys2Root,
        [string]$BashPath
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($MingwRoot)) { $candidates += (Join-Path (Convert-ToWinPath $MingwRoot) "bin\git.exe") }
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

# A relative -ConfigFile is relative to the script, not to the caller's working directory: these scripts are
# routinely launched by double-click and from elsewhere, and resolving against the cwd would silently pick a
# different config depending on where the shell happened to be.
$ConfigPath = if ([System.IO.Path]::IsPathRooted($ConfigFile))
{
    $ConfigFile
}
else
{
    Join-Path $PSScriptRoot $ConfigFile
}

if (-not (Test-Path $ConfigPath))
{
    Write-Error "Configuration file missing: $ConfigPath"
    Abort-WithError
}

try
{
    $Cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
}
catch
{
    Write-Error "Invalid JSON in $ConfigPath"
    Abort-WithError
}

# Validate the whole configuration before anything reads a value out of it. An unknown key is an ERROR here rather
# than a silent fall-back to a default; the head of DrivEnvConfig.ps1 explains why that distinction earns a file.
. (Join-Path $PSScriptRoot "DrivEnvConfig.ps1")

$cfgProblems = @(Test-DrivEnvConfig -Config $Cfg)
if ($cfgProblems.Count -gt 0)
{
    Write-Error ("Configuration has {0} problem(s): {1}" -f $cfgProblems.Count, $ConfigPath)
    foreach ($cfgProblem in $cfgProblems) { Write-Error "    $cfgProblem" }
    Abort-WithError
}

Write-Info "Configuration validated against the schema: no problems."

if ($ValidateOnly)
{
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

# Environment file written by steps 1 and 2 (single source of truth for the MSYS2 layout)
$envFilePath = Join-Path "$driveLetter`:" (("env/{0}_env_variables.env" -f $devEnvName).ToLower())

# INITIAL PREPARATION
# --------------------------------------------------------------------

$scriptStart = Get-Date
$scriptDir   = Get-ScriptDirectory

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir = Join-Path $scriptDir "install_logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile = Join-Path $logsDir "${timestamp}_vcpkg-clone-setup.log"
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
Write-NoFormat "  Updated: 19/08/2026"
Write-NoFormat "  Version: 1.0.0"
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
# NO ELEVATION IS REQUIRED HERE, and demanding it was a mistake inherited from step 1. This block used to abort
# unless the shell was already elevated, which sent people to reopen an Administrator terminal for no reason.
#
# This step writes to the dev drive and to the user's TEMP, and nothing else: no services, no registry, no machine
# environment variables, no VHD, no Defender exclusions, no scheduled tasks. Step 1 needs administrator rights
# because it creates and formats a volume; this one needs only a volume that already exists. The drive root carries
# the stock "Authenticated Users: Modify" ACE, inherited by everything on it, so an ordinary user can do all of it.
# Steps 2, 5 and 6 never had the check and have always worked -- step 6 clones repositories onto the same drive
# unelevated.
#
# Running elevated is WORSE than unnecessary: every directory vcpkg creates -- buildtrees, packages, installed,
# downloads -- ends up owned by BUILTIN\Administrators rather than by the person who will build against it.
if (Test-IsAdministrator)
{
    Write-Warn "Running elevated. Nothing in this step needs it, and it leaves the vcpkg tree owned by"
    Write-Warn "Administrators rather than by you. An ordinary terminal is the better choice for steps 2 to 6."
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
    Write-Error "Run 1-Setup_DevDrive.ps1 and 2-Setup_MSYS2.ps1 before this script."
    Abort-WithError
}

$envMap = Read-EnvFile $envFilePath

$msys2Root = [string]$envMap["MSYS2_ROOT"]
$mingwRoot = [string]$envMap["MINGW_ROOT"]
$msys2Bash = [string]$envMap["MSYS2_BASH"]
$msys2Env  = [string]$envMap["MSYS2_ENV"]

# Fall back to the layout conventions of step 2 if the file predates them.
if ([string]::IsNullOrWhiteSpace($msys2Root))
{
    $msys2Root = "{0}:/msys64" -f $driveLetter
    Write-Warn "MSYS2_ROOT missing from the environment file, assuming: $msys2Root"
}
if ([string]::IsNullOrWhiteSpace($msys2Env))
{
    $msys2Env = "{0}64" -f ([string]$Cfg.msys2.target.profile)
    Write-Warn "MSYS2_ENV missing from the environment file, assuming: $msys2Env"
}
if ([string]::IsNullOrWhiteSpace($mingwRoot))
{
    $mingwRoot = "{0}/{1}" -f $msys2Root, $msys2Env
    Write-Warn "MINGW_ROOT missing from the environment file, assuming: $mingwRoot"
}
if ([string]::IsNullOrWhiteSpace($msys2Bash))
{
    $msys2Bash = "{0}/usr/bin/bash.exe" -f $msys2Root
    Write-Warn "MSYS2_BASH missing from the environment file, assuming: $msys2Bash"
}

$msys2RootWin = Convert-ToWinPath $msys2Root
$mingwRootWin = Convert-ToWinPath $mingwRoot
$msys2BashWin = Convert-ToWinPath $msys2Bash

Write-Info "MSYS2_ROOT = $msys2RootWin"
Write-Info "MINGW_ROOT = $mingwRootWin"
Write-Info "MSYS2_ENV  = $msys2Env"

Write-Info "Checking if msys2 bash exists..."
if (-not (Test-Path -LiteralPath $msys2BashWin))
{
    Write-Error "Bash not found at expected MSYS2 path: $msys2BashWin"
    Write-Error "Run 2-Setup_MSYS2.ps1 before this script."
    Abort-WithError
}

Write-Info "Checking if git tool exists..."
$gitExe = Resolve-GitExecutable -MingwRoot $mingwRoot -Msys2Root $msys2Root -BashPath $msys2BashWin
if (-not $gitExe)
{
    Write-Error "Git was not found inside the generated MSYS2 installation."
    Write-Error "Looked under '$mingwRootWin\bin' and '$msys2RootWin\usr\bin', and asked the MSYS2 login shell."
    Write-Error "Re-run 2-Setup_MSYS2.ps1, which installs the git package."
    Abort-WithError
}

# MSYS2 runtime DLLs must be reachable for git and its helper processes.
$env:PATH = "{0}\bin;{1}\usr\bin;{2}" -f $mingwRootWin, $msys2RootWin, $env:PATH

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

if ($baselineMode -eq "fixed")
{
    $vcpkgBaseline = $baselineFixed
    Write-Info "Baseline mode 'fixed': using configured commit $vcpkgBaseline"
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

$dirty = Get-NativeOutput $gitExe @("-C", $vcpkgRootWin, "status", "--porcelain")
if ($dirty.ExitCode -eq 0 -and $dirty.Output.Count -gt 0)
{
    Write-Warn "The vcpkg work tree has local modifications; the checkout may fail."
    foreach ($line in $dirty.Output) { Write-Warn ("    | " + $line) }
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

# STEP 5: Bootstrap vcpkg.
# --------------------------------------------------------------------

Write-Info "STEP 5: Bootstrap vcpkg."

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

Write-Info "STEP 5: OK"

# STEP 6: Install the controlled overlay triplet.
# --------------------------------------------------------------------

Write-Info "STEP 6: Install the controlled overlay triplet '$vcpkgTriplet'."

$tripletFileName = "{0}.cmake"  -f $vcpkgTriplet
$tripletHashName = "{0}.sha256" -f $vcpkgTriplet

$tripletSrc     = Join-Path $scriptDir ("vcpkg_overlays\triplets\{0}" -f $tripletFileName)
$tripletHashSrc = Join-Path $scriptDir ("vcpkg_overlays\triplets\{0}" -f $tripletHashName)
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

# Every OTHER triplet in the overlay directory is installed as well, verified the same way. Only the CONFIGURED one
# is mandatory; the rest are alternatives, and installing them costs nothing but makes them usable without copying a
# file by hand.
#
# x64-mingw-ucrt-static-release is the one alternative that exists today. Nothing in vcpkg.packages uses it -- this
# environment is dynamic throughout -- and it is kept as a capability, for the case where a whole dependency closure
# has to be static and a separate installed tree is acceptable. It earned its place on a real problem: Fast DDS on
# MinGW builds a DLL that does not export the vtable of TypeSupport, so nothing defining a DDS type can link it.
# That turned out to be better solved per-port than per-triplet, and Fast DDS is no longer installed here at all --
# see installation/vcpkg_overlays.txt, section DEFERRED, which keeps the whole diagnosis for when DDS returns.
#
# Before this, a triplet that was not the configured one sat in the repository and never reached the drive, so using
# it meant copying a file by hand and remembering why.
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

Write-Info "STEP 6: OK"

# STEP 7: Install the controlled overlay ports.
# --------------------------------------------------------------------

Write-Info "STEP 7: Install the controlled overlay ports."

# OVERLAY PORTS ARE LAYERED, and every layer any triplet asks for is installed here.
#
# A layer is a directory of ports. vcpkg searches the layers a port's triplet declares IN ORDER and takes the
# first that contains the port, so a specific layer can override the shared one. The point of that is a future
# environment holding BOTH a GCC and a clang triplet in one vcpkg tree: the overlay path is not a property of
# the tree, it is chosen per invocation, and step 4 invokes vcpkg once per port -- so the layers can differ by
# triplet without the two treading on each other.
#
# "ports" is always installed even when no configuration mentions it, because it is the shared layer everything
# falls back to and an environment without it has no overlays at all.
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

        # A layer name is a single directory under vcpkg_overlays, not a path: anything else would let a
        # configuration reach outside the repository, and the reconcile below deletes whatever it finds in the
        # destination.
        if ($trimmedLayer -match '[\\/]' -or $trimmedLayer -match '\.\.')
        {
            Write-Error "vcpkg.overlay_ports: '$trimmedLayer' must be a single directory name under vcpkg_overlays."
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
    $layerSrc = Join-Path $scriptDir ("vcpkg_overlays\{0}" -f $layerName)
    $layerDst = Join-Path $overlayRootWin $layerName

    if (-not (Test-Path -LiteralPath $layerSrc))
    {
        if ($layerName -eq "ports")
        {
            Write-Error "Overlay ports source not found: $layerSrc"
            Abort-WithError
        }

        # A named layer that does not exist in the repository is a configuration error, not an empty layer:
        # silently treating it as empty would mean a port the configuration expects to be overridden quietly
        # comes from upstream instead.
        Write-Error "vcpkg.overlay_ports names layer '$layerName', but $layerSrc does not exist."
        Abort-WithError
    }

    if (-not (Test-Path -LiteralPath $layerDst))
    {
        New-Item -ItemType Directory -Path $layerDst -Force | Out-Null
        Write-Info "Created overlay layer directory: $layerDst"
    }

    $srcPortDirs = @(Get-ChildItem -LiteralPath $layerSrc -Directory)

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

Write-Info "STEP 7: OK"

# STEP 8: Setup environment variables.
# --------------------------------------------------------------------

Write-Info "STEP 8: Setup environment variables."

if (-not (Test-Path -LiteralPath $binaryCacheWin))
{
    New-Item -ItemType Directory -Path $binaryCacheWin -Force | Out-Null
    Write-Info "Created vcpkg binary cache directory: $binaryCacheWin"
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
}

# -- Custom variables and custom PATH entries -------------------------------------------------------------------------
#
# Two separate knobs, on purpose:
#
#   environment.custom_variables    -> extra KEY=VALUE lines. Some tools want a variable and nothing more (CMake
#                                      finding CUDA, a vendor SDK root), so being on PATH is not implied.
#   environment.custom_path_entries -> extra PATH components, in the order given. Each may be a literal path or a
#                                      ${REFERENCE} to a variable above, which is why they are written first.
#
# They are emitted HERE, in step 3, rather than in step 2, because PATH has to be the last assignment in the file and
# every reference it makes must already be defined: the launcher bootstrap expands ${...} line by line against what
# it has exported so far, so a forward reference silently yields an empty component -- and an empty PATH component
# means "the current directory" to both execvp and bash, which is a real shadowing hazard.
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

        # Every ${REFERENCE} a custom VALUE makes must already be defined, for the same reason the PATH entries
        # below are checked: the launcher expands line by line, so a forward reference or a typo yields the EMPTY
        # STRING and the variable is silently wrong rather than absent. GST_PLUGIN_PATH is the cautionary case --
        # empty means "find no plugins at all", and what the user then sees is a gstreamer that appears to have been
        # built without any.
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

# Every ${REFERENCE} a custom entry makes must resolve, or the component expands to the EMPTY STRING -- and an empty
# PATH component means "the current directory" to execvp and to bash. A typo in a hand-edited config would therefore
# let whatever directory you happen to cd into shadow gcc, make or ninja.
#
# Only the CUSTOM entries are checked. VCPKG_BIN comes from the block above and BASE_PATH is step 2's contract, so
# validating those here would just report the harness's own components -- and would fire spuriously the first time a
# fresh .env has not been written yet.
$definedKeys = @($vcpkgEnvValues.Keys) + @("BASE_PATH")
if (Test-Path -LiteralPath $envFilePath)
{
    foreach ($raw in (Get-Content -LiteralPath $envFilePath))
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
Set-EnvFileValues -Path $envFilePath -Values $vcpkgEnvValues

Write-Info "STEP 8: OK"

# FINALIZATION
# --------------------------------------------------------------------

$scriptEnd = Get-Date
$elapsed = $scriptEnd - $scriptStart
$elapsedStr = ("{0:hh\:mm\:ss}" -f $elapsed)

Write-Info "VCPKG clone setup completed successfully."
Write-Info "Next step: 4-Deps_VCPKG.ps1 (installs the ports listed in vcpkg.packages)."
Write-Info "TOTAL EXECUTION TIME: $($elapsed.TotalSeconds) seconds  ($elapsedStr)"

if ([Environment]::UserInteractive) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
}
$host.UI.RawUI.WindowTitle = $originalTitle

# --------------------------------------------------------------------
