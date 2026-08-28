# ====================================================================
# WORKSPACE REPOSITORIES CLONE SCRIPT
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
# Updated: 28/08/2026
# Version: 1.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Prerequisites: steps 1 and 2 must have completed, because this reads
# the environment file they produced (<drive>:\env\<dev_env_name>_env
# _variables.env) for the MSYS2 layout and the drive root.
#
# WHAT THIS STEP IS FOR. Everything before it produces a drive; this
# puts the projects on it. The configuration names repositories, this
# clones them, and that is the whole scope.
#
# WHAT IT DELIBERATELY DOES NOT DO: build anything, or run anything the
# configuration names. That was considered and rejected. A configuration
# file that both names remote repositories AND names a script to run
# after fetching them is a way to execute arbitrary code on whoever
# generates the drive, and step 1 self-elevates. Separately, and more
# mundanely: a project that fails to build is not a broken drive, and a
# step that conflates the two teaches people to ignore its failures,
# which is the worst outcome available. Build your projects from the
# launcher, where a red build means what it says.
#
# FAILURE SEMANTICS, which follow from that:
#   a repository that will not clone     -> this step fails (exit 1)
#   ... unless it is marked "optional"   -> warning, step still passes
#   a repository already cloned          -> skipped, reported, no fetch
#   no 'workspace' section at all        -> nothing to do, exit 0
# Nothing here can make the drive itself invalid. It either has the
# projects on it or it does not.
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
    # Every step takes the same switch and must be given the SAME file: they hand state to each other through the
    # generated .env on the dev drive, and mixing configs between steps produces an environment that matches neither.
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief Validate the configuration and stop, changing nothing.
    #
    # The validation runs on every invocation regardless; this switch only stops the script afterwards.
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
    Write-Host $line -ForegroundColor Yellow
    if ($globalLogFile) {Add-Content -Path $globalLogFile -Value $line}
}

function Write-Error
{
    param ($msg)
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][ERROR][$msg]"
    Write-Host $line -ForegroundColor Red
    if ($globalLogFile) {Add-Content -Path $globalLogFile -Value $line}
}

function Abort-WithError
{
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][ERROR][Setup failed!]"
    Write-Host $line
    if ($globalLogFile){Add-Content -Path $globalLogFile -Value $line}

    # UserInteractive alone is NOT enough. It reports True for any process in a normal user session, including one
    # launched from another script with its input redirected -- and there ReadKey THROWS instead of waiting.
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
    if ($PSScriptRoot) { return $PSScriptRoot }
    else { return Split-Path -Parent (Convert-Path -LiteralPath ([System.Environment]::GetCommandLineArgs()[0])) }
}

function Convert-ToMSYSPath($winPath)
{
    return $winPath -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
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

function Get-RepoNameFromUrl
{
    # @brief The directory name a repository gets when the configuration does not name one.
    #
    # The last path segment with any .git suffix removed, which is what `git clone` itself would choose. Handles
    # both https://host/org/name.git and git@host:org/name.git, and tolerates a trailing slash.
    param ([string]$Url)

    $u = ([string]$Url).Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($u)) { return $null }

    # scp-style git@host:org/name and url-style alike: everything after the last / or :
    $seg = $u -split '[/:]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($seg)) { return $null }

    if ($seg.EndsWith(".git", [System.StringComparison]::OrdinalIgnoreCase))
    {
        $seg = $seg.Substring(0, $seg.Length - 4)
    }

    return $seg
}

function Test-SafeRelativePath
{
    # @brief Whether a configured folder stays on the drive.
    #
    # Rejects absolute paths, drive-qualified paths and anything climbing out with "..". The destination is meant to
    # be somewhere on the generated drive; a config that can write anywhere on the host is a different feature with
    # a different risk profile, and not this one.
    param ([string]$Relative)

    $r = ([string]$Relative).Trim() -replace '\\', '/'
    if ([string]::IsNullOrWhiteSpace($r))          { return $false }
    if ($r -match '^[A-Za-z]:')                    { return $false }
    if ($r.StartsWith('/'))                        { return $false }
    if (($r -split '/') -contains '..')            { return $false }

    return $true
}

