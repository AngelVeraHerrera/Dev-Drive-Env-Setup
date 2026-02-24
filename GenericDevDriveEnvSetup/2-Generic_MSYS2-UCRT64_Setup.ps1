# ====================================================================
# GENERIC MSYS2-UCRT64 SETUP SCRIPT
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
#          David Abuín Sánchez
# Updated: 18/02/2026
# Version: 1.0.0
# --------------------------------------------------------------------
# License: MIT
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

# CONFIGURATION
# --------------------------------------------------------------------

$ConfigPath = Join-Path $PSScriptRoot "generic_dev_drive_env-cfg.json"

if (-not (Test-Path $ConfigPath)) 
{
    Write-Error "Configuration file missing: $ConfigPath"
    Abort-WithError
}

try 
{
    $Cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
} catch 
{
    Write-Error "Invalid JSON in $ConfigPath"
    Abort-WithError 
}

if (-not $Cfg.environment)
{
    Write-Error "Missing 'environment' object in config JSON: $ConfigPath"
    Abort-WithError 
}

if (-not $Cfg.msys2)
{
    Write-Error "Missing 'msys2' object in config JSON: $ConfigPath"
    Abort-WithError
}

if (-not $Cfg.msys2.source)
{
    Write-Error "Missing 'msys2.source' object in config JSON: $ConfigPath"
    Abort-WithError
}

if (-not $Cfg.msys2.target)
{
    Write-Error "Missing 'msys2.target' object in config JSON: $ConfigPath"
    Abort-WithError
}

if (-not $Cfg.msys2.packages)
{
    Write-Error "Missing 'msys2.packages' array in config JSON: $ConfigPath"
    Abort-WithError
}

$driveLetter = [string]$Cfg.environment.dev_drive_letter
$devEnvName  = [string]$Cfg.environment.dev_env_name
if ([string]::IsNullOrWhiteSpace($devEnvName))  {Write-Error "Missing environment.dev_env_name"; Abort-WithError}
if ([string]::IsNullOrWhiteSpace($driveLetter)) {Write-Error "Missing environment.dev_drive_letter"; Abort-WithError}
$driveLetter = $driveLetter.Trim().TrimEnd(':')         
$devDrive = "{0}:\" -f $driveLetter        
$driveLetterOnly = $driveLetter            
$proxyUrl = [string]$Cfg.environment.proxy_url

$msys2Url = [string]$Cfg.msys2.source.url
if ([string]::IsNullOrWhiteSpace($msys2Url))
{
    Write-Error "Missing msys2.source.url"
    Abort-WithError
}

$msys2Sha256 = ""
if ($Cfg.msys2.source.PSObject.Properties.Name -contains "sha256") 
{
    $msys2Sha256 = [string]$Cfg.msys2.source.sha256
}

$msysProfile = [string]$Cfg.msys2.target.profile   
$msysArch    = [string]$Cfg.msys2.target.arch     

if ([string]::IsNullOrWhiteSpace($msysProfile))
{
    Write-Error "Missing msys2.target.profile"
    Abort-WithError
}
if ([string]::IsNullOrWhiteSpace($msysArch))
{
    Write-Error "Missing msys2.target.arch"
    Abort-WithError
}

$msysEnv = "{0}64" -f $msysProfile

$msysPackages = @($Cfg.msys2.packages)

foreach ($p in $msysPackages)
{
    $pName = [string]$p.name
    $pMode = [string]$p.mode

    if ([string]::IsNullOrWhiteSpace($pName)) 
    {
        Write-Error "Invalid msys2.packages entry: missing 'name'"
        Abort-WithError
    }

    if ([string]::IsNullOrWhiteSpace($pMode)) 
    {
        Write-Error ("Invalid msys2.packages entry '{0}': missing 'mode' (pinned/latest)" -f $pName)
        Abort-WithError
    }

    $pMode = $pMode.Trim().ToLowerInvariant()
    if ($pMode -ne "pinned" -and $pMode -ne "latest") 
    {
        Write-Error ("Invalid msys2.packages entry '{0}': mode must be 'pinned' or 'latest' (got '{1}')" -f $pName, $pMode)
        Abort-WithError
    }

    if ($pMode -eq "pinned") {
        $pVer = ""
        if ($p.PSObject.Properties.Name -contains "version") {
            $pVer = [string]$p.version
        }
        if ([string]::IsNullOrWhiteSpace($pVer)) {
            Write-Error ("Invalid msys2.packages entry '{0}': mode='pinned' requires 'version'" -f $pName)
            Abort-WithError
        }
    }
}

