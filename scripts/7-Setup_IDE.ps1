# ====================================================================
# IDE INTEGRATION: QT CREATOR, ONE FOR THE DRIVE, ONE KIT PER TOOLCHAIN
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Needs step 1 and steps 2 to 5 for at least one toolchain (with source
# msys2, including the one whose subsystem provides Qt Creator). A
# toolchain not ready yet gets no kit, and the step says so.
#
# One Qt Creator for the drive, one kit per toolchain: a project keeps one
# .user file and builds each kit in its own directory. Each kit is what the
# toolchain's launcher gives a shell (compilers, gdb, cmake, ninja, vcpkg
# toolchain file and triplet, env file variables, PATH in launcher order),
# registered with sdktool into a drive-owned installer-settings folder
# (-installsettingspath); user settings beside it (-settingspath).
#
# One launcher per toolchain (owner decision, 2026-10-15) opens that Qt
# Creator through MSYS2 and the toolchain's env bootstrap, as its shell.
#
# ide_integration.qtcreator.source: msys2 (a subsystem's qt-creator
# package), external (an installed Qt Creator and its sdktool), none.
# A drive step: runs once, after every toolchain.
# ====================================================================

param
(
    # @brief Path to the JSON configuration; the same file every step is given. A bare name resolves against config/.
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief Validate the configuration, print what would be registered, and stop, changing nothing.
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

    # UserInteractive alone is NOT enough: with stdin redirected ReadKey throws instead of waiting.
    if ([Environment]::UserInteractive -and -not [System.Console]::IsInputRedirected) {
        Write-Host ""
        Write-Host "Press any key to exit..."
        [void][System.Console]::ReadKey($true)
    }

    if ($originalTitle) { $host.UI.RawUI.WindowTitle = $originalTitle }
    if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }
    exit 1
}

function Get-ScriptDirectory
{
    if ($PSScriptRoot) { return $PSScriptRoot }
    else { return Split-Path -Parent (Convert-Path -LiteralPath ([System.Environment]::GetCommandLineArgs()[0])) }
}

function Invoke-Sdktool
{
    # @brief Run sdktool with one operation's arguments, mirroring its output into the log. Returns the exit code.
    # Through Invoke-DrivEnvNative, never '& $Sdktool @Arguments': PowerShell 5.1 mangles an argument that holds a space
    # and ends in a backslash, which a custom variable's value can.
    param ([string]$Sdktool, [string[]]$Arguments)

    $r = Invoke-DrivEnvNative -FilePath $Sdktool -Arguments $Arguments
    foreach ($l in @($r.Output)) { if ("$l".Trim()) { Write-NoFormat ("    | " + $l) } }
    return $r.ExitCode
}

# --------------------------------------------------------------------
# CONFIGURATION
# --------------------------------------------------------------------

$scriptDir   = Get-ScriptDirectory
$drivEnvRoot = Split-Path -Parent $scriptDir

. (Join-Path $PSScriptRoot "DrivEnvConfig.ps1")
. (Join-Path $PSScriptRoot "DrivEnvLogs.ps1")

$ConfigPath = Resolve-DrivEnvConfigPath -ConfigFile $ConfigFile -GeneratorRoot $drivEnvRoot
if (-not (Test-Path -LiteralPath $ConfigPath))
{
    Write-Error "Configuration file missing: $ConfigPath"
    Abort-WithError
}

try   { $Cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Write-Error "Invalid JSON in $ConfigPath"; Abort-WithError }

$cfgProblems = @(Test-DrivEnvConfig -Config $Cfg)
if ($cfgProblems.Count -gt 0)
{
    Write-Error ("Configuration has {0} problem(s): {1}" -f $cfgProblems.Count, $ConfigPath)
    foreach ($cfgProblem in $cfgProblems) { Write-Error "    $cfgProblem" }
    Abort-WithError
}
Write-Info "Configuration validated against the schema: no problems."

# What to set up, resolved in one place: where Qt Creator and sdktool are, which drive directories, which toolchains.
$qt = Get-DrivEnvQtCreatorSetup -Cfg $Cfg

