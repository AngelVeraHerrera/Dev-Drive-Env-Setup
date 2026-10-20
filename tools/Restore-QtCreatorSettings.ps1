# ====================================================================
# YOUR OWN QT CREATOR'S SETTINGS: BACKUPS, RESTORE, AND DRIVE KITS OUT
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Backups of your own Qt Creator's settings made by step 7 (one set per
# run: <file>.xml.drivenv-<yyyyMMdd_HHmmss>.bak), and the drive kits in it.
#
#   .\tools\Restore-QtCreatorSettings.ps1                   list backup sets and drive kits
#   .\tools\Restore-QtCreatorSettings.ps1 -RemoveDrive D    take drive D:'s kits out, keep the rest
#   .\tools\Restore-QtCreatorSettings.ps1 -Restore latest   put a set back exactly (or -Restore <stamp>)
#   -SettingsPath <dir>  -Force  -WhatIf
#
# -RemoveDrive keeps later changes; -Restore does not. Both refuse while
# your own Qt Creator runs and back up the current files first.
# ====================================================================

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param
(
    [string]$Restore = "",                          # stamp or 'latest'
    [string]$RemoveDrive = "",                      # drive letter
    [string]$SettingsPath = "%APPDATA%/QtProject",  # folder holding QtCreator.ini
    [switch]$Force                                  # do not ask
)

$ErrorActionPreference = "Stop"
if ($Force) { $ConfirmPreference = 'None' }
. (Join-Path $PSScriptRoot "..\scripts\DrivEnvConfig.ps1")

$userDir = Join-Path ([Environment]::ExpandEnvironmentVariables($SettingsPath).Replace('/', '\').TrimEnd('\')) 'qtcreator'
$files   = @('profiles.xml', 'toolchains.xml', 'debuggers.xml', 'cmaketools.xml', 'qtversion.xml')
$stampRx = '^(?<file>.+\.xml)\.drivenv-(?<stamp>\d{8}_\d{6})\.bak$'

function Get-BackupSets
{
    # @return The backup sets, newest first: @{ Stamp; Files = @{ name -> path } }.
    $sets = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $userDir -File -Filter '*.drivenv-*.bak' -ErrorAction SilentlyContinue))
    {
        $m = [regex]::Match($f.Name, $stampRx)
        if (-not $m.Success) { continue }
        $s = $m.Groups['stamp'].Value
        if (-not $sets.ContainsKey($s)) { $sets[$s] = @{} }
        $sets[$s][$m.Groups['file'].Value] = $f.FullName
    }
    return @($sets.Keys | Sort-Object -Descending | ForEach-Object { [pscustomobject]@{ Stamp = $_; Files = $sets[$_] } })
}

function Get-DriveKits
{
    # @return The kits with a 'drivenv.<letter>.' id: @{ Letter; Name }.
    $p = Join-Path $userDir 'profiles.xml'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $x = [xml](Get-Content -LiteralPath $p -Raw -Encoding UTF8)
    $out = @()
    foreach ($d in @($x.qtcreator.data | Where-Object { $_.variable -match '^Profile\.\d+$' }))
    {
        $id   = @($d.valuemap.value | Where-Object { $_.key -eq 'PE.Profile.Id' })[0].'#text'
        $name = @($d.valuemap.value | Where-Object { $_.key -eq 'PE.Profile.Name' })[0].'#text'
        if ($id -match '^drivenv\.([a-z])\.') { $out += [pscustomobject]@{ Letter = $Matches[1].ToUpperInvariant(); Name = $name } }
    }
    return $out
}

function Test-OwnQtCreatorRunning
{
    $WhatIfPreference = $false   # keeps -WhatIf out of CimCmdlets' auto-load
    return (@(Get-CimInstance Win32_Process -Filter "Name='qtcreator.exe'" -ErrorAction SilentlyContinue |
              Where-Object { [string]$_.CommandLine -notmatch '-settingspath' }).Count -gt 0)
}

Write-Host ""
Write-Host "Your own Qt Creator's settings: $userDir" -ForegroundColor Cyan
Write-Host ("=" * 78) -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $userDir))
{
    Write-Host "  The directory does not exist: this Qt Creator has never been run, or keeps its settings elsewhere."
    exit 0
}

$sets = @(Get-BackupSets)
$kits = @(Get-DriveKits)

