# ====================================================================
# DEVSYSTEM MSYS2-UCRT64 ENVIRONMENT SETUP SCRIPT
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera & David Abuín Sánchez
# Updated: 03/02/2026
# Version: 0.9.3 (Dynamic Config)
# --------------------------------------------------------------------
# © Milethos Tecnologies Team
# ====================================================================

# PARAMETERS
# --------------------------------------------------------------------

param 
(
    # Proxy URL for downloading packages (empty = no proxy)
    [string]$proxyUrl = ""
)

# ====================================================================
# CONFIGURATION LOADER 
# ====================================================================
$ConfigPath = Join-Path $PSScriptRoot "devsystem-config.json"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "CRITICAL: Configuration file missing: $ConfigPath"
    exit 1
}

try {
    $Cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "CRITICAL: Invalid JSON in $ConfigPath"
    exit 1
}

# ====================================================================
# VARIABLES FROM CONFIGURATION (JSON -> SCRIPT)
# ====================================================================

# 1. ENvironment VARIABLES
$Global:DevDrive     = $Cfg.environment.driveLetter
$Global:MsysDirName  = $Cfg.environment.msysDir
$Global:MsysPath     = Join-Path "${Global:DevDrive}:\" $Global:MsysDirName
$Global:VcpkgCommit  = $Cfg.vcpkg.baselineCommit

# Local variable for convenience
$devDrive = $Global:DevDrive

# 2.URLs for tools and packages
$msys2Url    = $Cfg.tools.msys2.url
$ninjaUrl    = $Cfg.tools.ninja.url
$gdbUrl      = $Cfg.tools.gdb.url
$gccUrl      = $Cfg.tools.gcc.url
$gccLibsUrl  = $Cfg.tools.gccLibs.url
$makeUrl     = $Cfg.tools.make.url
$cmakeUrl    = $Cfg.tools.cmake.url

# Basic validation of critical URLs
if (-not $msys2Url) { Write-Error "CRITICAL: JSON config is missing 'tools.msys2.url'"; exit 1 }

# ====================================================================


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
    
    # Mejora: Solo pausar si hay un usuario interactivo
    if ([Environment]::UserInteractive) {
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
    if ($PSScriptRoot) 
    {
        return $PSScriptRoot
    } 
    else 
    {
        return Split-Path -Parent (Convert-Path -LiteralPath ([System.Environment]::GetCommandLineArgs()[0]))
    }
}

function Get-FileNameFromUrl($url) 
{
    return [System.IO.Path]::GetFileName($url)
}

function Convert-ToMSYSPath($winPath) 
{
    return $winPath -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
}

function Configure-MSYS2Proxy
{
    param(
        [Parameter(Mandatory=$true)][string]$Msys2Root,
        [Parameter(Mandatory=$true)][string]$Proxy
    )

    if ([string]::IsNullOrWhiteSpace($Proxy))
    {
        Write-Info "No proxy configured for MSYS2 (proxyUrl is empty)."
        return
    }

    Write-Info "Configuring MSYS2 proxy environment..."

    # 1) Proxy for shells / pacman using profile.d
    $profileDir = Join-Path $Msys2Root "etc\profile.d"
    if (-not (Test-Path $profileDir))
    {
        New-Item -ItemType Directory -Path $profileDir | Out-Null
    }

    $proxyScriptPath = Join-Path $profileDir "devsystem-proxy.sh"

    $proxyLines = @(
        "# DevSystem - proxy configuration"
        "export http_proxy=""$Proxy"""
        "export https_proxy=""$Proxy"""
        "export HTTP_PROXY=""$Proxy"""
        "export HTTPS_PROXY=""$Proxy"""
        "export no_proxy=""localhost,127.0.0.1"""
    )

    Set-Content -Path $proxyScriptPath -Encoding ASCII -Value $proxyLines
    Write-Info "MSYS2 proxy env script created at: $proxyScriptPath"
    
    # 2) Proxy for GnuPG/dirmngr (pacman-key)
    Write-Info "Configuring dirmngr proxy..."

    $gnupgDir = Join-Path $Msys2Root "etc\pacman.d\gnupg"
    if (-not (Test-Path $gnupgDir))
    {
        New-Item -ItemType Directory -Path $gnupgDir | Out-Null
    }

    $dirmngrConf = Join-Path $gnupgDir "dirmngr.conf"

    $dirmngrLines = @("http-proxy $Proxy")

    Set-Content -Path $dirmngrConf -Encoding ASCII -Value $dirmngrLines
    Write-Info "dirmngr.conf created at: $dirmngrConf"
}