$localPkgDir = Join-Path $PSScriptRoot "packages_msys2"
if (-not (Test-Path $localPkgDir)) { New-Item -ItemType Directory -Path $localPkgDir | Out-Null }

$msys2Installer = Join-Path $localPkgDir (Get-FileNameFromUrl $msys2Url)

$msys2Path   = Join-Path $devDrive "msys64"
$bashPath    = Join-Path $msys2Path "usr\bin\bash.exe"
$trustDbPath = Join-Path $msys2Path "etc\pacman.d\gnupg\trustdb.gpg"
$msysShellExe = Join-Path $msys2Path ("{0}.exe" -f $msysEnv)

# INITIAL PREPARATION
# --------------------------------------------------------------------

$scriptStart = Get-Date
$scriptDir = Get-ScriptDirectory
$localPkgDir = Join-Path $scriptDir "packages_msys2"
if (-not (Test-Path $localPkgDir)) { New-Item -ItemType Directory -Path $localPkgDir | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir = Join-Path $scriptDir "install_logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile = Join-Path $logsDir "${timestamp}_msys2-env-setup.log"
$globalLogFileUnix = $globalLogFile -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'

#Clear-Host
$originalTitle = $host.UI.RawUI.WindowTitle
$host.UI.RawUI.WindowTitle = "GENERIC MSYS2-UCRT64 SETUP SCRIPT"

$pinnedList = @()
$latestList = @()
foreach ($p in $msysPackages) {
    $mode = ([string]$p.mode).Trim().ToLowerInvariant()
    $name = [string]$p.name
    if ($mode -eq "pinned") {
        $pinnedList += ("{0}={1}" -f $name, [string]$p.version)
    } else {
        $latestList += $name
    }
}
$pinnedStr = if ($pinnedList.Count -gt 0) { $pinnedList -join ", " } else { "(none)" }
$latestStr = if ($latestList.Count -gt 0) { $latestList -join ", " } else { "(none)" }

Write-NoFormat "================================================================="
Write-NoFormat "  GENERIC MSYS2-$($msysEnv.ToUpperInvariant()) SETUP SCRIPT"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "  Authors: Ángel Vera Herrera"
Write-NoFormat "           David Abuín Sánchez"
Write-NoFormat "  Updated: 18/02/2026"
Write-NoFormat "  Version: 1.0.0"
Write-NoFormat "================================================================="
Write-NoFormat "Parameters (Loaded from JSON):"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "Drive Letter  = $devDrive"
Write-NoFormat "Dev Env Name   = $devEnvName"
Write-NoFormat "MSYS2 Root    = $msys2Path"
Write-NoFormat "MSYS2 Bash    = $bashPath"
Write-NoFormat "MSYS2 Env     = $msysEnv"
Write-NoFormat "MSYS2 URL     = $msys2Url"
Write-NoFormat "Pkgs (pinned) = $pinnedStr"
Write-NoFormat "Pkgs (latest) = $latestStr"
Write-NoFormat "Pkg Cache     = $localPkgDir"
Write-NoFormat "Current Path  = $scriptDir"
if ([string]::IsNullOrWhiteSpace($proxyUrl)) {
    Write-NoFormat "Proxy         = (none)"
} else {
    Write-NoFormat "Proxy         = $proxyUrl"
}
Write-NoFormat "================================================================="

# STEP 1: Initial checks and preparations.
# --------------------------------------------------------------------

Write-Info "STEP 1: Initial checks and preparations."

# Basic checks for target drive and cache folder
if (-not (Test-Path $devDrive)) {
    Write-Error "Dev drive path not found: $devDrive"
    Abort-WithError
}

if (-not (Test-Path $localPkgDir)) {
    New-Item -ItemType Directory -Path $localPkgDir | Out-Null
}

Write-Info "STEP 1: OK"


# STEP 2: Download MSYS2 installer and PINNED packages if not present.
# --------------------------------------------------------------------

Write-Info "STEP 2: Download MSYS2 installer and pinned packages if not present."

# Force TLS 1.2 (some endpoints fail otherwise)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Download MSYS2 installer
$msys2Installer = Join-Path $localPkgDir (Get-FileNameFromUrl $msys2Url)

# Build pinned download list from JSON
# URL pattern:
#   {base_url}/mingw/{profile}64/mingw-w64-{profile}-{arch}-{name}-{version}.pkg.tar.zst
$baseUrl   = [string]$Cfg.msys2.target.base_url
$profile   = [string]$Cfg.msys2.target.profile    
$arch      = [string]$Cfg.msys2.target.arch        
$repoPath  = "mingw/{0}64" -f $profile            

if ([string]::IsNullOrWhiteSpace($baseUrl)) 
{
    Write-Error "Missing msys2.target.base_url"
    Abort-WithError
}

$downloads = @(
    @{ Url = $msys2Url; Path = $msys2Installer; Name = "msys2-installer" }
)

foreach ($p in $msysPackages)
{
    $mode = ([string]$p.mode).Trim().ToLowerInvariant()
    if ($mode -ne "pinned") { continue }

    $name    = [string]$p.name
    $version = [string]$p.version

    $msysPkgName = "mingw-w64-{0}-{1}-{2}" -f $profile, $arch, $name
    $fileName    = "{0}-{1}-any.pkg.tar.zst" -f $msysPkgName, $version
    $url         = "{0}/{1}/{2}" -f $baseUrl.TrimEnd('/'), $repoPath, $fileName
    $path        = Join-Path $localPkgDir $fileName

    $downloads += @{ Url = $url; Path = $path; Name = $name }
}

foreach ($item in $downloads)
{
    if (-not (Test-Path $item.Path))
    {
        Write-Info "Downloading ($($item.Name)): $($item.Url)"
        try
        {
            $webParams = @{
                Uri       = $item.Url
                OutFile   = $item.Path
                UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
            }

            if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
                $webParams["Proxy"] = $proxyUrl
            }

            $oldProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'

            Invoke-WebRequest @webParams

            $ProgressPreference = $oldProgress
        }
        catch
        {
            Write-Error ("Failed to download: {0}. Error: {1}" -f $item.Url, $_.Exception.Message)
            Abort-WithError
        }
    }
    else
    {
        Write-Info "Package already exists: $($item.Path)"
    }
}

