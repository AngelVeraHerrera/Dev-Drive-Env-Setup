# ====================================================================
# VCPKG DEPENDENCIES SETUP SCRIPT
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
#          David Abuin Sanchez
# Updated: 19/08/2026
# Version: 1.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Prerequisites: 1-Setup_DevDrive.ps1, 2-Setup_MSYS2.ps1 and
# 3-Clone_VCPKG.ps1 must have completed.
#
# Installation model: vcpkg CLASSIC mode. Ports are installed once into
# <VCPKG_ROOT>\installed and shared by every project on the dev drive,
# which is what the generated environment (VCPKG_ROOT / VCPKG_BIN on the
# PATH) exposes. A reference manifest is also emitted under <drive>:\env
# so the environment can be migrated to vcpkg manifest mode later without
# re-authoring the configuration.
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
    #        (e.g. "X:\vcpkg" -> "X:/vcpkg"). This form is what vcpkg.exe itself expects.
    return ([string]$winPath) -replace '\\', '/'
}

function Convert-ToWinPath($anyPath)
{
    return ([string]$anyPath) -replace '/', '\'
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

function New-Msys2ScriptHeader
{
    # @brief Common preamble entering the MSYS2 target environment and exporting the vcpkg
    #        variables in Windows drive form, which is what vcpkg.exe needs.
    #
    # The variables are exported here rather than sourced from the .env file on purpose: the
    # launcher bootstrap converts drive paths to POSIX form when it loads that file, which is
    # right for an interactive shell but wrong for a native Windows binary such as vcpkg.exe.
    param
    (
        [string]$Msys2Env,
        [string]$VcpkgRootDrive,
        [string]$VcpkgRootUnix,
        [string]$Triplet,
        [string]$OverlayPorts,
        [string]$OverlayTriplets,
        [string]$BinaryCache
    )

    $msysEnvUpper = $Msys2Env.ToUpperInvariant()

    # NOTE: 'set -e' must NOT be active while the target environment is entered. The MSYS2
    # 'shell' helper (and /etc/profile) return a non-zero status internally, which under
    # 'set -e' aborts the whole script silently, with no output and exit code 1. The
    # environment is therefore validated explicitly instead.
    return @"
if command -v shell >/dev/null 2>&1; then
    source shell $Msys2Env || true
else
    export MSYSTEM=$msysEnvUpper
    source /etc/profile || true
fi

if [ "`$MSYSTEM" != "$msysEnvUpper" ]; then
    echo "[env] ERROR: failed to enter the $msysEnvUpper environment (MSYSTEM='`$MSYSTEM')" >&2
    exit 1
fi

export VCPKG_ROOT='$VcpkgRootDrive'
export VCPKG_DEFAULT_TRIPLET='$Triplet'
export VCPKG_DEFAULT_HOST_TRIPLET='$Triplet'
export VCPKG_OVERLAY_PORTS='$OverlayPorts'
export VCPKG_OVERLAY_TRIPLETS='$OverlayTriplets'
export VCPKG_DEFAULT_BINARY_CACHE='$BinaryCache'
export VCPKG_DISABLE_METRICS=1

cd '$VcpkgRootUnix' || { echo "[env] ERROR: cannot enter '$VcpkgRootUnix'" >&2; exit 1; }

if [ ! -x ./vcpkg ] && [ ! -f ./vcpkg.exe ]; then
    echo "[env] ERROR: no vcpkg executable in '$VcpkgRootUnix'" >&2
    exit 1
fi

echo "[env] MSYSTEM=`$MSYSTEM"
echo "[env] PWD=`$(pwd)"
echo "[env] VCPKG_DEFAULT_TRIPLET=`$VCPKG_DEFAULT_TRIPLET"
"@
}

function Invoke-Msys2Script
{
    # @brief Run a bash script inside the MSYS2 login shell, mirroring its output into the log.
    #        Returns the exit code of the script itself (no tee, so the code is not masked).
    param
    (
        [string]$BashPath,
        [string]$ScriptBody,
        [string]$TempName
    )

    $tempScript = Join-Path $env:TEMP $TempName
    $utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempScript, ($ScriptBody -replace "`r`n", "`n"), $utf8NoBom)

    $tempScriptUnix = Convert-ToMSYSPath $tempScript

    try
    {
        & $BashPath -lc "bash '$tempScriptUnix'" 2>&1 | ForEach-Object { Write-NoFormat ("    | " + $_) }
        return $LASTEXITCODE
    }
    finally
    {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Get-Msys2ScriptOutput
{
    # @brief Same as Invoke-Msys2Script but captures the output instead of logging it.
    param
    (
        [string]$BashPath,
        [string]$ScriptBody,
        [string]$TempName
    )

    $tempScript = Join-Path $env:TEMP $TempName
    $utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempScript, ($ScriptBody -replace "`r`n", "`n"), $utf8NoBom)

    $tempScriptUnix = Convert-ToMSYSPath $tempScript

    try
    {
        $out = & $BashPath -lc "bash '$tempScriptUnix'" 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = @($out) }
    }
    finally
    {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-ManifestName
{
    # @brief Turn the dev environment name into a valid vcpkg manifest name
    #        (lowercase, alphanumeric and hyphens only).
    param ([string]$Name)

    $slug = ([string]$Name).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = "devsystem" }
    return "$slug-env"
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
if (-not $Cfg.environment)  { Write-Error "Missing 'environment' object in config JSON: $ConfigPath"; Abort-WithError }
if (-not $Cfg.vcpkg)        { Write-Error "Missing 'vcpkg' object in config JSON: $ConfigPath";       Abort-WithError }
if (-not $Cfg.vcpkg.target) { Write-Error "Missing 'vcpkg.target' object in config JSON: $ConfigPath";Abort-WithError }

if (-not $Cfg.vcpkg.packages)
{
    Write-Error "Missing 'vcpkg.packages' array in config JSON: $ConfigPath"
    Write-Error "Add at least one entry, for example: { `"name`": `"fmt`" }"
    Abort-WithError
}

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

# VCPKG packages section
$vcpkgPackages = @($Cfg.vcpkg.packages)

if ($vcpkgPackages.Count -eq 0)
{
    Write-Error "'vcpkg.packages' is empty in config JSON: $ConfigPath"
    Abort-WithError
}

$portSpecs = @()
$portNames = @()

foreach ($p in $vcpkgPackages)
{
    $pName = [string]$p.name

    if ([string]::IsNullOrWhiteSpace($pName))
    {
        Write-Error "Invalid vcpkg.packages entry: missing 'name'"
        Abort-WithError
    }

    $pName = $pName.Trim()
    if ($pName -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$')
    {
        Write-Error ("Invalid vcpkg port name '{0}' (expected lowercase letters, digits, '.' and '-')" -f $pName)
        Abort-WithError
    }

    if ($portNames -contains $pName)
    {
        Write-Error ("Duplicated vcpkg port in configuration: '{0}'" -f $pName)
        Abort-WithError
    }

    $pFeatures = @()
    if ($p.PSObject.Properties.Name -contains "features")
    {
        foreach ($f in @($p.features))
        {
            $fName = ([string]$f).Trim()
            if ([string]::IsNullOrWhiteSpace($fName))
            {
                Write-Error ("Invalid empty feature in vcpkg.packages entry '{0}'" -f $pName)
                Abort-WithError
            }
            if ($fName -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$')
            {
                Write-Error ("Invalid feature name '{0}' in vcpkg.packages entry '{1}'" -f $fName, $pName)
                Abort-WithError
            }
            $pFeatures += $fName
        }
    }

    if ($pFeatures.Count -gt 0) { $spec = "{0}[{1}]" -f $pName, ($pFeatures -join ",") }
    else                        { $spec = $pName }

    $portNames += $pName
    $portSpecs += @{ Name = $pName; Features = $pFeatures; Spec = $spec }
}

# Dev drive layout (must match the layout written by 3-Clone_VCPKG.ps1)
$vcpkgRootWin       = Join-Path $devDrive "vcpkg"
$overlayPortsWin    = Join-Path $devDrive "overlays\ports"
$overlayTripletsWin = Join-Path $devDrive "overlays\triplets"
$binaryCacheWin     = Join-Path $devDrive "packages\vcpkg"
$vcpkgExeWin        = Join-Path $vcpkgRootWin "vcpkg.exe"

$envFilePath  = Join-Path "$driveLetter`:" (("env/{0}_env_variables.env" -f $devEnvName).ToLower())
$manifestPath = Join-Path "$driveLetter`:" (("env/{0}_vcpkg_reference.json" -f $devEnvName).ToLower())

# INITIAL PREPARATION
# --------------------------------------------------------------------

$scriptStart = Get-Date
$scriptDir   = Get-ScriptDirectory

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir = Join-Path $scriptDir "install_logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile = Join-Path $logsDir "${timestamp}_vcpkg-deps-setup.log"
$globalLogFileUnix = Convert-ToMSYSPath $globalLogFile

$originalTitle = $host.UI.RawUI.WindowTitle
$host.UI.RawUI.WindowTitle = "GENERIC VCPKG DEPS SETUP SCRIPT"

# SCRIPT STARTUP HEADER
# --------------------------------------------------------------------

Write-NoFormat "================================================================="
Write-NoFormat "  VCPKG DEPENDENCIES SETUP SCRIPT"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "  Authors: Angel Vera Herrera"
Write-NoFormat "           David Abuin Sanchez"
Write-NoFormat "  Updated: 19/08/2026"
Write-NoFormat "  Version: 1.0.0"
Write-NoFormat "================================================================="
Write-NoFormat "Parameters (Loaded from JSON):"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "Drive Letter  = $devDrive"
Write-NoFormat "Dev Env Name  = $devEnvName"
Write-NoFormat "Env File      = $envFilePath"
Write-NoFormat "VCPKG Root    = $vcpkgRootWin"
Write-NoFormat "VCPKG Triplet = $vcpkgTriplet"
Write-NoFormat "Install Mode  = classic"
Write-NoFormat "Ports         = $($portSpecs.Count)"
Write-NoFormat "-----------------------------------------------------------------"
foreach ($port in $portSpecs) { Write-NoFormat ("  - " + $port.Spec) }
Write-NoFormat "================================================================="

# STEP 1: Initial checks and preparations.
# --------------------------------------------------------------------

Write-Info "STEP 1: Initial checks and preparations."

Write-Info "Checking permissions..."
if (-not (Test-IsAdministrator))
{
    Write-Error "This script must be run as Administrator."
    Abort-WithError
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
    Write-Error "Run steps 1 to 3 before this script."
    Abort-WithError
}

$envMap = Read-EnvFile $envFilePath

$msys2Root = [string]$envMap["MSYS2_ROOT"]
$mingwRoot = [string]$envMap["MINGW_ROOT"]
$msys2Bash = [string]$envMap["MSYS2_BASH"]
$msys2Env  = [string]$envMap["MSYS2_ENV"]

if ([string]::IsNullOrWhiteSpace($msys2Root) -or [string]::IsNullOrWhiteSpace($msys2Bash) -or [string]::IsNullOrWhiteSpace($msys2Env))
{
    Write-Error "The environment file does not describe a complete MSYS2 installation: $envFilePath"
    Write-Error "Expected MSYS2_ROOT, MSYS2_BASH and MSYS2_ENV. Re-run 2-Setup_MSYS2.ps1."
    Abort-WithError
}

$msys2RootWin = Convert-ToWinPath $msys2Root
$msys2BashWin = Convert-ToWinPath $msys2Bash

Write-Info "MSYS2_ROOT = $msys2RootWin"
Write-Info "MSYS2_ENV  = $msys2Env"

if (-not (Test-Path -LiteralPath $msys2BashWin))
{
    Write-Error "Bash not found at expected MSYS2 path: $msys2BashWin"
    Write-Error "Run 2-Setup_MSYS2.ps1 before this script."
    Abort-WithError
}

# The clone step must have run: it is what creates the repository, the overlays and the
# VCPKG_* entries in the environment file.
Write-Info "Checking the vcpkg clone step..."

if (-not (Test-Path -LiteralPath (Join-Path $vcpkgRootWin ".git")))
{
    Write-Error "No vcpkg repository found at: $vcpkgRootWin"
    Write-Error "Run 3-Clone_VCPKG.ps1 before this script."
    Abort-WithError
}

$envTriplet = [string]$envMap["VCPKG_DEFAULT_TRIPLET"]
if ([string]::IsNullOrWhiteSpace($envTriplet))
{
    Write-Error "VCPKG_DEFAULT_TRIPLET is missing from: $envFilePath"
    Write-Error "Run 3-Clone_VCPKG.ps1 before this script."
    Abort-WithError
}

if ($envTriplet -ne $vcpkgTriplet)
{
    Write-Error "Triplet mismatch between the configuration and the generated environment."
    Write-Error "  Configuration (vcpkg.target.triplet) : $vcpkgTriplet"
    Write-Error "  Environment   (VCPKG_DEFAULT_TRIPLET): $envTriplet"
    Write-Error "Re-run 3-Clone_VCPKG.ps1 to apply the configured triplet."
    Abort-WithError
}

$tripletFileWin = Join-Path $overlayTripletsWin ("{0}.cmake" -f $vcpkgTriplet)
if (-not (Test-Path -LiteralPath $tripletFileWin))
{
    Write-Error "Overlay triplet not installed: $tripletFileWin"
    Write-Error "Run 3-Clone_VCPKG.ps1 before this script."
    Abort-WithError
}

if (-not (Test-Path -LiteralPath $overlayPortsWin))
{
    Write-Error "Overlay ports directory not installed: $overlayPortsWin"
    Write-Error "Run 3-Clone_VCPKG.ps1 before this script."
    Abort-WithError
}

if (-not (Test-Path -LiteralPath $binaryCacheWin))
{
    New-Item -ItemType Directory -Path $binaryCacheWin -Force | Out-Null
    Write-Info "Created vcpkg binary cache directory: $binaryCacheWin"
}

Write-Info "STEP 1: OK"

# STEP 2: Ensure the vcpkg executable is available.
# --------------------------------------------------------------------

Write-Info "STEP 2: Ensure the vcpkg executable is available."

if (Test-Path -LiteralPath $vcpkgExeWin)
{
    Write-Info "vcpkg.exe found at: $vcpkgExeWin"
}
else
{
    Write-Warn "vcpkg.exe not found at '$vcpkgExeWin'. Bootstrapping the existing clone..."

    $bootstrapBat = Join-Path $vcpkgRootWin "bootstrap-vcpkg.bat"
    if (-not (Test-Path -LiteralPath $bootstrapBat))
    {
        Write-Error "Bootstrap script not found: $bootstrapBat"
        Write-Error "The vcpkg clone looks incomplete. Re-run 3-Clone_VCPKG.ps1."
        Abort-WithError
    }

    Push-Location -LiteralPath $vcpkgRootWin
    try
    {
        & $bootstrapBat "-disableMetrics" 2>&1 | ForEach-Object { Write-NoFormat ("    | " + $_) }
        $code = $LASTEXITCODE
    }
    finally
    {
        Pop-Location
    }

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

Write-Info "STEP 2: OK"

# STEP 3: Install the configured ports.
# --------------------------------------------------------------------

Write-Info "STEP 3: Install the configured ports with triplet '$vcpkgTriplet'."

$vcpkgRootDrive       = Convert-ToDriveStylePath $vcpkgRootWin
$vcpkgRootUnix        = Convert-ToMSYSPath       $vcpkgRootWin
$overlayPortsDrive    = Convert-ToDriveStylePath $overlayPortsWin
$overlayTripletsDrive = Convert-ToDriveStylePath $overlayTripletsWin
$binaryCacheDrive     = Convert-ToDriveStylePath $binaryCacheWin

$scriptHeader = New-Msys2ScriptHeader -Msys2Env        $msys2Env `
                                      -VcpkgRootDrive  $vcpkgRootDrive `
                                      -VcpkgRootUnix   $vcpkgRootUnix `
                                      -Triplet         $vcpkgTriplet `
                                      -OverlayPorts    $overlayPortsDrive `
                                      -OverlayTriplets $overlayTripletsDrive `
                                      -BinaryCache     $binaryCacheDrive

$index = 0
foreach ($port in $portSpecs)
{
    $index++
    Write-Info ("Installing port {0}/{1}: '{2}'..." -f $index, $portSpecs.Count, $port.Spec)

    $installScript = $scriptHeader + @"

./vcpkg install '$($port.Spec)' --triplet '$vcpkgTriplet' --host-triplet '$vcpkgTriplet'
"@

    $tempName = "vcpkg_install_{0}.sh" -f ($port.Name -replace '[^A-Za-z0-9]', '_')
    $code = Invoke-Msys2Script -BashPath $msys2BashWin -ScriptBody $installScript -TempName $tempName

    if ($code -ne 0)
    {
        Write-Error "Installation of '$($port.Spec)' failed (ExitCode=$code)."
        Write-Error "See the full build output in: $globalLogFile"
        Abort-WithError
    }

    Write-Info "'$($port.Spec)' installed successfully."
}

Write-Info "STEP 3: OK"

# STEP 4: Verify the installed ports.
# --------------------------------------------------------------------

Write-Info "STEP 4: Verify the installed ports."

# --x-json, not the plain listing, and this is a bug fix rather than a preference. `vcpkg list` pads the
# "name:triplet" column to a fixed width and TRUNCATES what does not fit, with an ellipsis:
#
#   qt-advanced-docking-system:x64-mingw-ucrt-dynam...4.5.0   Create customizable layouts...
#
# The triplet is simply gone. Matching against it then fails and the port is reported as not installed although it
# built and installed perfectly -- 46 files, DLL and headers included. Any port whose name is long enough to eat the
# column hits this, and a 30-character triplet leaves very little of it.
$listScript = $scriptHeader + @"

./vcpkg list --x-json
"@

$listResult = Get-Msys2ScriptOutput -BashPath $msys2BashWin -ScriptBody $listScript -TempName "vcpkg_list.sh"

if ($listResult.ExitCode -ne 0)
{
    Write-Error "Failed to list the installed vcpkg packages (ExitCode=$($listResult.ExitCode))."
    foreach ($line in $listResult.Output) { Write-Error ("    | " + $line) }
    Abort-WithError
}

# The JSON is keyed by "name:triplet" and each value carries package_name, triplet, version and port_version as
# fields, so nothing has to be recovered from a formatted column.
$installedPorts    = @{}
$installedVersions = @{}

$listJson = $null
try
{
    $listJson = ($listResult.Output -join "`n") | ConvertFrom-Json
}
catch
{
    Write-Error "Could not parse the output of 'vcpkg list --x-json': $($_.Exception.Message)"
    Abort-WithError
}

foreach ($property in $listJson.PSObject.Properties)
{
    $entry = $property.Value
    $name  = [string]$entry.package_name
    if (-not $name) { continue }

    # Only this triplet. The key is "name:triplet" but the field is authoritative and needs no parsing.
    if ([string]$entry.triplet -ne $vcpkgTriplet) { continue }

    $installedPorts[$name] = $true

    # port_version 0 is the common case and vcpkg does not print "#0" anywhere, so neither does this.
    $version = [string]$entry.version
    if ($entry.PSObject.Properties.Name -contains "port_version")
    {
        $portVersion = [int]$entry.port_version
        if ($portVersion -gt 0) { $version = "{0}#{1}" -f $version, $portVersion }
    }
    if ($version) { $installedVersions[$name] = $version }
}

if ($installedPorts.Count -eq 0)
{
    Write-Error "'vcpkg list --x-json' reported no packages at all for triplet '$vcpkgTriplet'."
    Abort-WithError
}

$missing = @()
foreach ($port in $portSpecs)
{
    if ($installedPorts.ContainsKey($port.Name))
    {
        if ($installedVersions.ContainsKey($port.Name)) { $version = $installedVersions[$port.Name] }
        else                                            { $version = "(unknown)" }

        Write-Info ("Installed: {0} version {1}" -f $port.Name, $version)
    }
    else
    {
        $missing += $port.Name
    }
}

if ($missing.Count -gt 0)
{
    Write-Error ("The following configured ports are not installed for triplet '{0}': {1}" -f $vcpkgTriplet, ($missing -join ", "))
    Write-Error "The installation is incomplete."
    Abort-WithError
}

Write-Info ("All {0} configured port(s) are installed for triplet '{1}'." -f $portSpecs.Count, $vcpkgTriplet)

Write-Info "STEP 4: OK"

# STEP 5: Emit the reference manifest.
# --------------------------------------------------------------------

Write-Info "STEP 5: Emit the reference manifest."

# Not used by classic mode. It records the same dependency set in vcpkg manifest form so the
# environment can be moved to manifest mode later without re-authoring the configuration.

$dependencies = @()
foreach ($port in $portSpecs)
{
    if ($port.Features.Count -gt 0)
    {
        $dependencies += [PSCustomObject]@{ name = $port.Name; features = @($port.Features) }
    }
    else
    {
        $dependencies += $port.Name
    }
}

$manifest = [ordered]@{
    "name"         = (ConvertTo-ManifestName $devEnvName)
    "version-string" = "0.0.0"
    "description"  = ("Reference manifest generated by 4-Deps_VCPKG.ps1 for the {0} environment." -f $devEnvName)
    "dependencies" = $dependencies
}

$baselineCommit = [string]$envMap["VCPKG_BASELINE"]
if (-not [string]::IsNullOrWhiteSpace($baselineCommit) -and $baselineCommit -match '^[0-9a-fA-F]{40}$')
{
    $manifest["builtin-baseline"] = $baselineCommit
}
else
{
    Write-Warn "VCPKG_BASELINE is missing or not a full commit id; the manifest will have no 'builtin-baseline'."
}

try
{
    $manifestJson = [PSCustomObject]$manifest | ConvertTo-Json -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)
    Write-Info "Reference manifest written to: $manifestPath"
}
catch
{
    Write-Error "Failed to write the reference manifest '$manifestPath': $_"
    Abort-WithError
}

Write-Info "STEP 5: OK"

# --------------------------------------------------------------------
# STEP 6: Installation inventory
# --------------------------------------------------------------------
# A record of WHAT THIS ENVIRONMENT ACTUALLY IS, written to the drive
# next to the hand-written notes. Generated rather than maintained,
# because a list of a hundred packages is not something anybody keeps
# accurate by hand -- and the moment it is inaccurate it is worse than
# absent.
#
# What each file answers:
#   vcpkg_packages.txt   which ports, which versions, which features
#   vcpkg_packages.json  the same, in a form worth diffing between two
#                        environments or two dates
#   vcpkg_baseline.txt   the baseline commit and what it was, so a
#                        version can be traced back to an upstream state
#   msys2_packages.txt   the MSYS2 side, which vcpkg knows nothing about
#   environment.txt      the generated variables, verbatim

Write-Info "STEP 6: Write the installation inventory."

$inventoryDir = "${driveLetter}:/installation"
if (-not (Test-Path -LiteralPath $inventoryDir))
{
    New-Item -ItemType Directory -Path $inventoryDir -Force | Out-Null
}

$stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

function Write-InventoryFile
{
    # @brief Write one inventory file with a header saying what it is and when it was made.
    param
    (
        [string]$Name,
        [string]$Title,
        [string[]]$Body
    )

    $dest  = Join-Path $inventoryDir $Name
    $lines = @(
        "=======================================================================",
        $Title,
        "=======================================================================",
        "Generated by step 4 on $stamp. Do not hand-edit: a re-run overwrites it.",
        ""
    ) + $Body

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($dest, $lines, $utf8NoBom)
    Write-Info "Wrote $dest"
}

# -- vcpkg packages ----------------------------------------------------
try
{
    $listText = & $vcpkgExeWin list 2>&1
    if ($LASTEXITCODE -eq 0)
    {
        Write-InventoryFile -Name "vcpkg_packages.txt" -Title "VCPKG PACKAGES" -Body $listText
    }
    else
    {
        Write-Warn "vcpkg list failed; vcpkg_packages.txt not written."
    }

    $jsonText = & $vcpkgExeWin list --x-json 2>&1
    if ($LASTEXITCODE -eq 0)
    {
        $jsonDest  = Join-Path $inventoryDir "vcpkg_packages.json"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($jsonDest, $jsonText, $utf8NoBom)
        Write-Info "Wrote $jsonDest"
    }
}
catch
{
    Write-Warn "Could not query vcpkg for the package inventory: $($_.Exception.Message)"
}

# -- baseline ----------------------------------------------------------
# The commit alone is not much use a year later; the subject line says
# what the baseline was, which is what makes it traceable.
try
{
    $gitCmd  = Get-Command git -ErrorAction SilentlyContinue
    $baseline = $null

    if ($gitCmd -and $vcpkgRootWin -and (Test-Path -LiteralPath $vcpkgRootWin))
    {
        # -c safe.directory: a clone on a drive this account does not own is refused by git as "dubious
        # ownership", which is right for anything that writes and pointless for one read of the log.
        $baseline = & $gitCmd.Source -c "safe.directory=*" -C $vcpkgRootWin log -1 `
            --format="%H%nAuthor: %an <%ae>%nDate: %aI%nSubject: %s" 2>&1
        if ($LASTEXITCODE -ne 0) { $baseline = $null }
    }

    if (-not $baseline)
    {
        # No git here, so the commit alone. Still worth recording: without it the package versions cannot be traced
        # back to an upstream state at all.
        $recorded = [string]$envMap["VCPKG_BASELINE"]
        if ($recorded)
        {
            $baseline = @($recorded, "(git was not available to describe this commit)")
        }
    }

    if ($baseline)
    {
        Write-InventoryFile -Name "vcpkg_baseline.txt" -Title "VCPKG BASELINE" -Body $baseline
    }
}
catch
{
    Write-Warn "Could not read the vcpkg baseline: $($_.Exception.Message)"
}

# -- MSYS2 side --------------------------------------------------------
try
{
    if ($msys2Bash -and (Test-Path -LiteralPath $msys2Bash))
    {
        $pac = & $msys2Bash -lc "pacman -Q" 2>&1
        if ($LASTEXITCODE -eq 0)
        {
            Write-InventoryFile -Name "msys2_packages.txt" -Title "MSYS2 PACKAGES" -Body $pac
        }
    }
}
catch
{
    Write-Warn "Could not query pacman: $($_.Exception.Message)"
}

# -- the generated environment ----------------------------------------
try
{
    if ($envFilePath -and (Test-Path -LiteralPath $envFilePath))
    {
        Write-InventoryFile -Name "environment.txt" -Title "GENERATED ENVIRONMENT VARIABLES" `
            -Body (Get-Content -LiteralPath $envFilePath)
    }
}
catch
{
    Write-Warn "Could not copy the environment file: $($_.Exception.Message)"
}

Write-Info "STEP 6: OK"

# FINALIZATION
# --------------------------------------------------------------------

$scriptEnd = Get-Date
$elapsed = $scriptEnd - $scriptStart
$elapsedStr = ("{0:hh\:mm\:ss}" -f $elapsed)

Write-Info "VCPKG dependencies setup completed successfully."
Write-Info "TOTAL EXECUTION TIME: $($elapsed.TotalSeconds) seconds  ($elapsedStr)"

if ([Environment]::UserInteractive) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
}
$host.UI.RawUI.WindowTitle = $originalTitle

# --------------------------------------------------------------------