# INITIAL PREPARATION
# --------------------------------------------------------------------

# Timing start
$scriptStart = Get-Date

# Prepare variables.
$scriptDir = Get-ScriptDirectory
$localPkgDir = Join-Path $scriptDir "packages_msys2"

# Prepare logging.
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir = Join-Path $scriptDir "install_logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile = Join-Path $logsDir "${timestamp}_msys2-env-setup.log"
$globalLogFileUnix = $globalLogFile -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'

# SCRIPT STARTUP HEADER
# --------------------------------------------------------------------

# Clear and initial logs.
Clear-Host
$originalTitle = $host.UI.RawUI.WindowTitle
$host.UI.RawUI.WindowTitle = "DEVSYSTEM MSYS2-UCRT64 Env Setup"
Write-NoFormat "================================================================="
Write-NoFormat "  DEVSYSTEM MSYS2-UCRT64 ENVIRONMENT SETUP SCRIPT"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "  Author:  Angel Vera Herrera"
Write-NoFormat "  Updated: 19/11/2025"
Write-NoFormat "  Version: 0.9.3 (JSON Config)"
Write-NoFormat "================================================================="
Write-NoFormat "Parameters (Loaded from JSON):"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "Drive Letter     = $devDrive"
Write-NoFormat "MSYS2 Dir        = $Global:MsysDirName"
Write-NoFormat "MSYS2 URL        = $msys2Url"
Write-NoFormat "CMake URL        = $cmakeUrl"
Write-NoFormat "Ninja URL        = $ninjaUrl"
Write-NoFormat "GCC URL          = $gccUrl"
Write-NoFormat "Current Path     = $scriptDir"
if ([string]::IsNullOrWhiteSpace($proxyUrl)) 
{
    Write-NoFormat "Proxy            = (none)"
} else 
{
    Write-NoFormat "Proxy            = $proxyUrl"
}
Write-NoFormat "================================================================="

# STEP 1: Initial checks and preparations.
# --------------------------------------------------------------------

Write-Info "STEP 1: Initial checks and preparations."

# Check permissions.
Write-Info "Checking permissions..."
if (-not (Test-IsAdministrator)) 
{
    Write-Error "This script must be run as Administrator."
    Abort-WithError
}

# Ensure devDrive is defined and valid (Loaded from JSON)
Write-Info "Checking letter format..."
if ($devDrive -notmatch '^[A-Z]$') 
{
    Write-Error "Invalid drive letter format: $driveLetter"
    Abort-WithError
}

# Normalize format and prepare paths.
$driveLetterOnly = $devDrive.ToUpper()
$devDrive = "$driveLetterOnly`:\"

# Use the name of the JSON file 
$msys2Path   = Join-Path $devDrive $Global:MsysDirName 
$bashPath    = Join-Path $msys2Path "usr\bin\bash.exe"
$trustDbPath = Join-Path $msys2Path "etc\pacman.d\gnupg\trustdb.gpg"

# Check Dev Drive exists and is mounted
Write-Info "Checking if Dev Drive exists..."
try 
{
    $volume = Get-Volume -DriveLetter $driveLetterOnly -ErrorAction Stop
    Write-Info "Dev Drive detected at $devDrive"
} 
catch 
{
    Write-Error "Dev Drive '$devDrive' is not available or not mounted."
    Abort-WithError
}