Write-Info "STEP 2: OK"

# STEP 3: Extract MSYS2 and perform initial run
# --------------------------------------------------------------------

Write-Info "STEP 3: Extract MSYS2 and perform initial run."

Write-Info "Extracting MSYS2 to: $devDrive"
try
{
    $args = "-y -o$devDrive"
    Start-Process -FilePath $msys2Installer -ArgumentList $args -Wait
    Write-Info "Extraction complete."
}
catch
{
    Write-Error ("Extraction failed: {0}" -f $_.Exception.Message)
    Abort-WithError
}

# Proxy config (optional)
try {
    if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
        Configure-MSYS2Proxy -Msys2Root $msys2Path -Proxy $proxyUrl
    }
}
catch {
    Write-Error ("Proxy configuration failed: {0}" -f $_.Exception.Message)
    Abort-WithError
}

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

# STEP 5: Install toolchain and utilities (JSON-driven)
# --------------------------------------------------------------------

Write-Info "STEP 5: Install toolchain and utilities (JSON-driven)."

# Always install git (needed for vcpkg, common workflows)
$gitPkgName = "mingw-w64-{0}-{1}-git" -f $msysProfile, $msysArch
Write-Info "Installing git (latest): $gitPkgName"
Start-Process -FilePath $bashPath -ArgumentList "-l", "-c", "`"pacman -S --noconfirm --needed $gitPkgName`"" -Wait

# Install PINNED packages from downloaded .pkg.tar.zst files (pacman -U)
$pinnedFiles = @()
foreach ($p in $msysPackages)
{
    $mode = ([string]$p.mode).Trim().ToLowerInvariant()
    if ($mode -ne "pinned") { continue }

    $name    = [string]$p.name
    $version = [string]$p.version

    $msysPkgName = "mingw-w64-{0}-{1}-{2}" -f $msysProfile, $msysArch, $name

    # NOTE: MSYS2 mingw repo packages typically end with "-any"
    $fileName = "{0}-{1}-any.pkg.tar.zst" -f $msysPkgName, $version
    $filePath = Join-Path $localPkgDir $fileName

    if (-not (Test-Path $filePath)) {
        Write-Error "Pinned package file missing: $filePath"
        Abort-WithError
    }

    $pinnedFiles += (Convert-ToMSYSPath $filePath)
}

if ($pinnedFiles.Count -gt 0)
{
    Write-Info "Installing pinned packages via pacman -U..."
    $installPinnedCmd = "pacman -U --noconfirm " + ($pinnedFiles -join " ")
    $proc = Start-Process -FilePath $bashPath -ArgumentList "-l","-c","`"$installPinnedCmd`"" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Error "Pinned package installation failed (exit code $($proc.ExitCode))."
        Abort-WithError
    }
}
else
{
    Write-Info "No pinned packages configured."
}

