# ====================================================================
# IMPORT A DEV DRIVE EXPORTED FROM ANOTHER PC
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
# Updated: 21/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Runs from the package folder made by Export-DevDrive.ps1: double-click
# Import-DevDrive.cmd. Needs nothing installed; the generator travels in
# the drive (env\generator) and validates it once mounted.
#
#   .\Import-DevDrive.ps1                        C:\DevDrives, mode Auto
#   .\Import-DevDrive.ps1 -Destination E:\DevDrives -Mode Image -Force
#
# Modes:
#   Image     the packaged VHDX is used as is (NTFS). Windows 10 and 11.
#   DevDrive  a new Dev Drive (ReFS) is created and the files are copied
#             into it. Windows 11 22H2 or later; Auto picks it there.
# The drive keeps its letter: paths inside it name that letter, binaries
# included. If the letter is taken here, the import says what holds it
# and how to free it, and stops before writing anything.
# Exit code: 0 imported and validated, 2 imported but the validation
# (step 5) reported problems, 1 not imported.
# ====================================================================

[CmdletBinding()]
param
(
    [string]$Package = '',                   # folder with manifest.json; default: this script's folder
    [string]$Destination = 'C:\DevDrives',   # folder that receives the VHDX
    [ValidateSet('Auto', 'Image', 'DevDrive')]
    [string]$Mode = 'Auto',
    [switch]$Force,                          # no questions
    [switch]$ElevatedChild                   # internal: the elevated relaunch
)