# Check if the MSYS2 folder already exists.
Write-Info "Checking if MSYS2 folder exists..."
if ((Test-Path $msys2Path) -and ((Get-ChildItem -Path $msys2Path -Force) | Where-Object { $_.PSIsContainer -or $_.Length -gt 0 })) 
{
    Write-Error "The MSYS2 directory '$msys2Path' already exists and is not empty."
    Abort-WithError
}

# Ensure local MSYS2 packages directory exists
Write-Info "Checking if local MSYS2 packages folder exists..."
if (-not (Test-Path $localPkgDir)) 
{
    Write-Info "Creating local MSYS2 package cache at: $localPkgDir"
    New-Item -ItemType Directory -Path $localPkgDir | Out-Null
} 
else 
{
    Write-Info "Using existing MSYS2 package cache at: $localPkgDir"
}

Write-Info "STEP 1: OK"

# STEP 2: Download MSYS2 and required packages if not present.
# --------------------------------------------------------------------




Write-Info "STEP 2: Download MSYS2 and required packages if not present."

$makePkg        = Join-Path $localPkgDir (Get-FileNameFromUrl $makeUrl)
$ninjaPkg       = Join-Path $localPkgDir (Get-FileNameFromUrl $ninjaUrl)
$gdbPkg         = Join-Path $localPkgDir (Get-FileNameFromUrl $gdbUrl)
$cmakePkg       = Join-Path $localPkgDir (Get-FileNameFromUrl $cmakeUrl)
$gccPkg         = Join-Path $localPkgDir (Get-FileNameFromUrl $gccUrl)
$gccLibsPkg     = Join-Path $localPkgDir (Get-FileNameFromUrl $gccLibsUrl)
$msys2Installer = Join-Path $localPkgDir (Get-FileNameFromUrl $msys2Url)

$downloads = @(
    @{ Url = $msys2Url;     Path = $msys2Installer },
    @{ Url = $makeUrl;      Path = $makePkg },
    @{ Url = $ninjaUrl;     Path = $ninjaPkg },
    @{ Url = $gdbUrl;       Path = $gdbPkg },
    @{ Url = $cmakeUrl;     Path = $cmakePkg },
    @{ Url = $gccUrl;       Path = $gccPkg },
    @{ Url = $gccLibsUrl;   Path = $gccLibsPkg }
)


# At the begining of STEP 2, we force TLS 1.2 to avoid errors on safe connection
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Info "STEP 2: Download MSYS2 and required packages if not present."

foreach ($item in $downloads) 
{
    if (-Not (Test-Path $item.Path)) 
    {
        Write-Info "Downloading: $($item.Url)"
        try 
        {
            #Download params
            $webParams = @{
                Uri     = $item.Url
                OutFile = $item.Path
                # Some server may block the connection if there is no common UserAgent
                UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
            }

            # Add ONLY if there is some real proxy server with value (not blank string)
            if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
                $webParams["Proxy"] = $proxyUrl
            }

            # Optional: Deactivate progress speeds up the donwload 50%
            $oldProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            
            Invoke-WebRequest @webParams
            
            $ProgressPreference = $oldProgress
        } 
        catch 
        {
            Write-Error "Failed to download package: $($item.Url). Error: $($_.Exception.Message)"
            Abort-WithError
        }
    } 
    else 
    {
        Write-Info "Package already exists: $($item.Path)"
    }
}

Write-Info "STEP 2: OK"
<# OLD
foreach ($item in $downloads) 
{
    if (-Not (Test-Path $item.Path)) 
    {
        Write-Info "Downloading: $($item.Url)"
        try 
        {
            Invoke-WebRequest -Uri $item.Url -OutFile $item.Path -Proxy $proxyUrl
        } 
        catch 
        {
            Write-Error "Failed to download package: $($item.Url)"
            Abort-WithError
        }
    } 
    else 
    {
        Write-Info "Package already exists: $($item.Path)"
    }
}
#>


