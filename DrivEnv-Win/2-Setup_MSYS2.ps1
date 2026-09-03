# ====================================================================
# MSYS2 SETUP SCRIPT
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
#          David Abuín Sánchez
# Updated: 26/08/2026
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
    # @brief A warning line, in the same shape as Write-Info and Write-Error and mirrored into the log.
    #
    # This script called Write-Warn in three places and defined it in none, so each was a
    # CommandNotFoundException instead of a warning. Same omission as 1-Setup_DevDrive.ps1 had; steps 3
    # through 6 all define it.
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
    # lines below never run: the window title is left changed and the deliberate `exit 1` is replaced by an unhandled
    # PowerShell error. Verified on this machine: UserInteractive=True with stdin redirected, ReadKey throws.
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
    # @brief Record the pinned packages in pacman's IgnorePkg, so a later "pacman -Syu" leaves them alone.
    #
    # Pinning without this is only half a pin. The configuration installs an exact version from a downloaded
    # .pkg.tar.zst with pacman -U, and nothing then stops the next routine upgrade from replacing it with
    # whatever is current -- which is precisely the situation that pinning exists to avoid. A developer running
    # "pacman -Syu" inside the environment is a normal thing to do, not a mistake to guard against.
    #
    # WHAT PACMAN ACTUALLY DOES with an ignored package, because the behaviour is easy to over-promise:
    #   - a plain upgrade prints "warning: <pkg>: ignoring package upgrade" and skips it. That is the case
    #     this exists for, and it works.
    #   - if some OTHER package being installed requires a newer version of an ignored one, pacman reports a
    #     dependency error instead of silently upgrading it. Refusing to proceed is the right outcome, but it
    #     is an error the developer has to resolve rather than something this can prevent.
    #   - IgnorePkg does not survive being edited away by hand, and it does not pin transitive dependencies.
    #     Pinning a package does not freeze what it links against.
    #
    # Written by REPLACING the IgnorePkg line pacman.conf already ships commented out, rather than appending,
    # so re-running the generator cannot accumulate duplicates and the file keeps the layout pacman expects
    # (IgnorePkg has to live inside [options]).
    param(
        [Parameter(Mandatory=$true)][string]$Msys2Root,
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][string[]]$Packages
    )

    $confPath = Join-Path $Msys2Root "etc\pacman.conf"
    if (-not (Test-Path $confPath))
    {
        Write-Warn "pacman.conf not found at '$confPath'; pinned packages will not be protected from upgrades."
        return
    }

    if ($Packages.Count -eq 0)
    {
        Write-Info "No pinned packages, so IgnorePkg is left as it is."
        return
    }

    $wanted = ($Packages | Sort-Object -Unique) -join " "
    $marker = "# DrivEnv: pinned by the configuration, kept from being upgraded by pacman -Syu."
    $newLine = "IgnorePkg   = $wanted"

    $lines = @(Get-Content $confPath)
    $out = @()
    $done = $false

    foreach ($line in $lines)
    {
        # Our own marker from a previous run: drop it, the replacement below re-adds it.
        if ($line -eq $marker) { continue }

        if (-not $done -and $line -match '^\s*#?\s*IgnorePkg\s*=')
        {
            $out += $marker
            $out += $newLine
            $done = $true
            continue
        }

        $out += $line
    }

    if (-not $done)
    {
        # No IgnorePkg line at all, commented or otherwise. Put one directly under [options], which is the
        # only section where pacman reads it.
        $out = @()
        foreach ($line in $lines)
        {
            if ($line -eq $marker) { continue }
            $out += $line
            if (-not $done -and $line -match '^\s*\[options\]\s*$')
            {
                $out += $marker
                $out += $newLine
                $done = $true
            }
        }
    }

    if (-not $done)
    {
        Write-Warn "pacman.conf has no [options] section; pinned packages will not be protected from upgrades."
        return
    }

    Set-Content -Path $confPath -Value $out -Encoding ASCII
    Write-Info ("IgnorePkg set for {0} pinned package(s): {1}" -f $Packages.Count, $wanted)
}