if ($ValidateOnly)
{
    if ($null -eq $qt) { Write-Info "Qt Creator integration: none." }
    else
    {
        Write-Info ("Qt Creator ({0}): {1}" -f $qt.Source, $qt.QtCreator)
        Write-Info ("sdktool: {0}" -f $qt.Sdktool)
        Write-Info ("Installer settings (kits): {0}" -f $qt.InstallSettings)
        Write-Info ("User settings: {0}" -f $qt.UserSettings)
        foreach ($t in $qt.Toolchains)
        {
            Write-Info ("Kit for toolchain '{0}': '{1}', from {2}" -f $t.Id, $t.KitName, $t.EnvFile)
            Write-Info ("  launcher, in its environment: {0}" -f $t.Names.QtLauncher)
        }
        if ($qt.RegisterInUserSettings) { Write-Info ("Also added, as manual kits '<kit> ({0})', to your own Qt Creator: {1}" -f $qt.Drive, $qt.UserQtSettingsDir) }
    }
    Write-Info "-ValidateOnly was given, so nothing further will run."
    exit 0
}

if ($null -eq $qt)
{
    Write-Info "No Qt Creator integration is configured (ide_integration.qtcreator.source is 'none' or absent). Nothing to do."
    exit 0
}

$driveLetter = ([string]$Cfg.environment.dev_drive_letter).Trim().TrimEnd(':').ToUpperInvariant()
$devDrive    = "{0}:\" -f $driveLetter

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir   = Join-Path $drivEnvRoot "logs"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir | Out-Null }
$globalLogFile = Join-Path $logsDir (Get-DrivEnvLogName -Timestamp $timestamp -Role "ide-setup")

$originalTitle = $host.UI.RawUI.WindowTitle
$host.UI.RawUI.WindowTitle = "IDE INTEGRATION SETUP SCRIPT"

Write-NoFormat "================================================================="
Write-NoFormat "  IDE INTEGRATION SETUP SCRIPT (QT CREATOR)"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "  Authors: Angel Vera Herrera"
Write-NoFormat "  Updated: 20/10/2026"
Write-NoFormat "  Version: 3.0.0"
Write-NoFormat "================================================================="
Write-NoFormat "Drive             = $devDrive"
Write-NoFormat "Source            = $($qt.Source)"
Write-NoFormat "Qt Creator        = $($qt.QtCreator)"
Write-NoFormat "sdktool           = $($qt.Sdktool)"
Write-NoFormat "Installer settings= $($qt.InstallSettings)"
Write-NoFormat "User settings     = $($qt.UserSettings)"
Write-NoFormat "================================================================="

# STEP 1: Qt Creator and sdktool are there.
# --------------------------------------------------------------------

Write-Info "STEP 1: Find Qt Creator and sdktool."

if (-not (Test-Path -LiteralPath $devDrive))
{
    Write-Error "The dev drive is not present: $devDrive"
    Abort-WithError
}

# With source msys2, Qt Creator is a package of one toolchain, and that toolchain may not be on this drive yet -- a run
# given -Toolchain naming only the other, say. That is not a failure of this step: it is said, and nothing is done.
if (($qt.Source -eq 'msys2') -and (-not (Test-Path -LiteralPath $qt.QtCreator)) -and
    (($null -eq $qt.Holder) -or (-not (Test-Path -LiteralPath $qt.Holder.EnvFile))))
{
    Write-Warn ("Qt Creator comes with the {0} toolchain, which is not on this drive yet. Nothing to set up: run steps 2 to 5 for it, then this step." -f $qt.Subsystem)
    $host.UI.RawUI.WindowTitle = $originalTitle
    if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }
    exit 0
}

foreach ($exe in @($qt.QtCreator, $qt.Sdktool))
{
    if (-not (Test-Path -LiteralPath $exe))
    {
        Write-Error "Not found: $exe"
        if ($qt.Source -eq 'msys2')
        {
            Write-Error ("It comes from the qt-creator package of {0}, which step 2 installs for the toolchain with that subsystem. Run step 2 for it." -f $qt.Subsystem)
        }
        else
        {
            Write-Error "ide_integration.qtcreator names an installed Qt Creator; check the path, and 'sdktool' when sdktool.exe is neither beside qtcreator.exe nor in the Qt installer's Tools\sdktool\bin."
        }
        Abort-WithError
    }
}

# sdktool and Qt Creator load their DLLs from their own directory first; their directory on PATH covers the rest.
$env:PATH = (Split-Path -Parent $qt.Sdktool) + ";" + $env:PATH

Write-Info "STEP 1: OK"

# STEP 2: One kit per toolchain, into the drive's installer settings.
# --------------------------------------------------------------------

Write-Info "STEP 2: Register one kit per toolchain."