if (-not $Restore -and -not $RemoveDrive)
{
    Write-Host "  Backup sets (newest first):"
    if ($sets.Count -eq 0) { Write-Host "    none" }
    foreach ($s in $sets) { Write-Host ("    {0}  {1}" -f $s.Stamp, (($s.Files.Keys | Sort-Object) -join ', ')) }
    Write-Host ""
    Write-Host "  Drive kits registered here:"
    if ($kits.Count -eq 0) { Write-Host "    none" }
    foreach ($k in $kits) { Write-Host ("    {0}:  {1}" -f $k.Letter, $k.Name) }
    Write-Host ""
    Write-Host "  -RemoveDrive <letter> takes one drive's kits out and keeps everything else (the undo to reach for first)."
    Write-Host "  -Restore <stamp>|latest puts a set back exactly, losing what changed in Qt Creator since." -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

if (Test-OwnQtCreatorRunning)
{
    Write-Host "[ERROR] Your own Qt Creator is running. Close it first: it rewrites these files when it exits." -ForegroundColor Red
    exit 1
}

$now = Get-Date -Format "yyyyMMdd_HHmmss"
# Never reuse a set's stamp: its backups could be the set being restored.
while (@(Get-ChildItem -LiteralPath $userDir -File -Filter "*.drivenv-$now.bak").Count -gt 0) { Start-Sleep -Seconds 1; $now = Get-Date -Format "yyyyMMdd_HHmmss" }

if ($RemoveDrive)
{
    $letter = $RemoveDrive.Trim().TrimEnd(':', '\').ToLowerInvariant()
    if ($letter -notmatch '^[a-z]$') { Write-Host "[ERROR] -RemoveDrive takes a drive letter, e.g. D." -ForegroundColor Red; exit 1 }
    $mine = @($kits | Where-Object { $_.Letter -eq $letter.ToUpperInvariant() })
    if ($mine.Count -eq 0) { Write-Host ("  No kits of drive {0}: here. Nothing to do." -f $letter.ToUpperInvariant()); exit 0 }
    if (-not $PSCmdlet.ShouldProcess($userDir, ("Take out drive {0}:'s kits: {1}" -f $letter.ToUpperInvariant(), ((@($mine | ForEach-Object { $_.Name })) -join ', ')))) { exit 0 }

    # Step 7's merge with nothing to add: removes this drive's entries, with a backup.
    $empty = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-qtusr-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty | Out-Null
    try { $r = Merge-DrivEnvQtUserSettings -GeneratedDir $empty -UserDir $userDir -OwnPrefix ("drivenv.{0}." -f $letter) -Stamp $now }
    finally { Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not $r.Ok) { Write-Host "[ERROR] $($r.Message)" -ForegroundColor Red; exit 1 }
    Write-Host ("  [OK] drive {0}:'s kits taken out. Backup of the files as they were: *.drivenv-{1}.bak" -f $letter.ToUpperInvariant(), $now) -ForegroundColor Green
    exit 0
}

# -Restore
$set = if ($Restore -ieq 'latest') { $sets | Select-Object -First 1 } else { $sets | Where-Object { $_.Stamp -eq $Restore.Trim() } | Select-Object -First 1 }
if (-not $set) { Write-Host ("[ERROR] No backup set '{0}'. Run without arguments to list them." -f $Restore) -ForegroundColor Red; exit 1 }
if (-not $PSCmdlet.ShouldProcess($userDir, ("Put back the set {0} ({1}), losing what changed in Qt Creator since" -f $set.Stamp, (($set.Files.Keys | Sort-Object) -join ', ')))) { exit 0 }

# Back up the current files first, so a restore can be undone.
foreach ($name in $files)
{
    $cur = Join-Path $userDir $name
    if (Test-Path -LiteralPath $cur) { Copy-Item -LiteralPath $cur -Destination ("{0}.drivenv-{1}.bak" -f $cur, $now) -Force }
}
foreach ($name in $set.Files.Keys) { Copy-Item -LiteralPath $set.Files[$name] -Destination (Join-Path $userDir $name) -Force }
$bad = @($set.Files.Keys | Where-Object { (Get-FileHash -LiteralPath (Join-Path $userDir $_)).Hash -ne (Get-FileHash -LiteralPath $set.Files[$_]).Hash })
if ($bad.Count -gt 0) { Write-Host ("[ERROR] Not restored exactly: {0}. The files before this restore are in *.drivenv-{1}.bak." -f ($bad -join ', '), $now) -ForegroundColor Red; exit 1 }
Write-Host ("  [OK] set {0} restored. The files as they were just before: *.drivenv-{1}.bak" -f $set.Stamp, $now) -ForegroundColor Green
exit 0