# Resolves the MSYS2 target into the THREE DIFFERENT NAMES a subsystem has, which the configuration used to
# conflate into one "profile" value.
#
# They are genuinely three things, and only two of them can be derived from each other:
#
#   SUBSYSTEM       the MSYSTEM value and the install directory      CLANG64  -> /clang64
#   REPO SUBPATH    where the packages live on repo.msys2.org        mingw/clang64
#   PACKAGE PREFIX  what a package is actually called                mingw-w64-clang-x86_64-<name>
#
# The old derivation was PkgName = "mingw-w64-<profile>-<arch>-" and RepoPath = "mingw/<profile>64". That is
# correct for exactly the two subsystems in use and wrong for the others, which is the kind of bug that only
# shows up the day somebody targets one. Verified against repo.msys2.org, one HTTP request per subsystem:
#
#   ucrt64       mingw-w64-ucrt-x86_64      mingw/ucrt64
#   clang64      mingw-w64-clang-x86_64     mingw/clang64
#   mingw64      mingw-w64-x86_64           mingw/mingw64        <- NO infix at all
#   clangarm64   mingw-w64-clang-aarch64    mingw/clangarm64     <- subpath is not <infix>64
#   mingw32      mingw-w64-i686             mingw/mingw32
#   clang32      mingw-w64-clang-i686       mingw/clang32
#
# So mingw64 would have been asked for "mingw-w64-mingw-x86_64-<name>", which does not exist, and clangarm64
# would have been looked for under mingw/clang64, which is the wrong architecture's repository.
#
# The configuration normally names ONE thing, msys2.target.subsystem, and the rest comes from this table.
# msys2.target.profile still works and means what it always did -- subsystem = "<profile>64" -- so no existing
# configuration changes behaviour. package_prefix and repo_subpath are there as explicit overrides for a
# subsystem MSYS2 adds after this table was written.
function Resolve-Msys2Subsystem($Target)
{
    $keys = @()
    if ($null -ne $Target) { $keys = @($Target.PSObject.Properties | ForEach-Object { $_.Name }) }

    $subsystem = ""
    if ($keys -contains 'subsystem') { $subsystem = ([string]$Target.subsystem).Trim().ToLowerInvariant() }

    if ([string]::IsNullOrWhiteSpace($subsystem))
    {
        # Legacy shape. "clang" meant clang64, "ucrt" meant ucrt64, and both are still spelled that way in
        # configurations written before this function existed.
        $profile = ""
        if ($keys -contains 'profile') { $profile = ([string]$Target.profile).Trim().ToLowerInvariant() }
        if ([string]::IsNullOrWhiteSpace($profile))
        {
            Write-Error "Missing msys2.target.subsystem (or the legacy msys2.target.profile)"
            Abort-WithError
        }
        $subsystem = "{0}64" -f $profile
    }

    $table = @{
        'ucrt64'     = @{ Prefix = 'mingw-w64-ucrt-x86_64';   Subpath = 'mingw/ucrt64';     Arch = 'x86_64'  }
        'clang64'    = @{ Prefix = 'mingw-w64-clang-x86_64';  Subpath = 'mingw/clang64';    Arch = 'x86_64'  }
        'mingw64'    = @{ Prefix = 'mingw-w64-x86_64';        Subpath = 'mingw/mingw64';    Arch = 'x86_64'  }
        'clangarm64' = @{ Prefix = 'mingw-w64-clang-aarch64'; Subpath = 'mingw/clangarm64'; Arch = 'aarch64' }
        'mingw32'    = @{ Prefix = 'mingw-w64-i686';          Subpath = 'mingw/mingw32';    Arch = 'i686'    }
        'clang32'    = @{ Prefix = 'mingw-w64-clang-i686';    Subpath = 'mingw/clang32';    Arch = 'i686'    }
    }

    $prefix  = ""
    $subpath = ""
    $arch    = ""

    if ($table.ContainsKey($subsystem))
    {
        $prefix  = $table[$subsystem].Prefix
        $subpath = $table[$subsystem].Subpath
        $arch    = $table[$subsystem].Arch
    }

    # Explicit overrides win over the table, and are the only way to reach a subsystem it does not list.
    if ($keys -contains 'package_prefix')
    {
        $v = ([string]$Target.package_prefix).Trim()
        if (-not [string]::IsNullOrWhiteSpace($v)) { $prefix = $v }
    }
    if ($keys -contains 'repo_subpath')
    {
        $v = ([string]$Target.repo_subpath).Trim().Trim('/')
        if (-not [string]::IsNullOrWhiteSpace($v)) { $subpath = $v }
    }
    if ($keys -contains 'arch')
    {
        $v = ([string]$Target.arch).Trim()
        if (-not [string]::IsNullOrWhiteSpace($v)) { $arch = $v }
    }

    if ([string]::IsNullOrWhiteSpace($prefix) -or [string]::IsNullOrWhiteSpace($subpath))
    {
        Write-Error "msys2.target.subsystem '$subsystem' is not one this script knows, and neither"
        Write-Error "msys2.target.package_prefix nor msys2.target.repo_subpath was given to describe it."
        Write-Error "Known subsystems: $(($table.Keys | Sort-Object) -join ', ')."
        Abort-WithError
    }

    return @{ Subsystem = $subsystem; Prefix = $prefix; Subpath = $subpath; Arch = $arch }
}