# STEP 3: Extract MSYS2 and perform initial run
# --------------------------------------------------------------------

Write-Info "STEP 3: Extract MSYS2 and perform initial run."

Write-Info "Extracting MSYS2 to: $devDrive"
try 
{
    $args = "-y -o$devDrive"
    Start-Process -FilePath $msys2Installer `
                  -ArgumentList $args `
                  -Wait
    Write-Info "Extraction complete."
} 
catch 
{
    Write-Error "Extraction failed."
    Abort-WithError
}

#Configure-MSYS2Proxy -Msys2Root $msys2Path -Proxy $proxyUrl

if (-Not (Test-Path $trustDbPath)) 
{
 
    Write-Info "Running MSYS2 bash for initial setup..."

    & "$bashPath" -l -c "true" 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) 
    {
        Write-Error "MSYS2 initial keyring setup failed."
        Abort-WithError
    }
    
    Write-Info "Initial setup done."
    
    if (-Not [string]::IsNullOrWhiteSpace($proxyUrl))
    {
        Write-Info "Initializing MSYS2 keyring explicitly (proxy mode)..."

        $cmd = @"
set -e
gpgconf --kill dirmngr 2>/dev/null || true
pacman-key --init
pacman-key --populate
"@

        & "$bashPath" -l -c "$cmd" 1>$null 2>$null

        if ($LASTEXITCODE -ne 0) 
        {
            Write-Error "MSYS2 keyring initialization failed (exit code: $LASTEXITCODE)"
            Abort-WithError
        }

        Write-Info "MSYS2 keyring initialized via pacman-key (proxy mode)."
    }
    
    Write-Info "MSYS2 initialized."
} 
else 
{
    Write-Info "Keyring already initialized, skipping."
}

Write-Info "STEP 3: OK"

# STEP 4: Upgrade MSYS2 core system
# --------------------------------------------------------------------

Write-Info "STEP 4: Upgrade MSYS2 core system."

$coreUpdateScript = Join-Path $env:TEMP "upgrade_core.sh"
Set-Content -Path $coreUpdateScript -Encoding ASCII -Value @'
pacman -Sy --noconfirm
pacman -Su --noconfirm
'@
$coreScriptUnix = $coreUpdateScript -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'

for ($i = 1; $i -le 3; $i++) 
{
    Write-Info "Running core system upgrade pass $i..."
    $proc = Start-Process -FilePath $bashPath `
                          -ArgumentList "-l", "-c", "`"$coreScriptUnix`"" `
                          -Wait -PassThru
    if (($i -eq 1 -and $proc.ExitCode -ne 0 -and $proc.ExitCode -ne 1) -or
        ($i -gt 1 -and $proc.ExitCode -ne 0)) 
    {
        Write-Error "Core upgrade failed on pass $i (exit code $($proc.ExitCode))."
        Abort-WithError
    }
}

Remove-Item $coreUpdateScript -Force

Write-Info "STEP 4: OK"

# STEP 5: Install toolchain and utilities
# --------------------------------------------------------------------

Write-Info "STEP 5: Install toolchain and utilities."

Write-Info "Installing generic development dependencies..."
$pkgCmd = @"
pacman -S --noconfirm git
"@
Start-Process -FilePath $bashPath -ArgumentList "-l", "-c", "`"$pkgCmd`"" -Wait

Write-Info "Installing GNU Make..."
$makePkgUnix = Convert-ToMSYSPath $makePkg
Start-Process -FilePath $bashPath -ArgumentList "-l", "-c", "`"pacman -U --noconfirm $makePkgUnix`"" -Wait

Write-Info "Creating make.exe symlink..."
$makeExe = Join-Path $msys2Path "ucrt64\bin\make.exe"
$mingw32MakeExe = Join-Path $msys2Path "ucrt64\bin\mingw32-make.exe"