# Install LATEST packages via pacman -S (from JSON)
$latestPkgs = @()
foreach ($p in $msysPackages)
{
    $mode = ([string]$p.mode).Trim().ToLowerInvariant()
    if ($mode -ne "latest") { continue }

    $name = [string]$p.name
    $latestPkgs += ("mingw-w64-{0}-{1}-{2}" -f $msysProfile, $msysArch, $name)
}

if ($latestPkgs.Count -gt 0)
{
    Write-Info "Installing latest packages via pacman -S..."
    $installLatestCmd = "pacman -S --noconfirm --needed --disable-download-timeout " + ($latestPkgs -join " ")
    $proc = Start-Process -FilePath $bashPath -ArgumentList "-l","-c","`"$installLatestCmd`"" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Error "Latest package installation failed (exit code $($proc.ExitCode))."
        Abort-WithError
    }
}
else
{
    Write-Info "No latest packages configured."
}

# Optional: Create make.exe symlink if needed (some environments expose mingw32-make only)
$makeExe       = Join-Path $msys2Path ("{0}\bin\make.exe" -f $msysEnv)
$mingw32MakeEx = Join-Path $msys2Path ("{0}\bin\mingw32-make.exe" -f $msysEnv)

if (-not (Test-Path $makeExe) -and (Test-Path $mingw32MakeEx))
{
    Write-Info "Creating make.exe symlink (make.exe -> mingw32-make.exe)..."
    cmd /c mklink "$makeExe" "$mingw32MakeEx" | Out-Null
}

Write-Info "STEP 5: OK"

# STEP 6: Export the packages list.
# --------------------------------------------------------------------

Write-Info "STEP 6: Export the packages list."

$envNameLower = $devEnvName.ToLowerInvariant()
$msysEnvUpper = $msysEnv.ToUpperInvariant()
$baseFileName = "{0}_{1}_packages" -f $envNameLower, $msysEnv

# Output paths
$outTxtLocal = Join-Path $logsDir ("{0}.txt" -f $baseFileName)

$envDirOnDrive = Join-Path $devDrive "env"
if (-not (Test-Path $envDirOnDrive)) { New-Item -ItemType Directory -Path $envDirOnDrive | Out-Null }
$outTxtDrive = Join-Path $envDirOnDrive ("{0}.txt" -f $baseFileName)

# Run pacman -Q inside MSYS2 and capture output in PowerShell
Write-Info "Running 'pacman -Q' to capture installed packages..."

$pacmanOutput = & "$bashPath" -lc "pacman -Q"
if ($LASTEXITCODE -ne 0) {
    Write-Error "pacman -Q failed (exit code: $LASTEXITCODE)"
    Abort-WithError
}

# Build simple report (name version)
$reportLines = @()
$reportLines += "==============================================================="
$reportLines += "MSYS2 $msysEnvUpper ENVIRONMENT - PACKAGE LIST (pacman -Q)"
$reportLines += "==============================================================="
$reportLines += "# Format: <name> <version>"
$reportLines += "==============================================================="
$reportLines += $pacmanOutput

# Write to both locations (overwrite)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($outTxtLocal, $reportLines, $utf8NoBom)
[System.IO.File]::WriteAllLines($outTxtDrive, $reportLines, $utf8NoBom)

Write-Info "Packages exported:"
Write-Info "  Local: $outTxtLocal"
Write-Info "  Drive: $outTxtDrive"

Write-Info "STEP 6: OK"

# STEP 7: Setup environment variables and shorcout
# --------------------------------------------------------------------

Write-Info "STEP 7: Setup environment variables and shortcout."

$envFilePath = Join-Path "$driveLetter`:" (("env/{0}_env_variables.env" -f $devEnvName).ToLower())
$msys2Path = $msys2Path -replace '\\', '/'
$mingw64Path   = "$msys2Path/ucrt64"
$msys2BashPath = "$msys2Path/usr/bin/bash.exe"
$msys2RootPath = "$msys2Path"

Write-Info "UCRT64_ROOT=${mingw64Path}"
Write-Info "MINGW_ROOT=${mingw64Path}"
Write-Info "MSYS2_ROOT=${msys2Path}"
Write-Info "MSYS2_BASH=${msys2BashPath}"
Write-Info 'BASE_PATH=/ucrt64/bin:/usr/local/bin:/usr/bin:/bin'
Write-Info 'PATH=${BASE_PATH}'

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
    'BASE_PATH=/ucrt64/bin:/usr/local/bin:/usr/bin:/bin'
    'PATH=${BASE_PATH}'
)

