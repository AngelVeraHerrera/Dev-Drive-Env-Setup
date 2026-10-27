# ====================================================================
# REMOVE A DEV DRIVE, AND EVERYTHING THE GENERATOR LEFT OUTSIDE IT
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
# Updated: 27/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Deletes the drive a configuration describes (dismounts and DELETES its
# VHDX) and what the generator left outside it: its startup mount task
# (then Manage-MountTasks.ps1 -Remove), its Defender exclusions, the
# desktop shortcuts into it, and its kits in your own Qt Creator.
#
#   .\tools\Remove-DevDrive.ps1 -ConfigFile drivenv-cfg.json -WhatIf   show, change nothing
#   .\tools\Remove-DevDrive.ps1 -ConfigFile drivenv-cfg.json           elevates, asks twice
#
# Refuses while programs run from the drive.
# ====================================================================

[CmdletBinding()]
param
(
    # @brief The configuration of the drive to remove. A bare name resolves against config/.
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    # @brief Show what would be removed. Not the common -WhatIf, which leaks into every cmdlet below.
    [switch]$WhatIf,

    # @brief Internal: set on the elevated relaunch, so its window waits for a key before closing.
    [switch]$ElevatedChild
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\scripts\DrivEnvConfig.ps1")

function Test-IsAdministrator
{
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Exit-Window
{
    # @brief Leaves the elevated window open until a key, so its report is read; a plain console exits at once.
    param([int]$Code)
    if ($script:elevatedChild) { Write-Host ""; Write-Host "Press Enter to close this window..."; [void](Read-Host) }
    exit $Code
}

$script:elevatedChild = $false
$configPath = Resolve-DrivEnvConfigPath -ConfigFile $ConfigFile -GeneratorRoot (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path -LiteralPath $configPath)) { Write-Host "[ERROR] Configuration not found: $configPath" -ForegroundColor Red; exit 1 }

if ((-not $WhatIf) -and (-not (Test-IsAdministrator)))
{
    Write-Host "Removing a drive needs administrator rights; relaunching elevated in a window of its own..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-ConfigFile', ('"{0}"' -f $configPath), '-ElevatedChild')
    try { $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait -PassThru }
    catch { Write-Host "[ERROR] Elevation was refused or failed; nothing was changed." -ForegroundColor Red; exit 1 }
    exit $p.ExitCode
}
if ($ElevatedChild) { $script:elevatedChild = $true }
$isAdmin = Test-IsAdministrator

# --------------------------------------------------------------------
# WHAT THERE IS TO REMOVE
# --------------------------------------------------------------------

$cfg    = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$env_   = $cfg.environment
$letter = ([string]$env_.dev_drive_letter).Trim().TrimEnd(':', '\').ToUpperInvariant()
$label  = ([string]$env_.dev_drive_label).Trim()
$vhdDir = ([string]$env_.vhd_root).Trim().Replace('/', '\').TrimEnd('\')
$vhd    = Join-Path $vhdDir ("{0}.vhdx" -f $label)
$drive  = "${letter}:\"
if (($letter -notmatch '^[A-Z]$') -or (-not $label) -or (-not $vhdDir)) { Write-Host "[ERROR] The configuration does not name a drive letter, a label and a vhd_root." -ForegroundColor Red; Exit-Window 1 }

$image    = $null
try { $image = Get-DiskImage -ImagePath $vhd -ErrorAction Stop } catch { }
$attached = ($null -ne $image) -and $image.Attached

# The startup task: identified by what it does -- Mount-VHD or Mount-DiskImage of THIS file -- as Manage-MountTasks.ps1 does it.
$tasks = @()
foreach ($t in @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue))
{
    foreach ($a in @($t.Actions))
    {
        $m = [regex]::Match([string]$a.Arguments, "Mount-(?:VHD|DiskImage).*-(?:Image)?Path\s+['""]([^'""]+)['""]")
        if ($m.Success -and ($m.Groups[1].Value.TrimEnd('\') -ieq $vhd)) { $tasks += $t; break }
    }
}

$exclusions = @()
# Unelevated, Defender answers "N/A: Must be an administrator to view exclusions" instead of the list: not a path.
try { $exclusions = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | Where-Object { $_ -and ($_ -notmatch '^N/A') }) } catch { }
$exDrive   = @($exclusions | Where-Object { $_.TrimEnd('\') -ieq "${letter}:" })
$othersVhd = @(Get-ChildItem -LiteralPath $vhdDir -Filter '*.vhdx' -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ine $vhd })
$exRoot    = @(); if ($othersVhd.Count -eq 0) { $exRoot = @($exclusions | Where-Object { $_.TrimEnd('\') -ieq $vhdDir }) }

$shell     = New-Object -ComObject WScript.Shell
$desktop   = [Environment]::GetFolderPath('Desktop')
$shortcuts = @(Get-ChildItem -LiteralPath $desktop -Filter '*.lnk' -File -ErrorAction SilentlyContinue | Where-Object {
                 $target = ""; try { $target = [string]$shell.CreateShortcut($_.FullName).TargetPath } catch { }
                 ($target -ieq $vhd) -or $target.StartsWith($drive, [System.StringComparison]::OrdinalIgnoreCase) })

$qt = Get-DrivEnvQtCreatorSetup -Cfg $cfg
$qtKits = @()
if ($qt -and $qt.RegisterInUserSettings -and (Test-Path -LiteralPath (Join-Path $qt.UserQtSettingsDir 'profiles.xml')))
{
    $px = [xml](Get-Content -LiteralPath (Join-Path $qt.UserQtSettingsDir 'profiles.xml') -Raw -Encoding UTF8)
    $qtKits = @($px.qtcreator.data | Where-Object { $_.variable -match '^Profile\.\d+$' } | ForEach-Object {
                  $id = @($_.valuemap.value | Where-Object { $_.key -eq 'PE.Profile.Id' })[0].'#text'
                  if ($id -and $id.StartsWith($qt.UserIdPrefix)) { @($_.valuemap.value | Where-Object { $_.key -eq 'PE.Profile.Name' })[0].'#text' } })
}

$running = @()
if (Test-Path -LiteralPath $drive)
{
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($drive, [System.StringComparison]::OrdinalIgnoreCase) })
}

Write-Host ""
Write-Host ("Remove the dev drive '{0}' ({1}:)" -f $label, $letter) -ForegroundColor Cyan
Write-Host ("=" * 78) -ForegroundColor Cyan
Write-Host ("  VHDX                 {0}  {1}" -f $vhd, $(if (Test-Path -LiteralPath $vhd) { "{0:N1} GB on disk, {1}" -f ((Get-Item -LiteralPath $vhd).Length / 1GB), $(if ($attached) { 'mounted' } else { 'not mounted' }) } else { '(not found)' }))
Write-Host ("  startup task         {0}" -f $(if ($tasks.Count) { (@($tasks | ForEach-Object { $_.TaskName })) -join ', ' } else { 'none' }))
Write-Host ("  Defender exclusions  {0}" -f $(if (($exDrive + $exRoot).Count) { ($exDrive + $exRoot) -join ', ' } else { 'none' }))
if ($othersVhd.Count) { Write-Host ("                       (vhd_root's own exclusion stays: {0} other VHDX there)" -f $othersVhd.Count) -ForegroundColor DarkGray }
Write-Host ("  desktop shortcuts    {0}" -f $(if ($shortcuts.Count) { (@($shortcuts | ForEach-Object { $_.Name })) -join ', ' } else { 'none' }))
Write-Host ("  your Qt Creator kits {0}" -f $(if ($qtKits.Count) { $qtKits -join ', ' } else { 'none' }))
Write-Host ""

if ($running.Count -gt 0)
{
    $colour = if ($WhatIf) { 'Yellow' } else { 'Red' }
    Write-Host ("{0} Programs are running from the drive. Close them, then run this again:" -f $(if ($WhatIf) { '[WOULD REFUSE]' } else { '[ERROR]' })) -ForegroundColor $colour
    foreach ($p in $running) { Write-Host ("        {0} (pid {1})  {2}" -f $p.ProcessName, $p.Id, $p.Path) -ForegroundColor $colour }
    if (-not $WhatIf) { Exit-Window 1 }
}

if ($WhatIf)
{
    if (-not $isAdmin)
    {
        Write-Host "  (Not elevated: Windows hides SYSTEM tasks and Defender exclusions from this view, so 'none' there proves" -ForegroundColor DarkGray
        Write-Host "   nothing. Run it from an elevated PowerShell to see them.)" -ForegroundColor DarkGray
    }
    Write-Host "What if: all of the above would be removed and the VHDX deleted. Nothing was changed." -ForegroundColor Yellow
    exit 0
}

# --------------------------------------------------------------------
# ASKED TWICE
# --------------------------------------------------------------------

Write-Host "THIS DELETES THE VHDX AND EVERYTHING ON THE DRIVE. It cannot be undone." -ForegroundColor Red
if ((Read-Host "Type YES to continue") -cne 'YES') { Write-Host "Cancelled; nothing was changed."; Exit-Window 0 }
if ((Read-Host ("Type the drive's label, {0}, to confirm" -f $label)) -cne $label) { Write-Host "Cancelled; nothing was changed."; Exit-Window 0 }

# --------------------------------------------------------------------
# REMOVE
# --------------------------------------------------------------------

$failed = 0
function Step { param([string]$What, [scriptblock]$Do)
    try { & $Do; Write-Host "  [OK] $What" -ForegroundColor Green }
    catch { Write-Host ("  [FAILED] {0}: {1}" -f $What, $_.Exception.Message) -ForegroundColor Red; $script:failed++ }
}

# Kits first: nothing on the drive is needed for it, and it must not be skipped by a later failure.
if ($qtKits.Count -gt 0)
{
    $ownQtc = @(Get-CimInstance Win32_Process -Filter "Name='qtcreator.exe'" -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -notmatch '-settingspath' })
    if ($ownQtc.Count -gt 0) { Write-Host "  [SKIPPED] your Qt Creator is running; take the kits out later: .\tools\Restore-QtCreatorSettings.ps1 -RemoveDrive $letter" -ForegroundColor Yellow }
    else
    {
        Step "your Qt Creator: drive $letter`:'s kits taken out (backup kept beside the files)" {
            $empty = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-qtusr-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $empty | Out-Null
            try { $r = Merge-DrivEnvQtUserSettings -GeneratedDir $empty -UserDir $qt.UserQtSettingsDir -OwnPrefix $qt.UserIdPrefix -Stamp (Get-Date -Format 'yyyyMMdd_HHmmss') }
            finally { Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue }
            if (-not $r.Ok) { throw $r.Message }
        }
    }
}

$dismounted = $true
if ($attached) { $before = $failed; Step "VHDX dismounted" { Dismount-DiskImage -ImagePath $vhd -ErrorAction Stop | Out-Null }; $dismounted = ($failed -eq $before) }
if (Test-Path -LiteralPath $vhd)
{
    if (-not $dismounted) { Write-Host "  [SKIPPED] the VHDX is not deleted: it could not be dismounted." -ForegroundColor Yellow }
    else { Step "VHDX deleted" { Remove-Item -LiteralPath $vhd -Force -ErrorAction Stop } }
}
foreach ($t in $tasks) { Step ("startup task {0} removed" -f $t.TaskName) { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop } }
foreach ($e in @($exDrive + $exRoot)) { Step "Defender exclusion $e removed" { Remove-MpPreference -ExclusionPath $e -ErrorAction Stop } }
foreach ($s in $shortcuts) { Step ("desktop shortcut {0} removed" -f $s.Name) { Remove-Item -LiteralPath $s.FullName -Force -ErrorAction Stop } }

# Then the mount-task inventory, as Manage-MountTasks.ps1 does it: it lists every startup mount task and offers to
# remove any OTHER orphan -- one whose VHDX is gone -- asking for each.
Write-Host ""
& (Join-Path $PSScriptRoot 'Manage-MountTasks.ps1') -Remove

Write-Host ""
if ($failed -gt 0) { Write-Host ("Done, with {0} failure(s) above." -f $failed) -ForegroundColor Yellow; Exit-Window 1 }
Write-Host ("Drive '{0}' removed." -f $label) -ForegroundColor Green
Exit-Window 0