function Get-RepoField
{
    # @brief Read an optional per-repository field, returning $null when it is absent.
    #
    # Index-style membership rather than a bare dot: a PSCustomObject returns $null for a missing property, but the
    # explicit test keeps "absent" and "present but empty" distinguishable, which is what the defaults below need.
    param ($Repo, [string]$Name)

    if ($null -eq $Repo) { return $null }
    if ($Repo.PSObject.Properties.Name -contains $Name) { return $Repo.$Name }
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

if (-not $Cfg.environment) { Write-Error "Missing 'environment' object in config JSON: $ConfigPath"; Abort-WithError }

# Environment section
$driveLetter = [string]$Cfg.environment.dev_drive_letter
$devEnvName  = [string]$Cfg.environment.dev_env_name
$proxyUrl    = [string]$Cfg.environment.proxy_url

if ([string]::IsNullOrWhiteSpace($driveLetter)) { Write-Error "Missing environment.dev_drive_letter"; Abort-WithError }
if ([string]::IsNullOrWhiteSpace($devEnvName))  { Write-Error "Missing environment.dev_env_name";     Abort-WithError }

$driveLetter = $driveLetter.Trim().TrimEnd(':').ToUpperInvariant()
if ($driveLetter -notmatch '^[A-Z]$')
{
    Write-Error "Invalid environment.dev_drive_letter (expected a single letter): $driveLetter"
    Abort-WithError
}

$devDrive = "{0}:\" -f $driveLetter

# Workspace section. Entirely optional: a configuration that names no repositories is valid and this step is then a
# no-op, which is the right behaviour for an environment somebody populates by hand.
$defaultFolder = "workspace"
$repos         = @()

if ($Cfg.workspace)
{
    $configuredDefault = [string]$Cfg.workspace.default_folder
    if (-not [string]::IsNullOrWhiteSpace($configuredDefault)) { $defaultFolder = $configuredDefault.Trim() }

    if ($Cfg.workspace.repositories) { $repos = @($Cfg.workspace.repositories) }
}

if (-not (Test-SafeRelativePath $defaultFolder))
{
    Write-Error "Invalid workspace.default_folder: '$defaultFolder'"
    Write-Error "It must be a path relative to the drive root, with no drive letter and no '..' segment."
    Abort-WithError
}

# Environment file written by steps 1 and 2 (single source of truth for the MSYS2 layout)
$envFilePath = Join-Path "$driveLetter`:" (("env/{0}_env_variables.env" -f $devEnvName).ToLower())

# INITIAL PREPARATION
# --------------------------------------------------------------------

$scriptStart = Get-Date
$scriptDir   = Get-ScriptDirectory

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir = Join-Path $scriptDir "install_logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile = Join-Path $logsDir "${timestamp}_workspace-repos-clone.log"

$originalTitle = $host.UI.RawUI.WindowTitle
$host.UI.RawUI.WindowTitle = "WORKSPACE REPOSITORIES CLONE SCRIPT"

# SCRIPT STARTUP HEADER
# --------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($proxyUrl)) { $proxyDisplay = "(none)" } else { $proxyDisplay = $proxyUrl }

Write-NoFormat "================================================================="
Write-NoFormat "  WORKSPACE REPOSITORIES CLONE SCRIPT"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "  Authors: Angel Vera Herrera"
Write-NoFormat "  Updated: 28/08/2026"
Write-NoFormat "  Version: 1.0.0"
Write-NoFormat "================================================================="
Write-NoFormat "Parameters (Loaded from JSON):"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "Drive Letter     = $devDrive"
Write-NoFormat "Dev Env Name     = $devEnvName"
Write-NoFormat "Env File         = $envFilePath"
Write-NoFormat "Default Folder   = $defaultFolder"
Write-NoFormat "Repositories     = $($repos.Count)"
Write-NoFormat "Proxy            = $proxyDisplay"
Write-NoFormat "Current Path     = $scriptDir"
Write-NoFormat "================================================================="

# STEP 1: Initial checks and preparations.
# --------------------------------------------------------------------

Write-Info "STEP 1: Initial checks and preparations."

if (-not (Test-Path -LiteralPath $devDrive))
{
    Write-Error "The dev drive is not present: $devDrive"
    Write-Error "Run 1-Setup_DevDrive.ps1 first, or mount the drive."
    Abort-WithError
}

if (-not (Test-Path -LiteralPath $envFilePath))
{
    Write-Error "Environment file not found: $envFilePath"
    Write-Error "Steps 1 and 2 must have completed before this one."
    Abort-WithError
}

$envMap    = Read-EnvFile -Path $envFilePath
$mingwRoot = [string]$envMap["MINGW_ROOT"]
$msys2Root = [string]$envMap["MSYS2_ROOT"]
$msys2Bash = [string]$envMap["MSYS2_BASH"]

if ([string]::IsNullOrWhiteSpace($msys2Root))
{
    Write-Error "MSYS2_ROOT is not defined in: $envFilePath"
    Abort-WithError
}

$msys2BashWin = ""
if (-not [string]::IsNullOrWhiteSpace($msys2Bash)) { $msys2BashWin = Convert-ToWinPath $msys2Bash }

Write-Info "STEP 1: OK"

# STEP 2: Resolve git.
# --------------------------------------------------------------------

Write-Info "STEP 2: Resolve git."

if ($repos.Count -eq 0)
{
    Write-Info "No repositories are configured, so there is nothing to clone."
    Write-Info "Add them under 'workspace.repositories' in the configuration if you want this step to do something."
    Write-NoFormat "================================================================="
    Write-NoFormat "  NOTHING TO DO"
    Write-NoFormat "================================================================="
    if ($originalTitle) { $host.UI.RawUI.WindowTitle = $originalTitle }
    exit 0
}

$gitExe = Resolve-GitExecutable -MingwRoot $mingwRoot -Msys2Root $msys2Root -BashPath $msys2BashWin
if (-not $gitExe)
{
    Write-Error "Git was not found in the generated environment."
    Write-Error "Step 2 installs it; check that the MSYS2 package list still carries a git package."
    Abort-WithError
}

$gitVersion = Get-NativeOutput $gitExe @("--version")
if ($gitVersion.ExitCode -ne 0)
{
    Write-Error "Git was found at '$gitExe' but failed to run (ExitCode=$($gitVersion.ExitCode))."
    Abort-WithError
}
Write-Info ("Git version: {0}" -f (($gitVersion.Output | Select-Object -First 1) -replace '\s+$',''))

# Never let git stop for input. A private repository with no credentials available would otherwise sit waiting for
# a username that nobody is there to type, and an unattended generation would hang instead of failing. With this
# it fails immediately, and the failure says what it is.
$previousTerminalPrompt = $env:GIT_TERMINAL_PROMPT
$env:GIT_TERMINAL_PROMPT = "0"

# The proxy is passed on the command line as well as being written into the drive's git config by step 2. Belt and
# braces on purpose: this step is also run on its own against drives generated before that config existed.
$gitCommonArgs = @()
if (-not [string]::IsNullOrWhiteSpace($proxyUrl))
{
    $gitCommonArgs += @("-c", ("http.proxy={0}" -f $proxyUrl.Trim()))
    Write-Info "Using proxy: $proxyUrl"
}

Write-Info "STEP 2: OK"

# STEP 3: Clone the configured repositories.
# --------------------------------------------------------------------

Write-Info "STEP 3: Clone the configured repositories."

$cloned   = @()
$skipped  = @()
$failed   = @()
$warned   = @()

$index = 0
foreach ($repo in $repos)
{
    $index++

    $url = ([string]$repo.url).Trim()

    # --- name: configured, or whatever git itself would have chosen -----------------------------------------------
    $name = [string](Get-RepoField -Repo $repo -Name 'name')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = Get-RepoNameFromUrl -Url $url }
    if ([string]::IsNullOrWhiteSpace($name))
    {
        Write-Error ("workspace.repositories[{0}]: cannot derive a directory name from '{1}'." -f ($index - 1), $url)
        Write-Error "Give it an explicit 'name'."
        $failed += $url
        continue
    }
    $name = $name.Trim()

    # --- folder: configured per repository, or the shared default -------------------------------------------------
    $folder = [string](Get-RepoField -Repo $repo -Name 'folder')
    if ([string]::IsNullOrWhiteSpace($folder)) { $folder = $defaultFolder }
    $folder = $folder.Trim()

    if (-not (Test-SafeRelativePath $folder))
    {
        Write-Error ("workspace.repositories[{0}].folder is not a safe relative path: '{1}'" -f ($index - 1), $folder)
        Write-Error "It must be relative to the drive root, with no drive letter and no '..' segment."
        $failed += $url
        continue
    }

    $optional   = [bool](Get-RepoField -Repo $repo -Name 'optional')
    $ref        = [string](Get-RepoField -Repo $repo -Name 'ref')
    $submodules = [bool](Get-RepoField -Repo $repo -Name 'submodules')
    $depthValue = Get-RepoField -Repo $repo -Name 'depth'

    $folderWin = Join-Path $devDrive (Convert-ToWinPath $folder)
    $targetWin = Join-Path $folderWin $name

    Write-NoFormat "-----------------------------------------------------------------"
    Write-Info ("Repository {0}/{1}: {2}" -f $index, $repos.Count, $url)
    Write-NoFormat ("  destination : {0}" -f $targetWin)
    if (-not [string]::IsNullOrWhiteSpace($ref)) { Write-NoFormat ("  ref         : {0}" -f $ref) }
    if ($depthValue)                             { Write-NoFormat ("  depth       : {0}" -f $depthValue) }
    if ($submodules)                             { Write-NoFormat  "  submodules  : yes" }
    if ($optional)                               { Write-NoFormat  "  optional    : yes" }

    # --- already there? -------------------------------------------------------------------------------------------
    # Re-running a step must not be destructive and must not silently do half a job. Three cases, and only the first
    # is benign.
    if (Test-Path -LiteralPath $targetWin)
    {
        $isRepo = Get-NativeOutput $gitExe @("-C", $targetWin, "rev-parse", "--is-inside-work-tree")

        if ($isRepo.ExitCode -ne 0)
        {
            Write-Error "The destination exists and is not a git repository."
            Write-Error "Refusing to touch it. Move it aside or delete it, then re-run."
            if ($optional) { Write-Warn "Marked optional, so this is not fatal."; $warned += $url }
            else           { $failed += $url }
            continue
        }

        $originOut = Get-NativeOutput $gitExe @("-C", $targetWin, "remote", "get-url", "origin")
        $origin    = ""
        if ($originOut.ExitCode -eq 0 -and $originOut.Output.Count -gt 0) { $origin = ([string]$originOut.Output[0]).Trim() }

        if ($origin -ne $url)
        {
            Write-Error "The destination is a git repository with a DIFFERENT origin."
            Write-Error ("  configured : {0}" -f $url)
            Write-Error ("  on disk    : {0}" -f $origin)
            Write-Error "Refusing to touch it."
            if ($optional) { Write-Warn "Marked optional, so this is not fatal."; $warned += $url }
            else           { $failed += $url }
            continue
        }

        # Present, correct, and deliberately NOT fetched or reset. This step puts projects on a drive; it is not a
        # synchroniser, and pulling under somebody's uncommitted work would be a rude thing for a setup script to do.
        Write-Info "Already cloned with the same origin. Left untouched."
        $skipped += $url
        continue
    }

    # --- clone ------------------------------------------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $folderWin))
    {
        try   { New-Item -ItemType Directory -Path $folderWin -Force | Out-Null }
        catch
        {
            Write-Error ("Could not create the destination folder: {0}" -f $folderWin)
            if ($optional) { Write-Warn "Marked optional, so this is not fatal."; $warned += $url }
            else           { $failed += $url }
            continue
        }
    }

    $cloneArgs = @()
    $cloneArgs += $gitCommonArgs
    $cloneArgs += "clone"
    if (-not [string]::IsNullOrWhiteSpace($ref)) { $cloneArgs += @("--branch", $ref.Trim()) }
    if ($depthValue)                             { $cloneArgs += @("--depth", [string]$depthValue) }
    if ($submodules)                             { $cloneArgs += "--recurse-submodules" }
    $cloneArgs += @("--", $url, $targetWin)

    $code = Invoke-Native $gitExe $cloneArgs

    if ($code -ne 0)
    {
        Write-Error ("Clone failed (ExitCode={0}): {1}" -f $code, $url)

        # The single most likely cause on a fresh machine, and worth naming rather than leaving somebody to guess.
        if ($url -match '^https?://')
        {
            Write-Error "If this repository is private: the drive's git has no credential helper, and this step runs"
            Write-Error "non-interactively (GIT_TERMINAL_PROMPT=0), so HTTPS authentication cannot happen here."
            Write-Error "Use a public URL, or an SSH remote with a key this machine already has, or clone that one"
            Write-Error "by hand and mark it 'optional' in the configuration."
        }

        if ($optional) { Write-Warn "Marked optional, so this is not fatal."; $warned += $url }
        else           { $failed += $url }
        continue
    }

    if (-not (Test-Path -LiteralPath (Join-Path $targetWin ".git")))
    {
        Write-Error "Git reported success but there is no .git directory. Treating this as a failure."
        if ($optional) { Write-Warn "Marked optional, so this is not fatal."; $warned += $url }
        else           { $failed += $url }
        continue
    }

    $head = Get-NativeOutput $gitExe @("-C", $targetWin, "rev-parse", "--short", "HEAD")
    if ($head.ExitCode -eq 0 -and $head.Output.Count -gt 0)
    {
        Write-Info ("Cloned at commit {0}" -f ([string]$head.Output[0]).Trim())
    }
    else
    {
        Write-Info "Cloned."
    }

    $cloned += $url
}