if (-Not (Test-Path $makeExe) -and (Test-Path $mingw32MakeExe)) 
{
    cmd /c mklink "$makeExe" "$mingw32MakeExe" | Out-Null
    Write-Info "Symlink created successfully."
} 
else 
{
    Write-Info "Symlink already exists or mingw32-make not found."
}

Write-Info "Installing Ninja..."
$ninjaPkgUnix = Convert-ToMSYSPath $ninjaPkg
Start-Process -FilePath $bashPath -ArgumentList "-l", "-c", "`"pacman -U --noconfirm $ninjaPkgUnix`"" -Wait

Write-Info "Installing GDB..."
$gdbPkgUnix = Convert-ToMSYSPath $gdbPkg
Start-Process -FilePath $bashPath -ArgumentList "-l", "-c", "`"pacman -U --noconfirm $gdbPkgUnix`"" -Wait

Write-Info "Installing GCC and runtime libs..."
$pkg1 = Convert-ToMSYSPath $gccLibsPkg
$pkg2 = Convert-ToMSYSPath $gccPkg
$installCmd = "pacman -U --noconfirm $pkg1 $pkg2"
Start-Process -FilePath $bashPath `
                      -ArgumentList "-l", "-c", "`"$installCmd`"" `
                      -Wait
                      
Write-Info "Installing CMake..."
$cmakePkgUnix = Convert-ToMSYSPath $cmakePkg
Start-Process -FilePath $bashPath -ArgumentList "-l", "-c", "`"pacman -U --noconfirm $cmakePkgUnix`"" -Wait

Write-Info "STEP 5: OK"

# STEP 6: Show toolchain versions
# --------------------------------------------------------------------

Write-Info "STEP 6: Show toolchain versions."

# Ruta al bash de MSYS2 ya definida anteriormente como $bashPath
$tempValidationScript = Join-Path $env:TEMP "validate_versions.sh"

Set-Content -Path $tempValidationScript -Encoding ASCII -Value @'
echo "GCC   - $(/ucrt64/bin/gcc --version | head -n1)"
echo "CMake - $(/ucrt64/bin/cmake --version | head -n1)"
echo "Ninja - $(/ucrt64/bin/ninja --version | head -n1)"
echo "Make  - $(/ucrt64/bin/make --version | head -n1)"
echo "GDB   - $(/ucrt64/bin/gdb --version | head -n1)"
echo "Git   - $(/ucrt64/bin/git --version)"
'@

# Convert path to MSYS format
$valScriptUnix = $tempValidationScript -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'

# Execute and capture output
$toolchainOutput = & "$bashPath" -l -c "bash $valScriptUnix"

foreach ($line in $toolchainOutput) {
    Write-Info $line
}

Remove-Item $tempValidationScript -Force

Write-Info "STEP 6: OK"

# STEP 7: Install other utilities
# --------------------------------------------------------------------

Write-Info "STEP 7: Install other utilities."

$installDocCmd = @"
set -e
pacman -S --noconfirm --needed --disable-download-timeout \
  mingw-w64-ucrt-x86_64-doxygen \
  mingw-w64-ucrt-x86_64-curl \
  mingw-w64-ucrt-x86_64-ripgrep \
  mingw-w64-ucrt-x86_64-diffutils \
  mingw-w64-ucrt-x86_64-lld \
  mingw-w64-ucrt-x86_64-7zip \
  mingw-w64-ucrt-x86_64-ntldd
"@

$proc = Start-Process -FilePath $bashPath `
                      -ArgumentList "-l","-c","`"$installDocCmd`"" `
                      -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Error "Installation failed (exit code $($proc.ExitCode))."
    Abort-WithError
}

Write-Info "STEP 7: OK"

# STEP 8: Setup environment variables and shorcout
# --------------------------------------------------------------------

Write-Info "STEP 8: Setup environment variables and shortcout."

