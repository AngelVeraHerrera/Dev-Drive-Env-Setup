# ====================================================================
# MSYS2 SETUP SCRIPT
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
    [string]$ConfigFile = "generic_dev_drive_env-cfg.json"
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
    # lines below never run: the window title is left changed and the deliberate `exit 1` is replaced by an unhandled
    # PowerShell error. Verified on this machine: UserInteractive=True with stdin redirected, ReadKey throws.
    if ([Environment]::UserInteractive -and -not [System.Console]::IsInputRedirected) {
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

# Resolves one JSON package entry into the three things pacman and the downloader need: the real package name, the
# repository sub-path, and the architecture tag its file name carries.
#
# MSYS2 ships TWO kinds of package and they are not interchangeable:
#
#   mingw  (default) -> mingw-w64-<profile>-<arch>-<name>, native Windows binaries, land in /<profile>64/bin.
#   msys             -> <name> verbatim, built against the MSYS2 POSIX runtime, land in /usr/bin.
#
# The distinction matters beyond naming. A tool that has to understand POSIX paths -- notably `make`, which reads
# them out of a configure-generated Makefile -- only works as the MSYS build. The native one treats /x/foo as a
# nonexistent relative path. Requesting a package by the wrong repo yields a tool that is subtly wrong rather than
# missing, which is far harder to diagnose.
#
# Absent "repo" means "mingw", so every existing configuration keeps its exact behaviour.
function Resolve-Msys2Package($pkg, $profile, $arch)
{
    $repo = ([string]$pkg.repo).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($repo)) { $repo = "mingw" }

    $name = [string]$pkg.name

    switch ($repo)
    {
        "msys"
        {
            # msys packages are arch-specific, except the handful of scripted ones published as "any". The file_arch
            # field covers those without needing a table of exceptions here.
            $fileArch = ([string]$pkg.file_arch).Trim()
            if ([string]::IsNullOrWhiteSpace($fileArch)) { $fileArch = $arch }

            return @{
                Repo     = "msys"
                PkgName  = $name
                RepoPath = "msys/{0}" -f $arch
                FileArch = $fileArch
            }
        }
        "mingw"
        {
            $fileArch = ([string]$pkg.file_arch).Trim()
            if ([string]::IsNullOrWhiteSpace($fileArch)) { $fileArch = "any" }

            return @{
                Repo     = "mingw"
                PkgName  = "mingw-w64-{0}-{1}-{2}" -f $profile, $arch, $name
                RepoPath = "mingw/{0}64" -f $profile
                FileArch = $fileArch
            }
        }
        default
        {
            Write-Error "Package '$name' has unknown repo '$repo'. Use 'mingw' (default) or 'msys'."
            Abort-WithError
        }
    }
}

function Invoke-Msys2Bash
{
    # @brief Run a command in the generated MSYS2 login shell, mirroring its output into the log. Returns the exit code.
    param
    (
        [string]$BashPath,
        [string]$Command
    )

    & $BashPath -l -c $Command 2>&1 | ForEach-Object { Write-NoFormat ("    | " + $_) }
    return $LASTEXITCODE
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
$host.UI.RawUI.WindowTitle = "GENERIC MSYS2 SETUP SCRIPT"

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
Write-NoFormat "  MSYS2 SETUP SCRIPT"
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
# URL pattern, per package, depending on its "repo" (see Resolve-Msys2Package):
#   mingw -> {base_url}/mingw/{profile}64/mingw-w64-{profile}-{arch}-{name}-{version}-any.pkg.tar.zst
#   msys  -> {base_url}/msys/{arch}/{name}-{version}-{arch}.pkg.tar.zst
$baseUrl   = [string]$Cfg.msys2.target.base_url
$profile   = [string]$Cfg.msys2.target.profile
$arch      = [string]$Cfg.msys2.target.arch

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

    $res      = Resolve-Msys2Package $p $profile $arch
    $fileName = "{0}-{1}-{2}.pkg.tar.zst" -f $res.PkgName, $version, $res.FileArch
    $url      = "{0}/{1}/{2}" -f $baseUrl.TrimEnd('/'), $res.RepoPath, $fileName
    $path     = Join-Path $localPkgDir $fileName

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
            # Remove the partial file before aborting, or the next run treats it as a completed download.
            Remove-Item -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue
            Write-Error ("Failed to download: {0}. Error: {1}" -f $item.Url, $_.Exception.Message)
            Abort-WithError
        }
    }
    else
    {
        Write-Info "Package already exists: $($item.Path)"
    }
}

# The installer is a self-extracting executable that STEP 3 runs, so verify it when the configuration says how.
# msys2.source.sha256 was previously read into a variable and never used again -- a documented integrity control that
# did nothing. Placed after the loop so a cached file is checked too, not only a fresh download.
if (-not [string]::IsNullOrWhiteSpace($msys2Sha256))
{
    $expected = $msys2Sha256.Trim().ToUpperInvariant()
    $actual   = (Get-FileHash -Path $msys2Installer -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $expected)
    {
        Write-Error "MSYS2 installer SHA256 mismatch."
        Write-Error "  expected: $expected"
        Write-Error "  actual:   $actual"
        Write-Error "  file:     $msys2Installer"
        Abort-WithError
    }
    Write-Info "MSYS2 installer SHA256 verified."
}
else
{
    Write-Info "msys2.source.sha256 is empty: installer integrity NOT verified."
}