# The directory is DrivEnv's alone, so it is rebuilt from nothing on every run: a toolchain removed from the
# configuration loses its kit, and nothing is left from an earlier run's ids.
if (Test-Path -LiteralPath $qt.SdkPath)
{
    foreach ($xml in @('profiles.xml', 'toolchains.xml', 'debuggers.xml', 'cmaketools.xml', 'qtversion.xml'))
    {
        Remove-Item -LiteralPath (Join-Path $qt.SdkPath $xml) -Force -ErrorAction SilentlyContinue
    }
}
New-Item -ItemType Directory -Path $qt.SdkPath -Force | Out-Null
New-Item -ItemType Directory -Path $qt.UserSettings -Force | Out-Null

# Qt Creator refuses an installer-settings path without QtProject\QtCreator.ini in it -- an error dialog at every start
# -- though it needs nothing inside. Created empty when missing, and otherwise left as it is.
if (-not (Test-Path -LiteralPath $qt.InstallIni)) { [System.IO.File]::WriteAllText($qt.InstallIni, "") }

$specs = @()
$withKit = @()
$ready = @()
foreach ($t in $qt.Toolchains)
{
    if (-not (Test-Path -LiteralPath $t.EnvFile))
    {
        Write-Warn ("Toolchain '{0}': no env file yet ({1}), so no kit. Run steps 2 to 5 for it, then this step again." -f $t.Id, $t.EnvFile)
        continue
    }

    $values = Resolve-DrivEnvEnvValues -Lines ([System.IO.File]::ReadAllLines($t.EnvFile, (New-Object System.Text.UTF8Encoding($false))))
    $notReady = Get-DrivEnvQtKitProblem -EnvValues $values
    if ($notReady)
    {
        Write-Warn ("Toolchain '{0}': {1}, so no kit. Run steps 3 to 5 for it, then this step again." -f $t.Id, $notReady)
        continue
    }

    $toolDirs = Get-DrivEnvVcpkgToolDirs -VcpkgRoot $values['VCPKG_ROOT'] -Triplet $values['VCPKG_DEFAULT_TRIPLET']
    # The kit's own Qt: this toolchain's vcpkg one, when vcpkg built it (see Get-DrivEnvQtKitSpec for why).
    $qmake = ("{0}/installed/{1}/tools/Qt6/bin/qmake6.exe" -f ([string]$values['VCPKG_ROOT']).TrimEnd('/', '\'), $values['VCPKG_DEFAULT_TRIPLET'])
    if (-not (Test-Path -LiteralPath $qmake)) { $qmake = "" }
    $spec   = Get-DrivEnvQtKitSpec -Names $t.Names -EnvValues $values -Family $t.Family -Arch $t.Arch -KitName $t.KitName `
                                   -CustomNames $qt.CustomVariableNames -CustomPathEntries $qt.CustomPathEntries -ToolDirs $toolDirs -QMake $qmake
    foreach ($tool in @($spec.CCompiler, $spec.CxxCompiler, $spec.Gdb, $spec.CMake))
    {
        if (-not (Test-Path -LiteralPath $tool)) { Write-Warn ("Toolchain '{0}': {1} is missing; its kit will not work." -f $t.Id, $tool) }
    }

    foreach ($call in (ConvertTo-DrivEnvSdktoolCalls -Spec $spec -SdkPath $qt.SdkPath))
    {
        $code = Invoke-Sdktool -Sdktool $qt.Sdktool -Arguments $call
        if ($code -ne 0)
        {
            Write-Error ("sdktool failed (exit {0}) on: {1}" -f $code, ($call -join ' '))
            Abort-WithError
        }
    }
    Write-Info ("Kit '{0}' registered for toolchain '{1}'." -f $spec.KitName, $t.Id)
    $specs += $spec
    $withKit += $t
    $ready += @{ T = $t; Values = $values; ToolDirs = $toolDirs; QMake = $qmake }
}

if ($specs.Count -eq 0) { Write-Warn "No toolchain is ready for a kit yet (see above), so Qt Creator has none. Generate a toolchain first." }

Write-Info "STEP 2: OK"

# STEP 3: One launcher per toolchain, and their shortcuts.
# --------------------------------------------------------------------

Write-Info "STEP 3: Launchers and shortcuts, one per toolchain."

$encoding    = New-Object System.Text.UTF8Encoding($false)
$templateBat = Join-Path $drivEnvRoot "drive\launchers\qtcreator_launcher.bat"
$templateSh  = Join-Path $drivEnvRoot "drive\launchers\qtcreator_launcher.sh"
foreach ($tpl in @($templateBat, $templateSh))
{
    if (-not (Test-Path -LiteralPath $tpl)) { Write-Error "Launcher template not found: $tpl"; Abort-WithError }
}

# Rebuilt from nothing, like the kits: an earlier run's launchers and drive shortcuts go first, so a toolchain that has
# no kit any more has no launcher either. Only this drive's Qt Creator ones, by their exact names.
$prefixRx = [regex]::Escape($qt.Prefix)
$stale = @()
if (Test-Path -LiteralPath $qt.LauncherDir)
{
    $stale += @(Get-ChildItem -LiteralPath $qt.LauncherDir -File | Where-Object { $_.Name -match "^${prefixRx}(_[A-Za-z0-9]+)?_qtcreator(\.bat|_launcher\.sh)$" })
}
$stale += @(Get-ChildItem -LiteralPath $devDrive -File -Filter '*.lnk' | Where-Object { $_.Name -match "^${prefixRx}(_[A-Za-z0-9]+)?_qtcreator\.lnk$" })
foreach ($f in $stale) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }

# A '%' in a batch line starts a variable reference, so each one in the paths is doubled to stay a '%'.
function ConvertTo-BatchLiteral { param([string]$Text) return $Text.Replace('%', '%%') }
$bat = [System.IO.File]::ReadAllText($templateBat, $encoding)
$bat = $bat.Replace('@QTCREATOR_EXE@', (ConvertTo-BatchLiteral $qt.QtCreator)).Replace('@SETTINGS_PATH@', (ConvertTo-BatchLiteral $qt.UserSettings)).Replace('@INSTALL_SETTINGS_PATH@', (ConvertTo-BatchLiteral $qt.InstallSettings))
$bat = $bat -replace "(?<!`r)`n", "`r`n"
# bash is handed the launch script as it is, so it keeps LF whatever the checkout did to it.
$sh = ([System.IO.File]::ReadAllText($templateSh, $encoding)) -replace "`r`n", "`n"

$createDesktopShortcuts = $true
if ($Cfg.environment.PSObject.Properties.Name -contains "create_desktop_shortcuts") { $createDesktopShortcuts = [bool]$Cfg.environment.create_desktop_shortcuts }
$shell = New-Object -ComObject WScript.Shell
$opened = @()

foreach ($t in $withKit)
{
    $n = $t.Names
    if (-not (Test-Path -LiteralPath $n.Bootstrap))
    {
        Write-Warn ("Toolchain '{0}': its env bootstrap is missing ({1}), so its Qt Creator launcher could not load the environment. Run step 2 for it, then this step." -f $t.Id, $n.Bootstrap)
        continue
    }

    New-Item -ItemType Directory -Path $n.LauncherDir -Force | Out-Null
    [System.IO.File]::WriteAllText($n.QtLauncher, $bat, $encoding)
    [System.IO.File]::WriteAllText($n.QtLauncherTail, $sh, $encoding)
    Write-Info ("Launcher for '{0}': {1}" -f $t.Id, $n.QtLauncher)

    $targets = @($n.QtShortcut)
    if ($createDesktopShortcuts) { $targets += [System.IO.Path]::Combine([Environment]::GetFolderPath("Desktop"), $n.QtDesktopShortcutName) }
    foreach ($lnk in $targets)
    {
        $shortcut = $shell.CreateShortcut($lnk)
        $shortcut.TargetPath       = $n.QtLauncher
        $shortcut.WorkingDirectory = $devDrive
        # Normal, not minimised: the launcher's window closes once Qt Creator is started (through setsid), and when it
        # cannot start it, the error it pauses on has to be seen.
        $shortcut.WindowStyle      = 1
        $shortcut.IconLocation     = "$($qt.QtCreator),0"
        $shortcut.Save()
        Write-Info "Shortcut: $lnk"
    }
    $opened += $n.QtShortcut
}

# Remove desktop shortcuts to Qt Creator launchers of THIS drive that no longer exist (matched by target, not name).
$desktop = [Environment]::GetFolderPath("Desktop")
if ($desktop -and (Test-Path -LiteralPath $desktop))
{
    $launcherDirFull = [System.IO.Path]::GetFullPath($qt.LauncherDir).TrimEnd('\') + '\'
    foreach ($lnk in @(Get-ChildItem -LiteralPath $desktop -File -Filter '*.lnk' -ErrorAction SilentlyContinue))
    {
        $target = ""
        try { $target = [string]$shell.CreateShortcut($lnk.FullName).TargetPath } catch { continue }
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        $isOurs = $target.StartsWith($launcherDirFull, [System.StringComparison]::OrdinalIgnoreCase) -and
                  ((Split-Path -Leaf $target) -match "^${prefixRx}(_[A-Za-z0-9]+)?_qtcreator\.bat$")
        if ($isOurs -and -not (Test-Path -LiteralPath $target))
        {
            Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction SilentlyContinue
            Write-Info "Removed a desktop shortcut to a launcher that is gone: $($lnk.FullName)"
        }
    }
}

Write-Info "STEP 3: OK"

# STEP 4: The same kits in the user's own Qt Creator, when asked.
# --------------------------------------------------------------------
# register_in_user_settings (owner decision, 2026-10-19): the Start-menu Qt Creator gets this drive's kits as manual
# kits ('<kit> (<letter>:)', ids 'drivenv.<letter>.'), everything else kept (Merge-DrivEnvQtUserSettings). Skipped
# while it runs. Without a Qt version: that Qt Creator runs on the machine's PATH, where the vcpkg qmake cannot start,
# so QtInformation is -1 and projects find Qt through the vcpkg toolchain file.

Write-Info "STEP 4: The user's own Qt Creator."

if (-not $qt.RegisterInUserSettings)
{
    Write-Info "ide_integration.qtcreator.register_in_user_settings is not set: the user's own Qt Creator is left alone."
}
else
{
    $userQtc = @(Get-CimInstance Win32_Process -Filter "Name='qtcreator.exe'" -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -notmatch '-settingspath' })
    if (-not (Test-Path -LiteralPath (Join-Path $qt.UserSettingsRoot 'QtCreator.ini')) -or -not (Test-Path -LiteralPath (Join-Path $qt.UserQtSettingsDir 'profiles.xml')))
    {
        # Not a Qt Creator settings directory -- a mistyped user_settings_path -- or one whose Qt Creator has never
        # run: nothing is written. Kits created where no Qt Creator reads would only look like a success, and a
        # profiles.xml holding only these kits would stop a first start from creating its own Desktop kit.
        Write-Warn ("{0} holds no QtCreator.ini and qtcreator\profiles.xml, so it is not the settings of a Qt Creator that has run, and nothing was written. Check ide_integration.qtcreator.user_settings_path, or start that Qt Creator once." -f $qt.UserSettingsRoot)
    }
    elseif ($userQtc.Count -gt 0)
    {
        Write-Warn ("Your own Qt Creator is running, so its settings were left alone. Close it and run this step again to add the kits to {0}." -f $qt.UserQtSettingsDir)
    }
    else
    {
        $genDir = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-qtusr-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $genDir -Force | Out-Null
        try
        {
            foreach ($r in $ready)
            {
                $u = Get-DrivEnvQtKitSpec -Names $r.T.Names -EnvValues $r.Values -Family $r.T.Family -Arch $r.T.Arch -KitName ("{0} ({1})" -f $r.T.KitName, $qt.Drive) `
                                          -CustomNames $qt.CustomVariableNames -CustomPathEntries $qt.CustomPathEntries -ToolDirs $r.ToolDirs -IdPrefix $qt.UserIdPrefix
                foreach ($call in (ConvertTo-DrivEnvSdktoolCalls -Spec $u -SdkPath $genDir))
                {
                    $code = Invoke-Sdktool -Sdktool $qt.Sdktool -Arguments $call
                    if ($code -ne 0) { Write-Error ("sdktool failed (exit {0}) on: {1}" -f $code, ($call -join ' ')); Abort-WithError }
                }
            }
            $merge = Merge-DrivEnvQtUserSettings -GeneratedDir $genDir -UserDir $qt.UserQtSettingsDir -OwnPrefix $qt.UserIdPrefix -Stamp $timestamp
            if ($merge.Ok)
            {
                Write-Info ("Added to your own Qt Creator ({0}): {1}" -f $qt.UserQtSettingsDir, $(if ($merge.Kits.Count) { $merge.Kits -join ', ' } else { "no kit -- this drive's earlier ones removed" }))
                foreach ($b in $merge.Backups) { Write-Info "  backup: $b" }
            }
            else
            {
                Write-Warn ("Your own Qt Creator's settings were NOT changed: {0}" -f $merge.Message)
            }
        }
        finally { Remove-Item -LiteralPath $genDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Info "STEP 4: OK"

Write-Info ("Qt Creator integration done: {0} kit(s). Open Qt Creator, in a toolchain's environment, from: {1}" -f $specs.Count, ($opened -join ', '))
$host.UI.RawUI.WindowTitle = $originalTitle
if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }
exit 0