$ErrorActionPreference = 'Stop'
if (-not $Package) { $Package = $PSScriptRoot }   # not as the parameter default: Windows PowerShell leaves it empty there
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = Join-Path ([IO.Path]::GetTempPath()) ("{0}_devdrive-import.log" -f $stamp)
function Log { param([string]$Level, [string]$Msg, [string]$Color = 'Gray')
    $line = "[{0}][{1}] {2}" -f (Get-Date).ToString('s'), $Level, $Msg
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    Write-Host $line -ForegroundColor $Color
}
function Info { param([string]$m) Log 'INFO' $m }
function Warn { param([string]$m) Log 'WARN' $m 'Yellow' }
function Fail { param([string]$m) Log 'ERROR' $m 'Red'; Exit-Window 1 }
function Exit-Window { param([int]$Code)
    if ($ElevatedChild -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) { Write-Host "Press Enter to close..."; [void](Read-Host) }
    exit $Code
}
function GB { param([double]$Bytes) return ("{0:N2} GB" -f ($Bytes / 1GB)) }
function Test-IsAdministrator { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Test-CanAsk { -not $Force -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected }
function Invoke-Diskpart { param([string[]]$Lines)
    $f = Join-Path ([IO.Path]::GetTempPath()) ("drivenv-diskpart-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllLines($f, $Lines, (New-Object System.Text.ASCIIEncoding))
    try { $out = & diskpart.exe /s $f 2>&1 | Out-String; $code = $LASTEXITCODE } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    Add-Content -LiteralPath $logFile -Value $out -Encoding UTF8
    if ($code -ne 0) { throw "diskpart failed (exit $code): $($out.Trim())" }
}
function Get-DataPartition { param($Image) $Image | Get-Disk | Get-Partition | Where-Object Type -eq 'Basic' | Select-Object -First 1 }
function Set-DriveLetter { param($Part)
    # With automount on, Windows may already have given the volume some letter: move it to ours, or add ours.
    $Part = Get-Partition -DiskNumber $Part.DiskNumber -PartitionNumber $Part.PartitionNumber
    if ([string]$Part.DriveLetter -notmatch '^[A-Z]$') { $Part | Add-PartitionAccessPath -AccessPath "${letter}:\" }
    elseif ([string]$Part.DriveLetter -ne $letter) { $Part | Set-Partition -NewDriveLetter $letter }
}

if (-not (Test-IsAdministrator))
{
    Write-Host "Importing needs administrator rights; relaunching elevated in a window of its own..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Package', ('"{0}"' -f $Package),
                 '-Destination', ('"{0}"' -f $Destination), '-Mode', $Mode, '-ElevatedChild')
    if ($Force) { $argList += '-Force' }
    try { $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait -PassThru } catch { Fail "Elevation was refused or failed; nothing was done." }
    exit $p.ExitCode
}

# -- the package ----------------------------------------------------------------------------------
$mfPath = Join-Path $Package 'manifest.json'
if (-not (Test-Path -LiteralPath $mfPath)) { Fail "No manifest.json in ${Package}: run this from an exported package folder." }
$mf = Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($mf.Format -ne 1) { Fail "Unknown package format '$($mf.Format)'; this importer reads format 1." }
$label  = [string]$mf.Drive.Label
$letter = [string]$mf.Drive.Letter
$src    = Join-Path $Package $mf.Vhdx.File
$zst    = "$src.zst"
$zstd   = Join-Path $Package 'zstd\zstd.exe'
$packed = -not (Test-Path -LiteralPath $src)
if ($packed -and -not (Test-Path -LiteralPath $zst)) { Fail "The package has neither $($mf.Vhdx.File) nor $($mf.Vhdx.File).zst." }
if ($packed -and -not (Test-Path -LiteralPath $zstd)) { Fail "The package is compressed but zstd\zstd.exe is missing from it." }

Write-Host ""
Info ("Package {0}: drive {1} ({2}:), {3}, exported {4} from {5}." -f $Package, $label, $letter, (GB $mf.Vhdx.Bytes), $mf.Created, $mf.Source.Computer)
if ($mf.Config.Metadata) { Info ("Configuration {0}: {1} {2}{3}" -f $mf.Config.File, $mf.Config.Metadata.name, $mf.Config.Metadata.version, $(if ($mf.Config.Metadata.target_os) { ", target $($mf.Config.Metadata.target_os)" })) }
$os = Get-CimInstance Win32_OperatingSystem
Info ("This PC: {0}, build {1}." -f $os.Caption, $os.BuildNumber)

# Dev Drive needs Windows 11 22H2 (build 22621.2338) or later; fsutil answers only where it exists.
$devDriveOk = $false
if ([Environment]::OSVersion.Version.Build -ge 22621) { & fsutil.exe devdrv query *> $null; $devDriveOk = ($LASTEXITCODE -eq 0) }
if ($Mode -eq 'Auto')
{
    $Mode = if ($devDriveOk) { 'DevDrive' } else { 'Image' }
    if ($devDriveOk -and (Test-CanAsk) -and ((Read-Host "This PC supports Dev Drive. Import as a new Dev Drive (D: faster builds, copies the files) or the image as is (I: NTFS, quicker)? [D/i]") -match '^i')) { $Mode = 'Image' }
}
elseif (($Mode -eq 'DevDrive') -and -not $devDriveOk) { Fail "This PC does not support Dev Drive (Windows 11 22H2, build 22621.2338 or later). Use -Mode Image." }

# -- checks, before anything is written ------------------------------------------------------------
# GetLogicalDrives also sees mapped drives, substs and attached disks without a volume (Get-Volume does not).
if (@([IO.Directory]::GetLogicalDrives() | ForEach-Object { $_.Substring(0, 1) }) -contains $letter)
{
    # Another letter is not offered: compiled-in paths in some DLLs (OpenSSL, gettext) cannot be moved with certainty.
    $holder = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    $what = if ($holder) { "a {0} volume '{1}'" -f $holder.DriveType, $holder.FileSystemLabel } else { "a mapped network drive or a subst" }
    Fail (("{0}: is held by {1} on this PC, and the drive needs {0}: (paths inside it name it). Free the letter and run the import again: " +
           "Disk Management > right-click the volume > Change Drive Letter and Paths, or from an elevated PowerShell Set-Partition -DriveLetter {0} -NewDriveLetter <free letter>; " +
           "a mapped drive: net use {0}: /delete; a subst: subst {0}: /d. Nothing was written.") -f $letter, $what)
}
$Destination = [IO.Path]::GetFullPath($Destination)
$target = Join-Path $Destination ("{0}.vhdx" -f $label)
if (Test-Path -LiteralPath $target) { Fail "$target already exists. Remove it, or import into another -Destination." }
$destRoot = [IO.Path]::GetPathRoot($Destination)
$destPart = Get-Partition -DriveLetter $destRoot[0] -ErrorAction SilentlyContinue
if (-not $destPart) { Fail "$destRoot is not a local disk." }
$destVol  = $destPart | Get-Volume
$destDisk = $destPart | Get-Disk
if (@('NTFS', 'ReFS') -notcontains $destVol.FileSystem) { Fail "$destRoot is $($destVol.FileSystem); the VHDX needs an NTFS or ReFS volume." }
if (@('USB', 'SD', 'MMC') -contains [string]$destDisk.BusType) { Fail "$destRoot is on a $($destDisk.BusType) disk; keep the VHDX on an internal disk (it is mounted at every startup)." }
$probe = if (Test-Path -LiteralPath $Destination) { $Destination } else { $destRoot }
if ((Get-Item -LiteralPath $probe).Attributes -band [IO.FileAttributes]::Compressed) { Fail "$probe is NTFS-compressed: Windows refuses to attach a VHDX stored compressed." }
$need = $mf.Vhdx.Bytes * 1.1 + 512MB
if (($Mode -eq 'DevDrive') -and $packed) { $need += $mf.Vhdx.Bytes }   # the decompressed package, removed afterwards
$free = (New-Object System.IO.DriveInfo($destRoot)).AvailableFreeSpace
if ($free -lt $need) { Fail ("Not enough space on {0}: {1} free, about {2} needed." -f $destRoot, (GB $free), (GB $need)) }

Info ("Mode {0}: {1}" -f $Mode, $(if ($Mode -eq 'DevDrive') { "a new Dev Drive (ReFS) at $target, the files copied into it." } else { "the VHDX $(if ($packed) { 'decompressed' } else { 'copied' }) to $target as is (NTFS)." }))
$autoMount = $null   # $null: as the drive's configuration says (environment.automount_at_startup)
if (Test-CanAsk)
{
    $autoMount = (Read-Host "Mount the drive by itself at every startup (a scheduled task; no admin needed afterwards)? [Y/n]") -notmatch '^n'
    if ((Read-Host ("Import the drive as {0}: from {1}? Type YES" -f $letter, $target)) -cne 'YES') { Info "Cancelled; nothing was written."; Exit-Window 0 }
}

# -- the drive ----------------------------------------------------------------------------------------
function Expand-Package { param([string]$To)
    Info "Decompressing the package into $To..."
    & $zstd -d -q -f -o $To $zst
    if ($LASTEXITCODE) { throw "zstd failed (exit $LASTEXITCODE)." }
}
function Assert-PackageHash { param([string]$Path)
    Info "Checking the SHA-256 of $Path..."
    $h = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($h -cne $mf.Vhdx.Sha256) { throw "SHA-256 mismatch ($h, expected $($mf.Vhdx.Sha256)): the package is damaged." }
}

New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$tmp = $null; $source = $src; $err = $null
try
{
    if ($Mode -eq 'Image')
    {
        if ($packed) { Expand-Package $target }
        else
        {
            Info "Copying the VHDX to $target..."
            & robocopy.exe $Package $Destination $mf.Vhdx.File '/J' '/NP' '/NFL' '/NDL' '/R:1' '/W:1' | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE)." }
        }
        Assert-PackageHash $target
        Info "Attaching $target as ${letter}:..."
        Set-DriveLetter (Get-DataPartition (Mount-DiskImage -ImagePath $target -PassThru))
    }
    else
    {
        if ($packed) { $tmp = Join-Path $Destination ("{0}.import-tmp.vhdx" -f $label); Expand-Package $tmp; $source = $tmp }
        Assert-PackageHash $source

        # The new drive takes the letter first, so the package attached next cannot be given it.
        $capacityMB = [math]::Max([math]::Ceiling($mf.Drive.CapacityBytes / 1MB), 52224)   # Dev Drive: 50 GB minimum
        Info "Creating the Dev Drive $target (dynamic, $capacityMB MB) as ${letter}:..."
        Invoke-Diskpart @("create vdisk file=""$target"" maximum=$capacityMB type=expandable", "select vdisk file=""$target""", "attach vdisk")
        $disk = Get-DiskImage -ImagePath $target | Get-Disk
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize
        $part | Format-Volume -DevDrive -NewFileSystemLabel $label -Confirm:$false -Force | Out-Null
        Set-DriveLetter $part

        Info "Copying the files from the package (attached read-only)..."
        $roPart = Get-DataPartition (Mount-DiskImage -ImagePath $source -Access ReadOnly -PassThru)
        if ([string]$roPart.DriveLetter -notmatch '^[A-Z]$')
        {
            $roPart | Add-PartitionAccessPath -AssignDriveLetter
            $roPart = Get-Partition -DiskNumber $roPart.DiskNumber -PartitionNumber $roPart.PartitionNumber
        }
        $from = "$($roPart.DriveLetter):\"
        $rcLog = Join-Path ([IO.Path]::GetTempPath()) ("{0}_devdrive-import-robocopy.log" -f $stamp)
        & robocopy.exe $from "${letter}:\" '/E' '/COPY:DAT' '/DCOPY:DAT' '/XJ' '/SL' '/B' '/MT:16' '/R:1' '/W:1' '/NP' '/NFL' '/NDL' "/LOG:$rcLog" '/XD' "${from}System Volume Information" "${from}`$RECYCLE.BIN" | Out-Null
        $rc = $LASTEXITCODE
        Dismount-DiskImage -ImagePath $source | Out-Null
        if ($rc -ge 8) { throw "robocopy failed (exit $rc); see $rcLog" }

        $trust = & fsutil.exe devdrv trust "${letter}:" 2>&1
        if ($LASTEXITCODE) { Warn "fsutil devdrv trust failed (exit $LASTEXITCODE): $trust" } else { Info "Dev Drive trusted: Defender scans it in performance mode." }
    }
}
catch
{
    $err = $_.Exception.Message
    Dismount-DiskImage -ImagePath $target -ErrorAction SilentlyContinue | Out-Null
    if ($source -ne $target) { Dismount-DiskImage -ImagePath $source -ErrorAction SilentlyContinue | Out-Null }
    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
}
finally { if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
if ($err) { Fail "Import failed: $err. Nothing was left behind in $Destination." }
if (-not (Test-Path -LiteralPath "${letter}:\env\generator")) { Fail "${letter}: is attached but has no env\generator; the package is not a drive export." }

# -- integration with this PC ----------------------------------------------------------------------
$drive   = "${letter}:\"
$gen     = Join-Path $drive 'env\generator'
$cfgFile = Join-Path $gen ("config\{0}" -f $mf.Config.File)

# The embedded configuration now describes this PC: where the VHDX lives and what the volume is. Values replaced
# in place, so the file keeps its layout.
$text = [IO.File]::ReadAllText($cfgFile)
if ($null -eq $autoMount) { $autoMount = ($text | ConvertFrom-Json).environment.automount_at_startup -ne $false }
$text = [regex]::Replace($text, '("vhd_root"\s*:\s*)"[^"]*"', { $args[0].Groups[1].Value + '"' + $Destination.Replace('\', '/') + '"' })
$text = [regex]::Replace($text, '("use_dev_drive"\s*:\s*)(true|false)', { $args[0].Groups[1].Value + ([string]($Mode -eq 'DevDrive')).ToLowerInvariant() })
$text = [regex]::Replace($text, '("automount_at_startup"\s*:\s*)(true|false)', { $args[0].Groups[1].Value + ([string]$autoMount).ToLowerInvariant() })
[IO.File]::WriteAllText($cfgFile, $text, (New-Object System.Text.UTF8Encoding($false)))
Info "Configuration updated for this PC: $cfgFile"

# Git refuses repositories owned by another account ("dubious ownership"), and the copy belongs to whoever made it.
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$repos = @(Get-ChildItem -LiteralPath $drive -Directory -Force | Where-Object Name -notin @('msys64', 'System Volume Information', '$RECYCLE.BIN') |
           ForEach-Object { $_; Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction SilentlyContinue } | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') })
foreach ($r in $repos) { & icacls.exe $r.FullName /setowner $me /T /C /Q | Out-Null }
if ($repos.Count) { Info ("Repositories now owned by {0}: {1}" -f $me, (($repos | ForEach-Object Name) -join ', ')) }

if ($autoMount)
{
    # The same task as step 1 registers (Mount-DiskImage: no Hyper-V needed). Manage-MountTasks.ps1 and Remove-DevDrive.ps1 parse it.
    $taskName = "DrivEnv_{0}_{1}" -f $label, $letter
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-WindowStyle Hidden -Command `"Mount-DiskImage -ImagePath '$target' -ErrorAction SilentlyContinue`""
    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) -Description "DrivEnv-Win automatic mount for $target" -Force | Out-Null
    Info "Registered mount task '$taskName'."
}
else { Info "No mount at startup. To mount it later: double-click $target, or Mount-DiskImage -ImagePath '$target' (both need administrator rights)." }

if ($Mode -eq 'Image')
{
    # As step 1 does, and read back: Tamper Protection or a managed policy can turn the call into a silent no-op.
    try
    {
        Add-MpPreference -ExclusionPath $drive -ErrorAction Stop
        if (@((Get-MpPreference).ExclusionPath) -contains $drive) { Info "Defender exclusion confirmed for $drive" } else { Warn "Defender did not keep the exclusion for $drive (Tamper Protection or a policy). Builds work, slower." }
    }
    catch { Warn "Could not add the Defender exclusion for ${drive}: $($_.Exception.Message). Builds work, slower." }
}

$status = 0
Info "Validating the environment (step 5 of the embedded generator)..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $gen 'Generate-DrivEnv.ps1') -ConfigFile $cfgFile -From 5 -To 5
if ($LASTEXITCODE) { $status = 2; Warn "The validation reported problems (exit $LASTEXITCODE); its log is in $gen\logs." }

if ((Test-CanAsk) -and ((Read-Host "Register the drive's Qt Creator kits for this user (step 7)? [y/N]") -match '^(y|s)'))
{
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $gen 'Generate-DrivEnv.ps1') -ConfigFile $cfgFile -From 7 -To 7
    if ($LASTEXITCODE) { Warn "Step 7 reported problems (exit $LASTEXITCODE)." }
}

$records = Join-Path $drive 'installation'
New-Item -ItemType Directory -Path $records -Force | Out-Null
Log 'INFO' ("[OK] {0} imported as {1} ({2}) from {3}." -f $label, $drive, $Mode, $target) 'Green'
Copy-Item -LiteralPath $logFile -Destination (Join-Path $records ("import_{0}.log" -f $stamp)) -Force
Exit-Window $status