# Normalize MSYS2 path to forward slashes for cross-shell compatibility
$msys2Path = $msys2Path -replace '\\', '/'

$envFilePath   = Join-Path "$devDrive" "devsystem-env-variables.env"
$mingw64Path   = "$msys2Path/ucrt64"
$msys2BashPath = "$msys2Path/usr/bin/bash.exe"
$msys2RootPath = "$msys2Path"

Write-Info "UCRT64_ROOT=${mingw64Path}"
Write-Info "MINGW_ROOT=${mingw64Path}"
Write-Info "MSYS2_ROOT=${msys2Path}"
Write-Info "MSYS2_BASH=${msys2BashPath}"

# Prepare environment variable export file
if (-not (Test-Path $envFilePath)) 
{
    New-Item -Path $envFilePath -ItemType File -Force | Out-Null
}

# Write all environment variables to a file for later use
$envLines = @(
    "UCRT64_ROOT=$mingw64Path"
    "MINGW_ROOT=$mingw64Path"
    "MSYS2_ROOT=$msys2Path"
    "MSYS2_BASH=$msys2BashPath"
    "MSYS2_ENV=ucrt64"
)

Write-Info "Appending environment variables to $envFilePath"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stream = [System.IO.StreamWriter]::new($envFilePath, $true, $utf8NoBom)  
foreach ($line in $envLines) {$stream.WriteLine($line)}
$stream.Close()
 
$volume = Get-Volume -DriveLetter $driveLetterOnly -ErrorAction SilentlyContinue
$volumeLabel = if ($volume -and $volume.FileSystemLabel) { $volume.FileSystemLabel } else { $driveLetterOnly }

# Shortcut to MSYS2 MinGW64 shell
$shortcutName = "${volumeLabel} UCRT64.lnk"
$shortcutPath = [System.IO.Path]::Combine([Environment]::GetFolderPath("Desktop"), $shortcutName)
$targetPath = Join-Path $msys2Path "ucrt64.exe"

Write-Info "Creating shortcuts"

# Always (re)create shortcut
if (Test-Path $shortcutPath) 
{
    Remove-Item $shortcutPath -Force
    Write-Info "Existing shortcut removed: MSYS2 UCRT64"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $targetPath
$shortcut.WorkingDirectory = $devDrive
$shortcut.WindowStyle = 1
$shortcut.IconLocation = "$targetPath,0"
$shortcut.Save()

Write-Info "Shortcut created on desktop: MSYS2 UCRT64"

# Shortcut 2: DEVSYSTEM Environment Launcher (.bat)
$shortcutPath = [System.IO.Path]::Combine([Environment]::GetFolderPath("Desktop"), "${volumeLabel} Environment.lnk")
$targetPath = Join-Path "$devDrive" "devsystem-env-launcher.bat"

if (Test-Path $shortcutPath) 
{
    Remove-Item $shortcutPath -Force
    Write-Info "Existing shortcut removed: DEVSYSTEM Environment"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $targetPath
$shortcut.WorkingDirectory = $devDrive
$shortcut.WindowStyle = 1
$shortcut.IconLocation = "$targetPath,0"
$shortcut.Save()

Write-Info "Shortcut created on desktop: DEVSYSTEM Environment"

Write-Info "STEP 8: OK"

# FINALIZATION
# --------------------------------------------------------------------

# Compute elapsed time
$scriptEnd = Get-Date
$elapsed = $scriptEnd - $scriptStart
$elapsedStr = ("{0:hh\:mm\:ss}" -f $elapsed)

# Final logs.
Write-Info "MSYS2 environment setup completed successfully."
Write-Info "TOTAL EXECUTION TIME: $($elapsed.TotalSeconds) seconds  ($elapsedStr)"

# Exit
if ([Environment]::UserInteractive) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
}
$host.UI.RawUI.WindowTitle = $originalTitle

# --------------------------------------------------------------------