# Resolves one JSON package entry into the three things pacman and the downloader need: the real package name, the
# repository sub-path, and the architecture tag its file name carries.
#
# MSYS2 ships TWO kinds of package and they are not interchangeable:
#
#   mingw  (default) -> <package_prefix>-<name>, native Windows binaries, land in /<subsystem>/bin.
#   msys             -> <name> verbatim, built against the MSYS2 POSIX runtime, land in /usr/bin.
#
# The distinction matters beyond naming. A tool that has to understand POSIX paths -- notably `make`, which reads
# them out of a configure-generated Makefile -- only works as the MSYS build. The native one treats /x/foo as a
# nonexistent relative path. Requesting a package by the wrong repo yields a tool that is subtly wrong rather than
# missing, which is far harder to diagnose.
#
# Absent "repo" means "mingw", so every existing configuration keeps its exact behaviour.
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
                PkgName  = $name
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
                PkgName  = "{0}-{1}" -f $sub.Prefix, $name
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
    # @brief Run a pacman operation, retrying it a bounded number of times. Returns the exit code of the last attempt.
    #
    # Any pacman operation that downloads can fail for a reason that has nothing to do with this environment: a mirror
    # that stalls at zero bytes per second, a .sig file that 404s, a connection reset halfway through. Those are
    # transient, and pacman is built to survive them -- partial downloads stay in its cache and --needed skips what is
    # already installed -- so retrying costs seconds and turns a failed run into a completed one. Without a retry the
    # whole step aborts and a person re-runs it by hand, which is the same thing done slower.
    #
    # --disable-download-timeout is passed always, never per call site. Without it pacman hands curl a minimum-speed
    # rule and aborts the entire transaction when a mirror drops below it for ten seconds -- a property of the mirror,
    # not of the package being fetched.
    param
    (
        [Parameter(Mandatory=$true)][string]$BashPath,
        [Parameter(Mandatory=$true)][string]$Arguments,
        [int]$Attempts     = 3,
        [int]$DelaySeconds = 5
    )

    $code = 1
    for ($try = 1; $try -le $Attempts; $try++)
    {
        if ($try -gt 1) { Write-Info "pacman attempt $try of $Attempts..." }

        $code = Invoke-Msys2Bash -BashPath $BashPath -Command ("pacman --disable-download-timeout " + $Arguments)
        if ($code -eq 0) { return 0 }

        if ($try -lt $Attempts)
        {
            Write-Info "pacman failed with exit code $code. Retrying in $DelaySeconds seconds."
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $code
}

function Configure-MSYS2Terminal
{
    # @brief Give the drive's mintty a readable default configuration.
    #
    # WHY THIS EXISTS. The launcher hosts the shell in mintty rather than the Windows console, because conhost
    # cannot deliver a bracketed paste and costs about a hundred times more per redisplayed character. mintty is
    # the right terminal and its stock configuration is not: MSYS2 ships /etc/minttyrc with three lines
    # (Columns, Rows, Term) and leaves the font at a default that renders poorly.
    #
    # BoldAsFont is the setting that matters most and the least obvious. conhost mostly rendered the bold
    # attribute as a BRIGHTER COLOUR; mintty renders it as a genuine bold weight, and a synthesised bold at a
    # small size is exactly the smeared, ill-defined text somebody notices immediately after the switch. Setting
    # it to "no" restores the behaviour the console had, for the prompt and for every compiler diagnostic that
    # uses bold as well.
    #
    # /etc/minttyrc and not ~/.minttyrc, on purpose: HOME is the Windows profile, shared by every MSYS2
    # installation on the machine, and this file is a property of THIS drive. mintty reads /etc/minttyrc first and
    # ~/.minttyrc second, so a developer who wants something else still has the last word.
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

    # 3) Proxy for GIT, and this one is not redundant with (1).
    #
    # The profile.d script above only reaches a shell that sources /etc/profile -- which the launcher does and the
    # SETUP STEPS DO NOT: they invoke git.exe from PowerShell directly. Step 3 clones vcpkg that way, and step 6
    # clones the configured repositories the same way, so without this file both of them go straight at the remote
    # and time out behind a proxy.
    #
    # It works today on the developer machine this was written on only by accident: the drive's git falls back to
    # the personal C:/Users/<user>/.gitconfig, which happens to carry http.proxy. That is exactly the kind of
    # dependency on the host that this generator exists to remove -- on a clean machine there is nothing there.
    #
    # etc/gitconfig is the SYSTEM configuration for every git on the drive; both msys64/usr/bin/git.exe and
    # msys64/<env>/bin/git.exe read it, and the path is not a guess: an unconfigured drive's git reports
    # "cannot read config file 'S:/msys64/etc/gitconfig'" when asked for its system settings. A user's own
    # ~/.gitconfig still overrides it, which is the right precedence -- the drive states a default, the developer
    # keeps the last word.
    Write-Info "Configuring git proxy for the drive..."

    $gitConfigPath = Join-Path $Msys2Root "etc\gitconfig"

    $gitConfigLines = @(
        "# DevSystem - git system configuration for this drive."
        "# Written by 2-Setup_MSYS2.ps1 from environment.proxy_url. Edit the JSON, not this file:"
        "# regenerating the environment overwrites it."
        "[http]"
        "`tproxy = $Proxy"
    )

    Set-Content -Path $gitConfigPath -Encoding ASCII -Value $gitConfigLines
    Write-Info "git system config created at: $gitConfigPath"
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

if ($ValidateOnly)
{
    Write-Info "-ValidateOnly was given, so nothing further will run."
    if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }
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
#   mingw -> {base_url}/{repo_subpath}/{package_prefix}-{name}-{version}-any.pkg.tar.zst
#   msys  -> {base_url}/msys/{arch}/{name}-{version}-{arch}.pkg.tar.zst
#
# repo_subpath and package_prefix both come from $msysSub, resolved once near the top of this script, rather
# than being rebuilt from the profile here. They are not interchangeable: mingw64's packages carry no infix at
# all and clangarm64's sub-path is not "<infix>64".
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

$coreUpdateScript = Join-Path $env:TEMP "upgrade_core.sh"
Set-Content -Path $coreUpdateScript -Encoding ASCII -Value @'
pacman -Sy --noconfirm --disable-download-timeout
pacman -Su --noconfirm --disable-download-timeout
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
$gitPkgName = "{0}-git" -f $msysSub.Prefix
Write-Info "Installing git (latest): $gitPkgName"
$code = Invoke-Pacman -BashPath $bashPath -Arguments "-S --noconfirm --needed $gitPkgName"
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

# IgnorePkg goes in HERE, between the two installs, and the order is deliberate.
#
# pacman -Sy and -Su ran earlier in this script, so the pinned versions installed just above are current as of
# this run. What follows is "pacman -S" for the latest-mode packages, and that resolves dependencies: without
# IgnorePkg already in place, installing one of those could pull an upgrade of a package this configuration
# just pinned, inside the very same run. Setting it before that command closes the window as well as
# protecting the developer's later upgrades.
$pinnedNames = @()
foreach ($p in $msysPackages)
{
    if (([string]$p.mode).Trim().ToLowerInvariant() -ne "pinned") { continue }
    $pinnedNames += (Resolve-Msys2Package $p $msysSub).PkgName
}
Set-Msys2IgnorePkg -Msys2Root $msys2Path -Packages $pinnedNames

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

# GCC AND G++ DRIVER ALIASES, on a clang subsystem only.
#
# Plenty of build systems have "gcc" written into them rather than asking $CC, and MSYS2's clang package does
# not provide it. ffmpeg is the one that found this: libswscale/x86/Makefile generates an .asm file with
# $(HOSTCC), ffmpeg's configure defaults HOSTCC to "gcc" because vcpkg's port passes --cc but never --host-cc,
# and the build dies with
#     make: gcc: No such file or directory
#     make: *** [libswscale/x86/Makefile:35: libswscale/x86/uops_macros.gen.asm] Error 127
# after several minutes of successful compiling. It fails identically at concurrency 1, so it reads like a
# resource problem and is not: a binary is simply missing.
#
# COPIES OF THE CLANG DRIVER, and that works because clang chooses its personality from argv[0] -- exactly the
# mechanism by which the clang package itself ships cc.exe and c++.exe, three independent copies of the same
# 164 KB driver. (pacman -Qo denies owning them, which is misleading: it does not resolve paths under a mingw
# prefix. pacman -Ql on the clang package lists them.)
#
# Recreated on EVERY run, unconditionally, because a copy goes stale: a later pacman upgrade replaces
# clang.exe and leaves any copy of it behind at the old version. Copying each time is cheap and self-healing.
#
# The honest caveat: naming clang "gcc" does not fool a configure test that asks for a version -- it answers
# "clang version ..." -- but it can mislead a build system that assumes GCC-specific flags after finding a
# binary by that name. ffmpeg only needed a compiler that compiles. A port that needs more than that is better
# served by an overlay passing --host-cc explicitly.
if ($msysSub.Subsystem -like "clang*")
{
    $clangBin = Join-Path (Join-Path $msys2Path $msysSub.Subsystem) "bin"

    foreach ($pair in @(@{ From = "clang.exe"; To = "gcc.exe" }, @{ From = "clang++.exe"; To = "g++.exe" }))
    {
        $src = Join-Path $clangBin $pair.From
        $dst = Join-Path $clangBin $pair.To

        if (-not (Test-Path -LiteralPath $src))
        {
            Write-Warn ("{0} not found in {1}; skipping the {2} alias." -f $pair.From, $clangBin, $pair.To)
            continue
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

# THE FOUR WINDOWS SYSTEM DIRECTORIES ARE NOT OPTIONAL, and this used to be controlled by
# environment.append_windows_system_path, which is why they were sometimes missing.
#
# The tools in them are not conveniences, they are things the build system reaches for:
#
#   powershell.exe   vcpkg's own bootstrap-vcpkg.bat downloads the vcpkg tool with it, and several ports
#                    invoke it during their build
#   cmd.exe          shelled out to by makefiles and by ninja rules more often than anyone would like
#   where.exe        used by configure scripts to locate tools
#
# With the flag set to false, NONE of them was reachable from the environment's terminal. Verified on a
# generated drive: with the PATH the .env imposes, "command -v powershell.exe" and the same for cmd.exe and
# where.exe all report nothing. An environment that cannot run vcpkg by hand is not hermetic, it is broken --
# and the failure surfaces as "powershell is not recognised" halfway through a vcpkg bootstrap, which points
# nowhere near this file.
#
# They still go at the TAIL, which is what makes this safe: nothing in System32 can shadow the toolchain. That
# ordering is the reason the flag existed at all, and it is preserved -- the make.exe incident this file warns
# about above was a shadowing problem, not a presence problem.
#
# Lower-cased drive letter to match cygpath's canonical form and the rest of this file. MSYS2 resolves /C/ and
# /c/ alike -- verified -- so this is consistency, not correctness.
$sysRootPosix = (Convert-ToMSYSPath ([string]$env:SystemRoot)) -replace '/$', ''
$sysRootPosix = [regex]::Replace($sysRootPosix, '^/([A-Za-z])/', { param($m) "/" + $m.Groups[1].Value.ToLowerInvariant() + "/" })
if ([string]::IsNullOrWhiteSpace($sysRootPosix)) { $sysRootPosix = "/c/Windows" }

$basePath = "{0}:{1}/System32:{1}:{1}/System32/Wbem:{1}/System32/WindowsPowerShell/v1.0" -f $basePath, $sysRootPosix
Write-Info "Windows system directories appended to BASE_PATH (System32, Wbem, WindowsPowerShell)."

# environment.append_windows_system_path now governs the REST of the machine's PATH -- everything a developer
# happens to have installed -- which is the part that is genuinely a matter of taste. Off by default, because
# an environment that inherits whatever is on the host stops being reproducible, and because an inherited entry
# ahead of nothing is still one more place a stray tool of the same name can come from.
$appendWindowsPath = $false
if ($Cfg.environment.PSObject.Properties.Name -contains "append_windows_system_path")
{
    $appendWindowsPath = [bool]$Cfg.environment.append_windows_system_path
}

if ($appendWindowsPath)
{
    # Only entries that are not already present, and only ones that still exist, so a stale user PATH does not
    # fill BASE_PATH with directories that are not there.
    $extra = @()
    foreach ($winEntry in (([string]$env:PATH) -split ';'))
    {
        $trimmed = $winEntry.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if (-not (Test-Path -LiteralPath $trimmed -ErrorAction SilentlyContinue)) { continue }

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
# ABOVE the prompt below, not after it: UserInteractive is True even with stdin redirected, and ReadKey then
# throws instead of waiting -- the trap Abort-WithError already documents. Anything after the prompt is
# skipped in precisely the non-interactive case where this copy is the only record anybody will have.
if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }

if ([Environment]::UserInteractive) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
}
$host.UI.RawUI.WindowTitle = $originalTitle

# --------------------------------------------------------------------