Write-Info "Appending environment variables to $envFilePath"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stream = [System.IO.StreamWriter]::new($envFilePath, $true, $utf8NoBom)  
foreach ($line in $envLines) {$stream.WriteLine($line)}
$stream.Close()
 
# Shortcut 
$volume = Get-Volume -DriveLetter $driveLetterOnly -ErrorAction SilentlyContinue
$volumeLabel = if ($volume -and $volume.FileSystemLabel) { $volume.FileSystemLabel } else { $driveLetterOnly }
$shortcutPath = [System.IO.Path]::Combine([Environment]::GetFolderPath("Desktop"), "${devEnvName} Environment.lnk")
$targetPath = Join-Path "$devDrive" (("env/{0}_env_launcher.bat" -f $devEnvName).ToLower())

if (Test-Path $shortcutPath) 
{
    Remove-Item $shortcutPath -Force
    Write-Info "Existing shortcut removed."
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $targetPath
$shortcut.WorkingDirectory = $devDrive
$shortcut.WindowStyle = 1
$shortcut.IconLocation = "$targetPath,0"
$shortcut.Save()

Write-Info "Shortcut created on desktop."

$shortcutPath = [System.IO.Path]::Combine($devDrive, ("{0}_env_launcher.lnk" -f $devEnvName).ToLower())
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $targetPath
$shortcut.WorkingDirectory = $devDrive
$shortcut.WindowStyle = 1
$shortcut.IconLocation = "$targetPath,0"
$shortcut.Save()

Write-Info "Shortcut created on dev drive."

Write-Info "STEP 7: OK"

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