# Restore whatever the caller had, so this script does not leave a changed environment behind in a shell that runs
# several steps in a row.
$env:GIT_TERMINAL_PROMPT = $previousTerminalPrompt

Write-Info "STEP 3: OK"

# SUMMARY
# --------------------------------------------------------------------

$elapsed = (Get-Date) - $scriptStart

Write-NoFormat "================================================================="
Write-NoFormat "  WORKSPACE REPOSITORIES SUMMARY"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat ("  configured : {0}" -f $repos.Count)
Write-NoFormat ("  cloned     : {0}" -f $cloned.Count)
Write-NoFormat ("  skipped    : {0}   (already present with the same origin)" -f $skipped.Count)
Write-NoFormat ("  warnings   : {0}   (optional, and did not clone)" -f $warned.Count)
Write-NoFormat ("  failed     : {0}" -f $failed.Count)
Write-NoFormat ("  elapsed    : {0:mm}:{0:ss}" -f $elapsed)
Write-NoFormat "================================================================="

foreach ($u in $warned) { Write-Warn  ("optional, not cloned: {0}" -f $u) }
foreach ($u in $failed) { Write-Error ("not cloned: {0}" -f $u) }

if ($failed.Count -gt 0)
{
    Write-Error ("{0} repository(ies) could not be cloned." -f $failed.Count)
    Write-Error "The DRIVE is fine -- everything the previous steps built is untouched. Only the projects are missing."
    Abort-WithError
}

Write-Info "All configured repositories are in place."

if ($originalTitle) { $host.UI.RawUI.WindowTitle = $originalTitle }
exit 0