Write-Info "STEP 2: OK"

# STEP 3: Extract MSYS2 and perform initial run
# --------------------------------------------------------------------

Write-Info "STEP 3: Extract MSYS2 and perform initial run."

Write-Info "Extracting MSYS2 to: $devDrive"
try
{
    if (Test-Path -LiteralPath $bashPath)
    {
        Write-Info "MSYS2 already present at $msys2Path; skipping extraction."
    }
    else
    {
        # Renamed off $args: that is an automatic variable, and shadowing it at script scope is a trap for anyone
        # who later adds a function here.
        $sfxArgs = "-y -o$devDrive"
        $proc = Start-Process -FilePath $msys2Installer -ArgumentList $sfxArgs -Wait -PassThru
        if ($proc.ExitCode -ne 0)
        {
            Write-Error "MSYS2 extraction failed (exit code $($proc.ExitCode))."
            Abort-WithError
        }
        Write-Info "Extraction complete."
    }
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
    $code = Invoke-Msys2Bash -BashPath $bashPath -Command ("sh '{0}'" -f $coreScriptUnix)
    if (($i -eq 1 -and $code -ne 0 -and $code -ne 1) -or
        ($i -gt 1 -and $code -ne 0)) 
    {
        Write-Error "Core upgrade failed on pass $i (exit code $code)."
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
$code = Invoke-Msys2Bash -BashPath $bashPath -Command "pacman -S --noconfirm --needed $gitPkgName"
if ($code -ne 0)
{
    Write-Error "git installation failed (exit code $code): $gitPkgName"
    Abort-WithError
}

# Install PINNED packages from downloaded .pkg.tar.zst files (pacman -U)
$pinnedFiles = @()
foreach ($p in $msysPackages)
{
    $mode = ([string]$p.mode).Trim().ToLowerInvariant()
    if ($mode -ne "pinned") { continue }

    $name    = [string]$p.name
    $version = [string]$p.version

    # Must name the file exactly as the download step above did, or the pinned install looks for something that was
    # never fetched: mingw packages are published as "-any", msys ones per architecture.
    $res      = Resolve-Msys2Package $p $msysProfile $msysArch
    $fileName = "{0}-{1}-{2}.pkg.tar.zst" -f $res.PkgName, $version, $res.FileArch
    $filePath = Join-Path $localPkgDir $fileName

    if (-not (Test-Path $filePath)) {
        Write-Error "Pinned package file missing: $filePath"
        Abort-WithError
    }

    #Non compatible with spaces in file paths, and pacman -U doesn't support quoting well, so we skip it for now and rely on the user to keep the local package folder clean of unrelated files.
    #$pinnedFiles += (Convert-ToMSYSPath $filePath)


    $msysPath = Convert-ToMSYSPath $filePath
    $pinnedFiles += "'$msysPath'"
}

if ($pinnedFiles.Count -gt 0)
{
    Write-Info "Installing pinned packages via pacman -U..."
    $installPinnedCmd = "pacman -U --noconfirm " + ($pinnedFiles -join " ")
    $code = Invoke-Msys2Bash -BashPath $bashPath -Command $installPinnedCmd
    if ($code -ne 0) {
        Write-Error "Pinned package installation failed (exit code $code)."
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

    $res = Resolve-Msys2Package $p $msysProfile $msysArch
    $latestPkgs += $res.PkgName
}

if ($latestPkgs.Count -gt 0)
{
    Write-Info "Installing latest packages via pacman -S..."
    $installLatestCmd = "pacman -S --noconfirm --needed --disable-download-timeout " + ($latestPkgs -join " ")
    $code = Invoke-Msys2Bash -BashPath $bashPath -Command $installLatestCmd
    if ($code -ne 0) {
        Write-Error "Latest package installation failed (exit code $code)."
        Abort-WithError
    }
}
else
{
    Write-Info "No latest packages configured."
}

# A make.exe -> mingw32-make.exe symlink used to be created here, so that plain `make` existed in the mingw prefix.
# It is DELIBERATELY GONE. Ask for { "name": "make", "repo": "msys" } in the configuration instead.
#
# The alias broke vcpkg. mingw32-make is a native Windows build, so it cannot resolve the POSIX paths that a
# configure script writes into its own Makefile. vcpkg's ffmpeg port prepends the compiler's directory to PATH ahead
# of the MSYS2 it downloads for the job, so an alias sitting next to gcc shadowed the correct make and the build died
# on its first line:
#
#   Makefile:1: /x/vcpkg/buildtrees/ffmpeg/src/.../Makefile: No such file or directory
#
# Diagnosed on the DegorasSLR drive: the same Makefile fails with this make and builds with the MSYS one. The msys
# package puts make in /usr/bin, where it satisfies the original intent -- plain `make` on PATH -- without displacing
# anything, and it understands both /x/... and X:/... paths.
#
# mingw32-make.exe itself stays: it comes from the mingw make package and nothing here removes it.

Write-Info "STEP 5: OK"

# STEP 6: Export the packages list.
# --------------------------------------------------------------------

Write-Info "STEP 6: Export the packages list."

$envNameLower = $devEnvName.ToLowerInvariant()
$msysEnvUpper = $msysEnv.ToUpperInvariant()
$baseFileName = "{0}_{1}_packages" -f $envNameLower, $msysEnv

# Output paths. The plain name is the CURRENT snapshot; the stamped one is history, because a fixed name meant each
# run erased the only record of what the previous environment contained.
$runStamp    = Get-Date -Format "yyyyMMdd-HHmmss"
$outTxtLocal = Join-Path $logsDir ("{0}.txt" -f $baseFileName)
$outTxtStamp = Join-Path $logsDir ("{0}_{1}.txt" -f $baseFileName, $runStamp)

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
[System.IO.File]::WriteAllLines($outTxtStamp, $reportLines, $utf8NoBom)

Write-Info "Packages exported:"
Write-Info "  Local: $outTxtLocal"
Write-Info "  Drive: $outTxtDrive"
Write-Info "  Stamp: $outTxtStamp"

Write-Info "STEP 6: OK"

# STEP 7: Setup environment variables and shorcout
# --------------------------------------------------------------------

Write-Info "STEP 7: Setup environment variables and shortcout."

$envFilePath = Join-Path "$driveLetter`:" (("env/{0}_env_variables.env" -f $devEnvName).ToLower())
$msys2PathNorm = $msys2Path -replace '\\', '/'
$mingwRootPath = "$msys2PathNorm/$msysEnv"     
$msys2BashPath = "$msys2PathNorm/usr/bin/bash.exe"

Write-Info "MINGW_ROOT=${mingwRootPath}"
Write-Info "MSYS2_ROOT=${msys2PathNorm}"
Write-Info "MSYS2_BASH=${msys2BashPath}"
Write-Info "MSYS2_ENV=${msysEnv}"
# BASE_PATH, with the Windows system directories optionally appended.
#
# Default ON, because leaving them out breaks more than it looks. Native tools reach cmd.exe through popen(), so
# without System32 on PATH windres fails with "can't popen ... Bad file descriptor" and gcc falls back to C:\Windows
# for temporary files and is denied. Measured in this environment: cmd.exe, powershell.exe, where.exe and reg.exe are
# all unreachable from the generated shell.
#
# They go at the TAIL so nothing in System32 can ever shadow the toolchain -- which is the failure this whole
# environment has already been bitten by once, with make.exe.
$basePath = "/{0}/bin:/usr/local/bin:/usr/bin:/bin" -f $msysEnv

$appendWindowsPath = $true
if ($Cfg.environment.PSObject.Properties.Name -contains "append_windows_system_path")
{
    $appendWindowsPath = [bool]$Cfg.environment.append_windows_system_path
}

if ($appendWindowsPath)
{
    # Lower-cased drive letter to match cygpath's canonical form and the rest of this file. MSYS2 resolves /C/ and
    # /c/ alike -- verified -- so this is consistency, not correctness.
    $sysRootPosix = (Convert-ToMSYSPath ([string]$env:SystemRoot)) -replace '/$', ''
    $sysRootPosix = [regex]::Replace($sysRootPosix, '^/([A-Za-z])/', { param($m) "/" + $m.Groups[1].Value.ToLowerInvariant() + "/" })
    if ([string]::IsNullOrWhiteSpace($sysRootPosix)) { $sysRootPosix = "/c/Windows" }
    $basePath = "{0}:{1}/System32:{1}:{1}/System32/Wbem:{1}/System32/WindowsPowerShell/v1.0" -f $basePath, $sysRootPosix
    Write-Info "Windows system directories appended to BASE_PATH (environment.append_windows_system_path)."
}
else
{
    Write-Info "Windows system directories NOT appended (environment.append_windows_system_path = false)."
}

Write-Info ("BASE_PATH={0}" -f $basePath)

# Prepare environment variable export file
if (-not (Test-Path $envFilePath)) 
{
    New-Item -Path $envFilePath -ItemType File -Force | Out-Null
}

# Write all environment variables to a file for later use
$envLines = @(
    "MINGW_ROOT=$mingwRootPath"
    "MSYS2_ROOT=$msys2PathNorm"
    "MSYS2_BASH=$msys2BashPath"
    "MSYS2_ENV=$msysEnv"
    ("BASE_PATH={0}" -f $basePath)
    # NOTE: PATH is deliberately NOT written here. Step 3 composes it from BASE_PATH, the vcpkg directories and
    # the configuration's custom entries, and it must be the LAST assignment in the file: the launcher bootstrap
    # expands ${...} line by line, so a PATH written before the variables it references would resolve to empty.
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
$targetPath = Join-Path "$devDrive" (("env/launcher/{0}_env_launcher.bat" -f $devEnvName).ToLower())


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