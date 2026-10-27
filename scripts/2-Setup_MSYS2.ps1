# ====================================================================
# MSYS2 SETUP SCRIPT
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
#          David Abuín Sánchez
# Updated: 27/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
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
    # @brief A warning line, shaped like Write-Info/Write-Error and mirrored into the log.
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

function Set-Msys2IgnorePkg
{
    # @brief Record the pinned packages in pacman's IgnorePkg, so "pacman -Syu" skips them ("ignoring package
    # upgrade"). A package that needs a newer pinned one makes pacman stop with a dependency error instead.
    # Transitive dependencies are not pinned. One list for the whole drive: every declared toolchain's installed
    # pins (the shared msys64 has one pacman.conf). The edit is Update-DrivEnvIgnorePkgLines: a managed block that a
    # re-run replaces, removed when there are no pins; line endings kept.
    param(
        [Parameter(Mandatory=$true)][string]$Msys2Root,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Packages
    )

    $confPath = Join-Path $Msys2Root "etc\pacman.conf"
    if (-not (Test-Path -LiteralPath $confPath))
    {
        Write-Warn "pacman.conf not found at '$confPath'; pinned packages will not be protected from upgrades."
        return
    }

    $raw = [System.IO.File]::ReadAllText($confPath)
    $nl  = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [string[]]($raw -split "`r?`n")
    # A file that ends with a newline splits into a last empty element; it is the newline, not a line.
    if (($lines.Count -gt 0) -and ($lines[$lines.Count - 1] -eq '')) { $lines = [string[]]($lines | Select-Object -First ($lines.Count - 1)) }

    $edit = Update-DrivEnvIgnorePkgLines -Lines $lines -Packages $Packages
    switch ($edit.Status)
    {
        'no-options'
        {
            Write-Warn "pacman.conf has no [options] section; pinned packages will not be protected from upgrades."
            return
        }
        'unchanged'
        {
            Write-Info "No pinned packages, and no IgnorePkg line of ours to take out."
            return
        }
    }

    [System.IO.File]::WriteAllText($confPath, ((@($edit.Lines) -join $nl) + $nl), [System.Text.Encoding]::ASCII)

    if ($edit.Status -eq 'cleared')
    {
        Write-Info "No pinned packages: the IgnorePkg line of an earlier run was taken out."
    }
    else
    {
        $wanted = @($Packages | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        Write-Info ("IgnorePkg set for {0} pinned package(s): {1}" -f $wanted.Count, ($wanted -join " "))
    }
}

function Set-Msys2InstalledPins
{
    # @brief Write IgnorePkg with the pins pacman reports INSTALLED (see Select-DrivEnvInstalledPins: IgnorePkg also
    # blocks resolving dependencies to packages not installed yet). Fatal when pacman cannot be asked.
    param
    (
        [Parameter(Mandatory=$true)][string]$Msys2Root,
        [Parameter(Mandatory=$true)][string]$BashPath,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Pins,
        [string]$When = ""
    )

    $query = @(& "$BashPath" -lc "pacman -Qq" 2>$null)
    if ($LASTEXITCODE -ne 0)
    {
        Write-Error ("'pacman -Qq' failed (exit code {0}), so the installed pins to protect are unknown." -f $LASTEXITCODE)
        Abort-WithError
    }

    # Assigned, not wrapped: it comma-returns.
    $protect = Select-DrivEnvInstalledPins -Pins $Pins -Installed ([string[]]$query)
    Write-Info ("IgnorePkg {0}: {1} of the configuration's {2} pin(s) are installed and named; the rest join once installed." -f
                $When, $protect.Count, $Pins.Count)
    Set-Msys2IgnorePkg -Msys2Root $Msys2Root -Packages $protect
}

# Resolves the MSYS2 target into its three names: subsystem (MSYSTEM, /clang64), repo subpath (mingw/clang64) and
# package prefix (mingw-w64-clang-x86_64-). They cannot be derived from one another (mingw64 has no infix,
# clangarm64's subpath is not <infix>64). The table lives in DrivEnvConfig.ps1 (Resolve-DrivEnvMsys2Target);
# this function only adds the step's refusals and warnings.
function Resolve-Msys2Subsystem($Target)
{
    # Legacy shape included: "clang" meant clang64, "ucrt" meant ucrt64, and both are still spelled that way in
    # configurations written before the subsystem key existed.
    $subsystem = Get-DrivEnvToolchainKey -Target $Target
    if ([string]::IsNullOrWhiteSpace($subsystem))
    {
        Write-Error "Missing msys2.target.subsystem (or the legacy msys2.target.profile)"
        Abort-WithError
    }

    $resolved = Resolve-DrivEnvMsys2Target -Target $Target

    if ([string]::IsNullOrWhiteSpace($resolved.Prefix) -or [string]::IsNullOrWhiteSpace($resolved.Subpath))
    {
        Write-Error "msys2.target.subsystem '$subsystem' is not one this script knows, and neither"
        Write-Error "msys2.target.package_prefix nor msys2.target.repo_subpath was given to describe it."
        Write-Error "Known subsystems: $(((Get-DrivEnvMsys2SubsystemTable).Keys | Sort-Object) -join ', ')."
        Abort-WithError
    }

    # A subsystem reached only through overrides has no family unless the configuration gave one. Guessing
    # from the name would be exactly the sniffing this table exists to avoid, so say so and let the user
    # decide: an empty family means the contract simply does not claim to know.
    if ([string]::IsNullOrWhiteSpace($resolved.Family))
    {
        Write-Warn "msys2.target.family is not set and subsystem '$subsystem' is not in the known table, so"
        Write-Warn "DEVSYSTEM_TOOLCHAIN will be written empty. Set msys2.target.family to 'gcc' or 'clang'."
    }

    # @{ Subsystem; Prefix; Subpath; Arch; Family }, the shape this function has always returned.
    return $resolved
}

# Resolves one package entry into its pacman name, repository subpath and architecture tag.
#   mingw (default) -> <package_prefix>-<name>, native, /<subsystem>/bin
#   msys            -> <name>, POSIX runtime, /usr/bin (e.g. make, which must read POSIX paths from Makefiles)
# The name comes from Get-DrivEnvMsys2PackageName, the same rule IgnorePkg uses.
function Resolve-Msys2Package($pkg, $sub)
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
            if ([string]::IsNullOrWhiteSpace($fileArch)) { $fileArch = $sub.Arch }

            return @{
                Repo     = "msys"
                PkgName  = (Get-DrivEnvMsys2PackageName -Package $pkg -Prefix $sub.Prefix)
                RepoPath = "msys/{0}" -f $sub.Arch
                FileArch = $fileArch
            }
        }
        "mingw"
        {
            $fileArch = ([string]$pkg.file_arch).Trim()
            if ([string]::IsNullOrWhiteSpace($fileArch)) { $fileArch = "any" }

            return @{
                Repo     = "mingw"
                PkgName  = (Get-DrivEnvMsys2PackageName -Package $pkg -Prefix $sub.Prefix)
                RepoPath = $sub.Subpath
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

function Invoke-Pacman
{
    # @brief Run a pacman operation with bounded retries (mirrors stall, .sig files 404, rate limits answer HTTP 429);
    # returns the last exit code. The pause grows with the attempt (10 s, then 20 s): a rate limit needs one, and the
    # same command run again a minute later is what has always worked by hand.
    # --disable-download-timeout always: otherwise one slow mirror aborts the whole transaction. LC_ALL=C: messages in
    # English, the same on every PC and searchable, and none of the localized quotes the log turned into mojibake.
    param
    (
        [Parameter(Mandatory=$true)][string]$BashPath,
        [Parameter(Mandatory=$true)][string]$Arguments,
        [int]$Attempts     = 3,
        [int]$DelaySeconds = 10
    )

    $code = 1
    for ($try = 1; $try -le $Attempts; $try++)
    {
        if ($try -gt 1) { Write-Info "pacman attempt $try of $Attempts..." }

        $code = Invoke-Msys2Bash -BashPath $BashPath -Command ("LC_ALL=C pacman --disable-download-timeout " + $Arguments)
        if ($code -eq 0) { return 0 }

        if ($try -lt $Attempts)
        {
            Write-Info ("pacman failed with exit code {0}. Retrying in {1} seconds." -f $code, ($DelaySeconds * $try))
            Start-Sleep -Seconds ($DelaySeconds * $try)
        }
    }

    return $code
}

function Configure-MSYS2Terminal
{
    # @brief A readable default /etc/minttyrc for the drive's mintty (the launcher's terminal). BoldAsFont=no keeps
    # bold as a brighter colour, as the console had. /etc rather than ~ (HOME is shared by every MSYS2 on the
    # machine); ~/.minttyrc still wins.
    param(
        [Parameter(Mandatory=$true)][string]$Msys2Root
    )

    Write-Info "Configuring the terminal..."

    $etcDir = Join-Path $Msys2Root "etc"
    if (-not (Test-Path $etcDir))
    {
        New-Item -ItemType Directory -Path $etcDir | Out-Null
    }

    $minttyPath = Join-Path $etcDir "minttyrc"

    # Cascadia Mono is Microsoft's terminal face and is markedly better hinted at small sizes, but it only ships
    # with Windows 11 and with Windows Terminal, so it cannot be assumed. Consolas has been on every Windows since
    # Vista. Probe for the better one and fall back rather than hard-coding either.
    $font = "Consolas"
    $fontDirs = @((Join-Path $env:SystemRoot "Fonts"),
                  (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"))
    foreach ($dir in $fontDirs)
    {
        if (Test-Path (Join-Path $dir "CascadiaMono.ttf")) { $font = "Cascadia Mono"; break }
    }
    Write-Info "Terminal font: $font"

    # Columns, Rows and Term are MSYS2's own and are kept as they were.
    $minttyLines = @(
        "# DevSystem - terminal configuration for this drive."
        "# Written by 2-Setup_MSYS2.ps1. A personal ~/.minttyrc still overrides everything here."
        "Columns=100"
        "Rows=27"
        "Term=xterm-256color"
        ""
        "# Bold as a brighter colour rather than a heavier face. This is what the Windows console did, and a"
        "# synthesised bold at this size is what makes text look smeared."
        "BoldAsFont=no"
        ""
        "Font=$font"
        "FontHeight=11"
        "FontSmoothing=full"
        ""
        "# Accented output -- the setup scripts and MSYS2 itself both produce it -- and a scrollback that can hold"
        "# a build log rather than the tail of one."
        "Charset=UTF-8"
        "ScrollbackLines=50000"
        ""
        "# Right-click pastes, as it did in the console window this replaces. Selecting already copies in mintty,"
        "# so between the two there is nothing new to learn."
        "RightClickAction=paste"
    )

    Set-Content -Path $minttyPath -Encoding ASCII -Value $minttyLines
    Write-Info "mintty configuration written at: $minttyPath"
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
    # 3) git's proxy goes into etc/gitconfig, written below with the git identity.
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
} catch 
{
    Write-Error "Invalid JSON in $ConfigPath"
    Abort-WithError 
}

# Validate the whole configuration before anything reads a value out of it. An unknown key is an ERROR here rather
# than a silent fall-back to a default; the head of DrivEnvConfig.ps1 explains why that distinction earns a file.
. (Join-Path $PSScriptRoot "DrivEnvConfig.ps1")
. (Join-Path $PSScriptRoot "DrivEnvLogs.ps1")

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

# The configuration as read, kept for what is drive-level and so needs every toolchain, not just this one: today
# the IgnorePkg union. Read-only from here on.
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

# Every declared toolchain's pins, by the names pacman knows them, from the configuration AS READ: the projected
# $Cfg holds this toolchain only. Computed here, before anything is installed, because the installed ones go into
# pacman.conf BEFORE the core upgrade: see Set-Msys2InstalledPins. Assigned, not wrapped in @(): it comma-returns.
try
{
    $ignoreUnion = Get-DrivEnvIgnorePkgUnion -Cfg $CfgFull
}
catch
{
    Write-Error ("Cannot name the pinned packages: {0}" -f $_.Exception.Message)
    Abort-WithError
}

# EVERY FILE THIS TOOLCHAIN OWNS IS NAMED HERE, from Get-DrivEnvToolchainNames and from nowhere else: the env file,
# the launcher set, the shortcuts and the packages export all carry the toolchain key, and steps 3 to 6 read them back
# through the same table. A name built anywhere else is a file some other step cannot find.
$names = Get-DrivEnvToolchainNames -Cfg $Cfg
if ($null -eq $names)
{
    Write-Error "Cannot name this toolchain's files: environment.dev_drive_letter, environment.dev_env_name or the toolchain key is blank."
    Abort-WithError
}

# The one variable every read and write of the env file below goes through, assigned once, here, and printed under
# -ValidateOnly AS IT IS -- so what the tests see is what the step opens.
$envFilePath = $names.EnvFile

if ($ValidateOnly)
{
    Write-Info ("Env file for this toolchain: {0}" -f $envFilePath)
    Write-Info ("Launcher for this toolchain: {0}" -f $names.Launcher)
    $unionShown = if ($ignoreUnion.Count -gt 0) { $ignoreUnion -join " " } else { "(none)" }
    Write-Info ("IgnorePkg for the drive, every declared toolchain's pins, each named once installed: {0}" -f $unionShown)
    Write-Info "-ValidateOnly was given, so nothing further will run."
    exit 0
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

# A drive generated before 3.0.0 is not migrated: its launchers glob *_env_variables.env and would find two files
# once this step writes the new one. Checked on real runs only (-ValidateOnly needs no mounted drive).
$legacyEnvFile = Get-DrivEnvLegacyEnvFile -Cfg $Cfg
if ($legacyEnvFile -and (Test-Path -LiteralPath $legacyEnvFile))
{
    Write-Error "This drive was generated before 3.0.0: $legacyEnvFile exists."
    Write-Error "3.0.0 names one env file and one launcher set per toolchain and does not migrate older drives: written"
    Write-Error "beside the old ones, the new files would stop the drive's existing launchers from starting. Generate a"
    Write-Error "new drive with this version, or keep using the generator that made this one."
    Abort-WithError
}

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

# Resolved ONCE, here, and passed around afterwards. The three names a subsystem has -- MSYSTEM value,
# repository sub-path and package prefix -- were previously rebuilt by string concatenation at four separate
# places in this file, each of which had to be right independently. See Resolve-Msys2Subsystem.
$msysSub  = Resolve-Msys2Subsystem $Cfg.msys2.target
$msysEnv  = $msysSub.Subsystem
$msysArch = $msysSub.Arch

# The key the files are named after and the MSYS2_ENV this step writes into them are ONE value. The launcher opens
# MSYS2 as -<MSYS2_ENV> and the bootstrap refuses a session whose MSYSTEM differs, so a name and a content that
# disagreed would make a launcher that never opens.
if ($names.Key -ine $msysEnv)
{
    Write-Error ("The toolchain key '{0}' and the MSYS2 subsystem '{1}' differ; they must be the same value." -f $names.Key, $msysEnv)
    Abort-WithError
}

if ([string]::IsNullOrWhiteSpace($msysArch))
{
    Write-Error "Missing msys2.target.arch, and subsystem '$msysEnv' has no default architecture in the table."
    Abort-WithError
}

Write-Info ("MSYS2 target: subsystem {0}, packages {1}-*, repository {2}" -f
            $msysSub.Subsystem, $msysSub.Prefix, $msysSub.Subpath)

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

$localPkgDir = Join-Path (Split-Path -Parent (Get-ScriptDirectory)) "cache\msys2"
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
# The steps live in scripts/. Everything they read out of the generator or write back into it -- the
# configuration, the overlay ports and triplets, the MSYS2 package cache, the launcher templates and these
# logs -- sits one level up beside that directory, so it is all named from the root and not from here.
$drivEnvRoot = Split-Path -Parent $scriptDir
$localPkgDir = Join-Path $drivEnvRoot "cache\msys2"
if (-not (Test-Path $localPkgDir)) { New-Item -ItemType Directory -Path $localPkgDir | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir = Join-Path $drivEnvRoot "logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile = Join-Path $logsDir (Get-DrivEnvLogName -Timestamp $timestamp -Role "msys2-env-setup" -Key $names.Key)
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
Write-NoFormat "  Updated: 27/10/2026"
Write-NoFormat "  Version: 3.0.0"
Write-NoFormat "================================================================="
Write-NoFormat "Parameters (Loaded from JSON):"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "Drive Letter  = $devDrive"
Write-NoFormat "Dev Env Name   = $devEnvName"
Write-NoFormat "MSYS2 Root    = $msys2Path"
Write-NoFormat "MSYS2 Bash    = $bashPath"
Write-NoFormat "MSYS2 Env     = $msysEnv"
Write-NoFormat "Env File      = $($names.EnvFile)"
Write-NoFormat "Launcher      = $($names.Launcher)"
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
# Download URLs, per repo (see Resolve-Msys2Package):
#   mingw -> {base_url}/{repo_subpath}/{package_prefix}-{name}-{version}-any.pkg.tar.zst
#   msys  -> {base_url}/msys/{arch}/{name}-{version}-{arch}.pkg.tar.zst
$baseUrl   = [string]$Cfg.msys2.target.base_url

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

    $res      = Resolve-Msys2Package $p $msysSub
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
        $webParams = @{
            Uri       = $item.Url
            OutFile   = $item.Path
            UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        }

        if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
            $webParams["Proxy"] = $proxyUrl
        }

        # Three attempts, as pacman gets: repo.msys2.org answers a burst of downloads with HTTP 429 (rate limit), and
        # the same request a little later succeeds.
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        for ($try = 1; $try -le 3; $try++)
        {
            try
            {
                Invoke-WebRequest @webParams
                break
            }
            catch
            {
                # Remove the partial file, or the next run treats it as a completed download.
                Remove-Item -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue
                if ($try -lt 3)
                {
                    Write-Info ("Download failed ({0}). Retrying in {1} seconds." -f $_.Exception.Message, (10 * $try))
                    Start-Sleep -Seconds (10 * $try)
                    continue
                }
                $ProgressPreference = $oldProgress
                Write-Error ("Failed to download: {0}. Error: {1}" -f $item.Url, $_.Exception.Message)
                Abort-WithError
            }
        }
        $ProgressPreference = $oldProgress
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

# The drive's git system config (proxy and identity): the setup steps run git.exe directly and never source
# profile.d. ~/.gitconfig and repository configs still override it. UTF-8: names are not ASCII.
$gitSysLines = @(Get-DrivEnvGitSystemConfigLines -Proxy $proxyUrl -Git $Cfg.git)
if ($gitSysLines.Count -gt 0)
{
    $gitConfigPath = Join-Path $msys2Path "etc\gitconfig"
    [System.IO.File]::WriteAllLines($gitConfigPath, [string[]]$gitSysLines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Info "git system config written: $gitConfigPath"
}

# Terminal config. Unconditional, unlike the proxy above: every drive gets a terminal, whether or not it sits
# behind one.
try {
    Configure-MSYS2Terminal -Msys2Root $msys2Path
}
catch {
    # Not fatal. A drive with an unstyled terminal is still a working drive.
    Write-Warn ("Terminal configuration failed: {0}" -f $_.Exception.Message)
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

# IgnorePkg BEFORE the upgrade, so "pacman -Su" cannot replace another toolchain's pinned compiler. Only installed
# pins: a pin not installed yet would stop pacman resolving git's dependencies below. On a fresh drive pacman.conf
# is left pristine through its first upgrade.
$pacmanConf   = Join-Path $msys2Path "etc\pacman.conf"
$pacnewPath   = $pacmanConf + ".pacnew"
$pacnewBefore = Test-Path -LiteralPath $pacnewPath
Set-Msys2InstalledPins -Msys2Root $msys2Path -BashPath $bashPath -Pins $ignoreUnion -When "before the core upgrade"

for ($i = 1; $i -le 3; $i++)
{
    Write-Info "Running core system upgrade pass $i..."
    # Pass 1 may end in 1 by design (a core update that wants a fresh shell), and the next pass repeats it, so it gets
    # one attempt; the later passes get the network retries before a failure counts.
    $code = Invoke-Pacman -BashPath $bashPath -Arguments "-Syu --noconfirm" -Attempts $(if ($i -eq 1) { 1 } else { 3 })
    if (($i -eq 1 -and $code -ne 0 -and $code -ne 1) -or
        ($i -gt 1 -and $code -ne 0))
    {
        Write-Error "Core upgrade failed on pass $i (exit code $code)."
        Abort-WithError
    }
}

# An upgrade of pacman itself never overwrites a pacman.conf that was edited -- and on a drive with pins installed
# the line above edits it -- so it stays in force; pacman puts its new default beside it as pacman.conf.pacnew
# instead. Said, because a .pacnew can carry repository changes that only a person should merge.
if (Test-Path -LiteralPath $pacnewPath)
{
    $pacnewWhen = if ($pacnewBefore) { "is still there" } else { "appeared during this upgrade" }
    Write-Warn ("'{0}' {1}: pacman's new default configuration, which pacman does not apply by itself. Compare it with pacman.conf and merge it by hand; keep the IgnorePkg lines marked 'DrivEnv'." -f $pacnewPath, $pacnewWhen)
}

Write-Info "STEP 4: OK"

# STEP 5: Install toolchain and utilities (JSON-driven)
# --------------------------------------------------------------------

Write-Info "STEP 5: Install toolchain and utilities (JSON-driven)."

# Always install git (needed for vcpkg, common workflows)
$gitPkgName = "{0}-git" -f $msysSub.Prefix
Write-Info "Installing git (latest): $gitPkgName"
$code = Invoke-Pacman -BashPath $bashPath -Arguments "-S --noconfirm --needed $gitPkgName"
if ($code -ne 0)
{
    Write-Error "git installation failed (exit code $code): $gitPkgName"
    Abort-WithError
}

# Ask pacman: with an unresolvable dependency --noconfirm skips the package and still exits 0.
$null = & "$bashPath" -lc "pacman -Q $gitPkgName" 2>&1
if ($LASTEXITCODE -ne 0)
{
    Write-Error "pacman reported success, but $gitPkgName is not installed. Read the pacman output above for the dependency it skipped."
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
    $res      = Resolve-Msys2Package $p $msysSub
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
    # Through the retries too: the files are local, but their dependencies come from the mirrors.
    $code = Invoke-Pacman -BashPath $bashPath -Arguments ("-U --noconfirm " + ($pinnedFiles -join " "))
    if ($code -ne 0) {
        Write-Error "Pinned package installation failed (exit code $code)."
        Abort-WithError
    }
}
else
{
    Write-Info "No pinned packages configured."
}

# IgnorePkg again, now with this toolchain's pins installed, so the "pacman -S" below cannot upgrade them.
Set-Msys2InstalledPins -Msys2Root $msys2Path -BashPath $bashPath -Pins $ignoreUnion -When "after the pinned install"

# This toolchain's own pins, for the check that follows the installs.
$pinnedNames = @()
foreach ($p in $msysPackages)
{
    if (([string]$p.mode).Trim().ToLowerInvariant() -ne "pinned") { continue }
    $pinnedNames += (Resolve-Msys2Package $p $msysSub).PkgName
}

# Install LATEST packages via pacman -S (from JSON)
$latestPkgs = @()
foreach ($p in $msysPackages)
{
    $mode = ([string]$p.mode).Trim().ToLowerInvariant()
    if ($mode -ne "latest") { continue }

    $res = Resolve-Msys2Package $p $msysSub
    $latestPkgs += $res.PkgName
}

if ($latestPkgs.Count -gt 0)
{
    Write-Info "Installing latest packages via pacman -S..."
    $installLatestArgs = "-S --noconfirm --needed " + ($latestPkgs -join " ")
    $code = Invoke-Pacman -BashPath $bashPath -Arguments $installLatestArgs
    if ($code -ne 0) {
        Write-Error "Latest package installation failed (exit code $code)."
        Abort-WithError
    }
}
else
{
    Write-Info "No latest packages configured."
}

# Confirm every pin is installed at its exact version: "pacman -U" exits 0 even when it skipped packages over an
# unresolved dependency (winpthreads without its exact libwinpthread took clang down with it, and step 4 then failed
# much later in vcpkg's detect_compiler).
if ($pinnedNames.Count -gt 0)
{
    Write-Info "Verifying that every pinned package installed at its pinned version..."

    $installedMap = @{}
    $queryOut = & "$bashPath" -lc "pacman -Q"
    if ($LASTEXITCODE -ne 0)
    {
        Write-Error "pacman -Q failed while verifying the pinned packages (exit $LASTEXITCODE)."
        Abort-WithError
    }
    foreach ($line in @($queryOut))
    {
        $parts = ([string]$line).Trim() -split '\s+'
        if ($parts.Count -ge 2) { $installedMap[$parts[0]] = $parts[1] }
    }

    $pinProblems = @()
    foreach ($p in @($Cfg.msys2.packages))
    {
        if (([string]$p.mode).Trim().ToLowerInvariant() -ne "pinned") { continue }

        $res = Resolve-Msys2Package -pkg $p -sub $msysSub
        $wanted = [string]$p.version
        $actual = $installedMap[$res.PkgName]

        if ($null -eq $actual)      { $pinProblems += ("{0}: pinned {1}, NOT INSTALLED" -f $res.PkgName, $wanted) }
        elseif ($actual -ne $wanted) { $pinProblems += ("{0}: pinned {1}, installed {2}" -f $res.PkgName, $wanted, $actual) }
    }

    if ($pinProblems.Count -gt 0)
    {
        Write-Error ("{0} pinned package(s) did not install as pinned:" -f $pinProblems.Count)
        foreach ($problem in $pinProblems) { Write-Error ("    " + $problem) }
        Write-Error ""
        Write-Error "pacman reports an unresolvable pin as a WARNING and still exits zero, so this is caught here"
        Write-Error "rather than by an exit code. Read the pacman output above for the dependency it could not"
        Write-Error "satisfy. The usual cause is a pin on one half of a package pair: winpthreads requires an exact"
        Write-Error "libwinpthread, and mingw-w64's headers, crt, winpthreads and libwinpthread are one source."
        Write-Error "Pin both halves to the same version, or neither."
        Abort-WithError
    }

    Write-Info ("All {0} pinned package(s) verified at their pinned versions." -f $pinnedNames.Count)
}

# gcc/g++ driver aliases on a clang subsystem: some builds call "gcc" directly (ffmpeg's HOSTCC). Copies of the clang
# driver, which picks its personality from argv[0] (as the package's own cc.exe does), refreshed on every run so an
# upgraded clang never leaves a stale copy. They answer "clang version", so they fool no version check.
if ($msysSub.Subsystem -like "clang*")
{
    $clangBin = Join-Path (Join-Path $msys2Path $msysSub.Subsystem) "bin"

    foreach ($pair in @(@{ From = "clang.exe"; To = "gcc.exe" }, @{ From = "clang++.exe"; To = "g++.exe" }))
    {
        $src = Join-Path $clangBin $pair.From
        $dst = Join-Path $clangBin $pair.To

        if (-not (Test-Path -LiteralPath $src))
        {
            # Fatal: a clang subsystem without clang.exe is not an environment.
            Write-Error ("{0} is missing from {1}." -f $pair.From, $clangBin)
            Write-Error "This is a clang subsystem, so that file is the compiler. The environment cannot be built"
            Write-Error "without it, and continuing would fail much later inside vcpkg with an unrelated-looking"
            Write-Error "error. Check the pacman output above for a package that did not install."
            Abort-WithError
        }

        try
        {
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
            Write-Info ("Driver alias: {0} -> {1}" -f $pair.To, $pair.From)
        }
        catch
        {
            # Not fatal on its own, but say so loudly: the ports that need it fail much later and much less
            # legibly than this line does.
            Write-Warn ("Could not create the {0} alias: {1}" -f $pair.To, $_.Exception.Message)
        }
    }
}

# No make.exe -> mingw32-make.exe alias any more: a native make cannot read the POSIX paths configure writes, and the
# alias shadowed the right make in vcpkg's ffmpeg build. Use { "name": "make", "repo": "msys" } (/usr/bin).

Write-Info "STEP 5: OK"

# STEP 6: Export the packages list.
# --------------------------------------------------------------------

Write-Info "STEP 6: Export the packages list."

$msysEnvUpper = $msysEnv.ToUpperInvariant()
$baseFileName = $names.PackagesExport

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

# Build simple report (name version): this toolchain's prefix and the shared msys base only. Not wrapped in @().
$ownPackages = Select-DrivEnvToolchainPackages -Lines ([string[]]@($pacmanOutput)) -Prefix $msysSub.Prefix
$reportLines = @()
$reportLines += "==============================================================="
$reportLines += "MSYS2 $msysEnvUpper ENVIRONMENT - PACKAGE LIST (pacman -Q)"
$reportLines += "==============================================================="
$reportLines += "# Format: <name> <version>"
$reportLines += "# This toolchain's packages ($($msysSub.Prefix)-*) and the msys base every toolchain shares."
$reportLines += "==============================================================="
$reportLines += $ownPackages

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

$msys2PathNorm = $msys2Path -replace '\\', '/'
# BASE_PATH: the toolchain first; the Windows system directories always at the tail (native tools reach cmd.exe
# through popen, vcpkg needs powershell.exe), where nothing in them can shadow the toolchain.
$basePath = "/{0}/bin:/usr/local/bin:/usr/bin:/bin" -f $msysEnv

$sysRootPosix = (Convert-ToMSYSPath ([string]$env:SystemRoot)) -replace '/$', ''
$sysRootPosix = [regex]::Replace($sysRootPosix, '^/([A-Za-z])/', { param($m) "/" + $m.Groups[1].Value.ToLowerInvariant() + "/" })
if ([string]::IsNullOrWhiteSpace($sysRootPosix)) { $sysRootPosix = "/c/Windows" }

$basePath = "{0}:{1}/System32:{1}:{1}/System32/Wbem:{1}/System32/WindowsPowerShell/v1.0" -f $basePath, $sysRootPosix
Write-Info "Windows system directories appended to BASE_PATH (System32, Wbem, WindowsPowerShell)."

# append_windows_system_path adds the rest of the host PATH. Off by default: it makes the drive depend on the host.
$appendWindowsPath = $false
if ($Cfg.environment.PSObject.Properties.Name -contains "append_windows_system_path")
{
    $appendWindowsPath = [bool]$Cfg.environment.append_windows_system_path
}

if ($appendWindowsPath)
{
    # The host PATH is whatever shell started this run. From inside a DrivEnv environment it is that environment's,
    # which is not what anyone means by "the machine's PATH"; entries on this drive are skipped below, but anything
    # else that session added comes along. Said, so the result is not a surprise.
    if ($env:DEVSYSTEM_TOOLCHAIN_ID)
    {
        Write-Warn ("This run was started from inside the '{0}' environment, so the host PATH appended to BASE_PATH is that session's. Run from a plain Windows shell for the machine's own." -f $env:DEVSYSTEM_TOOLCHAIN_ID)
    }

    # Only entries that are not already present, and only ones that still exist, so a stale user PATH does not
    # fill BASE_PATH with directories that are not there.
    $extra = @()
    foreach ($winEntry in (([string]$env:PATH) -split ';'))
    {
        $trimmed = $winEntry.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if (-not (Test-Path -LiteralPath $trimmed -ErrorAction SilentlyContinue)) { continue }

        # Never this drive's own directories: from inside one of its shells they would bring the other toolchain in.
        if (Test-DrivEnvPathUnder -Path $trimmed -Root $devDrive) { continue }

        $posix = (Convert-ToMSYSPath $trimmed) -replace '/$', ''
        $posix = [regex]::Replace($posix, '^/([A-Za-z])/', { param($m) "/" + $m.Groups[1].Value.ToLowerInvariant() + "/" })
        if ([string]::IsNullOrWhiteSpace($posix)) { continue }
        if (($basePath -split ':') -contains $posix) { continue }
        if ($extra -contains $posix) { continue }

        $extra += $posix
    }

    if ($extra.Count -gt 0)
    {
        $basePath = "{0}:{1}" -f $basePath, ($extra -join ':')
        Write-Info ("The rest of the host PATH appended too: {0} entries (environment.append_windows_system_path)." -f $extra.Count)
    }
    else
    {
        Write-Info "environment.append_windows_system_path is true, but the host PATH added nothing new."
    }
}
else
{
    Write-Info "The rest of the host PATH was NOT appended (environment.append_windows_system_path = false)."
}

Write-Info ("BASE_PATH={0}" -f $basePath)

# Prepare environment variable export file
if (-not (Test-Path $envFilePath)) 
{
    New-Item -Path $envFilePath -ItemType File -Force | Out-Null
}

# The msys2 block, from Get-DrivEnvMsys2EnvValues: the public contract (DEVSYSTEM_TOOLCHAIN*, explained there), the
# MSYS2 layout and BASE_PATH. Built by the same function the tests compose a file with, and DEVSYSTEM_TOOLCHAIN_ID and
# MSYS2_ENV are the toolchain KEY -- what steps 3 to 5 check the file against -- not this run's profile id.
$msys2Values = Get-DrivEnvMsys2EnvValues -Key $names.Key -Family ([string]$msysSub.Family) -Msys2Root $msys2PathNorm -BasePath $basePath
foreach ($key in $msys2Values.Keys) { Write-Info ("{0}={1}" -f $key, $msys2Values[$key]) }

# Written as a named section, so a re-run replaces its block instead of appending it again.
Write-Info "Writing environment variables to $envFilePath"

# The drive header (DEVDRIVE_*, DEVSYSTEM_NAME/DEPLOYS/WORKSPACE) first: later lines reference it through ${...}.
$driveValues = Get-DrivEnvDriveEnvValues -Cfg $Cfg
if ($null -eq $driveValues)
{
    Write-Error "Cannot write the drive header: environment.dev_drive_letter is blank or workspace.default_folder is not a folder on the drive."
    Abort-WithError
}
Set-DrivEnvFileValues -Path $envFilePath -Values $driveValues -Section "drive" -First

# -Retire names what this block used to write. MINGW_ROOT was removed from the list above, and on a drive
# generated before the fences existed that is not enough to make it go: there is no marked block to
# replace, so the orphaned line just stays. Measured on a real drive, which had two of them.
Set-DrivEnvFileValues -Path $envFilePath -Values $msys2Values -Section "msys2" -Retire @("MINGW_ROOT")

# THIS TOOLCHAIN'S LAUNCHER SET, deployed on every run so the scripts on the drive always match the generator that
# last touched it. <stem>_env_launcher.bat finds <stem>_env_variables.env by its own name; see
# Install-DrivEnvLauncherSet. Step 1 used to copy one unsuffixed set, once.
try
{
    Install-DrivEnvLauncherSet -TemplateDir (Join-Path $drivEnvRoot "drive\launchers") -Names $names -Report { param($m) Write-Info $m }
}
catch
{
    Write-Error ("Could not deploy the launcher set: {0}" -f $_.Exception.Message)
    Abort-WithError
}

# Shortcuts, named with the toolchain key like the launcher. $targetPath is shared and set outside the guard: the
# drive-root shortcut is not optional.
$targetPath = $names.Launcher
if (-not (Test-Path -LiteralPath $targetPath))
{
    Write-Warn "The launcher the shortcuts point at is missing: $targetPath"
}

# Presence first, then cast: absent means TRUE here, and a bare [bool] of a missing property is $false. Read
# beside its only use rather than with the other flags at the top, because this is the only place it matters.
$createDesktopShortcuts = $true
if ($Cfg.environment.PSObject.Properties.Name -contains "create_desktop_shortcuts")
{
    $createDesktopShortcuts = [bool]$Cfg.environment.create_desktop_shortcuts
}

$shortcutPath = [System.IO.Path]::Combine([Environment]::GetFolderPath("Desktop"), $names.DesktopShortcutName)

if ($createDesktopShortcuts)
{
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
}
else
{
    # Matched on target, not on name, for the same reason step 1 does it: the file is named after the
    # environment and this generator should only delete what it can show it wrote.
    if (Test-Path $shortcutPath)
    {
        try
        {
            $probe = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
            if ($probe.TargetPath -eq $targetPath)
            {
                Remove-Item $shortcutPath -Force
                Write-Info "Desktop shortcuts not requested (environment.create_desktop_shortcuts = false); removed '$shortcutPath'."
            }
            else
            {
                Write-Warn "'$shortcutPath' exists but points at '$($probe.TargetPath)', not at this environment's launcher. Left alone."
            }
        }
        catch
        {
            Write-Warn ("Could not inspect '{0}', so it was left alone: {1}" -f $shortcutPath, $_.Exception.Message)
        }
    }
    else
    {
        Write-Info "Desktop shortcuts not requested (environment.create_desktop_shortcuts = false); nothing created on the desktop."
    }
}

# NOT OPTIONAL, and not governed by a key named after the desktop: this one lands on the generated drive itself.
# It is part of the artifact -- it is what makes a drive handed to somebody else explain how to enter it -- and
# it costs a kilobyte on a volume measured in gigabytes.
$shortcutPath = $names.DriveShortcut
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

# Exit. Copy the log before the prompt: in a non-interactive run nothing after it executes.
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
