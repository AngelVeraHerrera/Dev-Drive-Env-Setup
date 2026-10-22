# ====================================================================
# EXPORT A DEV DRIVE TO ANOTHER PC
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Copies the drive into a NEW dynamic VHDX inside a package folder. The
# drive itself is only read: nothing on it is deleted or rewritten. What
# a cleanup would remove is simply left out of the copy.
#
#   .\tools\Export-DevDrive.ps1 -ConfigFile drivenv-cfg.json -Diagnose
#   .\tools\Export-DevDrive.ps1 -ConfigFile drivenv-cfg.json -Destination E:\exports
#   ... -Full            leave out every optional category (no questions)
#   ... -Exclude downloads,user_builds    leave out these optional ones
#   ... -Compress        compress the VHDX with zstd (about a third)
#   ... -Archive         pack the package folder into one .zip to carry
#   ... -RemoveProxy     the copy without the drive's proxy (another network)
#   ... -Force           no confirmation
#
# Package: <Destination>\<label>_<stamp>\ with <label>.vhdx (or .vhdx.zst
# and zstd\), manifest.json, the logs and Import-DevDrive.cmd/.ps1: copy
# the folder (or the .zip, then Extract All) to the other PC and
# double-click Import-DevDrive.cmd. The copy carries the generator in
# <drive>:\env\generator.
# Needs administrator rights (creating and attaching a VHDX); relaunches
# itself elevated. -Diagnose needs none.
# ====================================================================

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,                 # a bare name resolves against config/
    [string]$Destination = "",           # folder that receives the package
    [switch]$Diagnose,                   # report only
    [switch]$Full,                       # leave out every optional category
    [string[]]$Exclude = @(),            # optional categories to leave out
    [switch]$Compress,                   # zstd the VHDX
    [switch]$Archive,                    # pack the package into one .zip
    [switch]$RemoveProxy,                # the copy without environment.proxy_url
    [switch]$Force,                      # no confirmation
    [switch]$ElevatedChild               # internal: the elevated relaunch
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root "scripts\DrivEnvConfig.ps1")
. (Join-Path $root "scripts\DrivEnvPortability.ps1")

$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$logDir  = Join-Path $root 'logs'; New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ("{0}_devdrive-export.log" -f $stamp)
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
function Get-TreeBytes { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { return 0 } [double](Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum }
function Test-IsAdministrator { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Invoke-Diskpart { param([string[]]$Lines)
    $f = Join-Path ([IO.Path]::GetTempPath()) ("drivenv-diskpart-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllLines($f, $Lines, (New-Object System.Text.ASCIIEncoding))
    try { $out = & diskpart.exe /s $f 2>&1 | Out-String; $code = $LASTEXITCODE } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    Add-Content -LiteralPath $logFile -Value $out -Encoding UTF8
    if ($code -ne 0) { throw "diskpart failed (exit $code): $($out.Trim())" }
}

# -- configuration -------------------------------------------------------------
$configPath = Resolve-DrivEnvConfigPath -ConfigFile $ConfigFile -GeneratorRoot $root
if (-not (Test-Path -LiteralPath $configPath)) { Fail "Configuration not found: $configPath" }
$cfg = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$problems = @(Test-DrivEnvConfig -Config $cfg)
if ($problems.Count) { $problems | ForEach-Object { Log 'ERROR' $_ 'Red' }; Exit-Window 1 }

if (-not $Diagnose -and -not (Test-IsAdministrator))
{
    if (-not $Destination) { Fail "-Destination is required to export (or use -Diagnose)." }
    Write-Host "Exporting needs administrator rights; relaunching elevated in a window of its own..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-ConfigFile', ('"{0}"' -f $configPath),
                 '-Destination', ('"{0}"' -f $Destination), '-ElevatedChild')
    if ($Full) { $argList += '-Full' }
    if ($Exclude.Count) { $argList += @('-Exclude', ('"{0}"' -f ($Exclude -join ','))) }
    if ($Compress) { $argList += '-Compress' }
    if ($Archive) { $argList += '-Archive' }
    if ($RemoveProxy) { $argList += '-RemoveProxy' }
    if ($Force) { $argList += '-Force' }
    try { $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait -PassThru } catch { Fail "Elevation was refused or failed; nothing was done." }
    exit $p.ExitCode
}
$Exclude = @($Exclude | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$letter = ([string]$cfg.environment.dev_drive_letter).Trim().TrimEnd(':', '\').ToUpperInvariant()
$label  = ([string]$cfg.environment.dev_drive_label).Trim()
$vhd    = Join-Path (([string]$cfg.environment.vhd_root).Trim().Replace('/', '\').TrimEnd('\')) ("{0}.vhdx" -f $label)
$drive  = "${letter}:\"

Write-Host ""
Info ("Export of {0} ({1}:) -- {2}" -f $label, $letter, $(if ($Diagnose) { 'diagnosis only' } else { "to $Destination" }))
$meta = Get-DrivEnvMetadataSummary -Cfg $cfg; if ($meta) { Info $meta }

# -- the drive -----------------------------------------------------------------------
$image = $null; try { $image = Get-DiskImage -ImagePath $vhd -ErrorAction Stop } catch { }
$vol = $null; try { $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop } catch { }
if (-not ($image -and $image.Attached -and $vol)) { Fail "The drive is not mounted at ${letter}: from $vhd. Mount it first." }
if ($vol.FileSystem -ne 'NTFS') { Fail "Only NTFS drives are exported for now ($($vol.FileSystem) found): a Dev Drive (ReFS) export needs Windows 11 and is not implemented yet." }
$fileBytes = (Get-Item -LiteralPath $vhd).Length
$usedBytes = $vol.Size - $vol.SizeRemaining
Info ("VHDX {0}: file {1}; volume NTFS, capacity {2}, used {3}." -f $vhd, (GB $fileBytes), (GB $vol.Size), (GB $usedBytes))

# -- what would be copied ----------------------------------------------------------------
$btWin    = ((Resolve-DrivEnvBuildtreesRoot -Cfg $cfg -DriveLetter $letter).Windows).Replace('/', '\')
$binCache = Join-Path $drive 'packages\vcpkg'
$targets  = Get-DrivEnvDeclaredTargets -Cfg $cfg
$triplets = @(foreach ($t in $targets) { if ($t.Triplet) { $t.Triplet } })
$cats     = Get-DrivEnvPortabilityCategories -Drive $drive -BuildtreesWin $btWin -BinaryCache $binCache

# Per category: its size and the exact folders a copy would leave out.
$sizes = @{}; $dirs = @{}; foreach ($c in $cats) { $sizes[$c.Key] = 0; $dirs[$c.Key] = @() }
if (Test-Path -LiteralPath $btWin)
{
    foreach ($e in @(Get-ChildItem -LiteralPath $btWin -Directory -Force -ErrorAction SilentlyContinue))
    {
        $files = @(Get-ChildItem -LiteralPath $e.FullName -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $key = switch (Get-DrivEnvBuildtreeEntryKind -Name $e.Name -FileNames $files -Triplets $triplets) { 'port' { 'buildtree_ports' } 'user' { 'user_builds' } 'internal' { 'buildtree_internal' } default { $null } }
        if ($key) { $sizes[$key] += Get-TreeBytes $e.FullName; $dirs[$key] += $e.FullName } else { Warn "Unrecognised build tree folder, copied as is: $($e.FullName)" }
    }
}
foreach ($c in $cats | Where-Object { $_.Key -notin @('buildtree_ports', 'user_builds', 'buildtree_internal') })
{
    foreach ($p in $c.Paths) { if (Test-Path -LiteralPath $p) { $sizes[$c.Key] += Get-TreeBytes $p; $dirs[$c.Key] += $p } }
}
$always   = @((Join-Path $drive 'System Volume Information'), (Join-Path $drive '$RECYCLE.BIN'))
$total    = [double](Get-ChildItem -LiteralPath $drive -Force -ErrorAction SilentlyContinue | Where-Object { $always -notcontains $_.FullName } |
                     ForEach-Object { if ($_.PSIsContainer) { Get-TreeBytes $_.FullName } else { $_.Length } } | Measure-Object -Sum).Sum

Write-Host ""
Write-Host ("  {0,-20} {1,-9} {2,12}  {3}" -f 'Category', 'Class', 'Size', 'If left out') -ForegroundColor Cyan
foreach ($c in $cats) { Write-Host ("  {0,-20} {1,-9} {2,12}  {3}" -f $c.Key, $c.Class, (GB $sizes[$c.Key]), $c.Effect) }
$safeBytes = (@($cats | Where-Object Class -eq 'safe' | ForEach-Object { $sizes[$_.Key] }) | Measure-Object -Sum).Sum
$optBytes  = (@($cats | Where-Object Class -eq 'optional' | ForEach-Object { $sizes[$_.Key] }) | Measure-Object -Sum).Sum
Info ("Files on the drive: {0}. A copy weighs about {1} (safe categories left out, always), {2} with every optional one left out too." -f (GB $total), (GB ($total - $safeBytes)), (GB ($total - $safeBytes - $optBytes)))
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($drive, [System.StringComparison]::OrdinalIgnoreCase) })
if ($running.Count) { Warn ("Programs running from the drive: {0}. Close them before exporting: a copy of files being written is not consistent." -f (($running | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join ', ')) }
if ($Diagnose) { Info "Diagnosis only: nothing was written. Log: $logFile"; exit 0 }

# -- what to leave out ---------------------------------------------------------------------------
if (-not $Full -and $Exclude.Count -eq 0 -and -not $Force -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
{
    $ans = Read-Host ("Full cleanup of the copy? Leaves out every optional category too ({0} less) [y/N]" -f (GB $optBytes))
    if ($ans -match '^(y|s)') { $Full = $true }
    else
    {
        foreach ($c in $cats | Where-Object Class -eq 'optional')
        {
            if ((Read-Host ("  Leave out {0} ({1}): {2}? [y/N]" -f $c.Key, (GB $sizes[$c.Key]), $c.Effect)) -match '^(y|s)') { $Exclude += $c.Key }
        }
    }
}
$canAsk = -not $Force -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
if (-not $Archive -and $canAsk)
{
    $Archive = (Read-Host "Pack the package into one .zip file to carry it (the importer goes inside)? [y/N]") -match '^(y|s)'
}
# The .zip only bundles (stored); the size comes from zstd, so an archive always carries a compressed VHDX.
if ($Archive) { $Compress = $true }
elseif (-not $Compress -and $canAsk)
{
    $Compress = (Read-Host "Compress the VHDX with zstd (about a third of the size, under a minute)? [Y/n]") -notmatch '^n'
}
$proxyUrl = [string]$cfg.environment.proxy_url
if (-not $RemoveProxy -and $proxyUrl -and $canAsk)
{
    $RemoveProxy = (Read-Host "The drive goes through the proxy $proxyUrl. Export it without the proxy (for a PC on another network)? [y/N]") -match '^(y|s)'
}
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if ($Archive -and -not (Test-Path -LiteralPath $tar)) { Fail "-Archive needs Windows' tar.exe (Windows 10 1803 or later): $tar not found." }
# zstd travels in the package for the import; the drive's own MSYS2 build (zstd.exe + libzstd.dll, nothing else).
$zstdDir = $null
if ($Compress)
{
    $zstdDir = @('ucrt64', 'clang64', 'mingw64') | ForEach-Object { Join-Path $drive "msys64\$_\bin" } |
               Where-Object { (Test-Path -LiteralPath "$_\zstd.exe") -and (Test-Path -LiteralPath "$_\libzstd.dll") } | Select-Object -First 1
    if (-not $zstdDir) { Fail "-Compress needs zstd on the drive (msys64\<subsystem>\bin\zstd.exe and libzstd.dll); none found." }
}
try { $excluded = Get-DrivEnvExportExclusions -Categories $cats -Full:$Full -Exclude $Exclude } catch { Fail $_.Exception.Message }
$xd = @($always) + @($excluded | ForEach-Object { $dirs[$_] })
$copyBytes = $total - (@($excluded | ForEach-Object { $sizes[$_] }) | Measure-Object -Sum).Sum
Info ("Left out of the copy: {0}. Copy: about {1}." -f ($excluded -join ', '), (GB $copyBytes))
if ($running.Count) { Fail "Programs are running from the drive; nothing was exported." }

$pkg = Join-Path $Destination ("{0}_{1}" -f $label, $stamp)
$newVhd = Join-Path $pkg ("{0}.vhdx" -f $label)
$destRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destination))
$free = (New-Object System.IO.DriveInfo($destRoot)).AvailableFreeSpace
$need = $copyBytes * $(if ($Archive) { 2.2 } else { 1.1 }) + 512MB   # the .zip is written next to the folder before the folder goes
if ($free -lt $need) { Fail ("Not enough space on {0}: {1} free, about {2} needed." -f $destRoot, (GB $free), (GB $need)) }
if ((Get-Item -LiteralPath $destRoot).Attributes -band [IO.FileAttributes]::Compressed) { Warn "The destination is NTFS-compressed: Windows refuses to attach a VHDX stored compressed." }
if (-not $Force)
{
    if ((Read-Host ("Create {0} and copy the drive into it? The drive itself is only read. Type YES" -f $newVhd)) -cne 'YES') { Info "Cancelled; nothing was written."; Exit-Window 0 }
}

# -- the new VHDX --------------------------------------------------------------------------------
New-Item -ItemType Directory -Path $pkg -Force | Out-Null
$mnt = Join-Path ([IO.Path]::GetTempPath()) ("drivenv-export-{0}" -f $stamp)
New-Item -ItemType Directory -Path $mnt -Force | Out-Null
$capacityMB = [math]::Ceiling($image.Size / 1MB)
$attached = $false
try
{
    Info "Creating $newVhd (dynamic, $capacityMB MB) mounted at $mnt..."
    Invoke-Diskpart @("create vdisk file=""$newVhd"" maximum=$capacityMB type=expandable", "select vdisk file=""$newVhd""", "attach vdisk", "convert gpt",
                      "create partition primary", "format quick fs=ntfs label=""$label""", "assign mount=""$mnt""")
    $attached = $true

    Info "Copying the drive (robocopy, read-only on the drive)..."
    $rcLog = Join-Path $pkg 'robocopy.log'
    $rcArgs = @($drive, $mnt, '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/SL', '/B', '/MT:16', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', '/BYTES', "/LOG:$rcLog", '/XD') + $xd
    & robocopy.exe @rcArgs | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { throw "robocopy failed (exit $rc); see $rcLog" }
    $failedLine = @(Select-String -LiteralPath $rcLog -Pattern '^\s*(Files|Archivos)\s*:' | Select-Object -Last 1)
    Info ("robocopy finished (exit {0}). {1}" -f $rc, $(if ($failedLine) { $failedLine[0].Line.Trim() } else { '' }))

    # The drive carries what is needed to integrate it elsewhere: the generator and its configuration.
    $gen = Join-Path $mnt 'env\generator'
    & robocopy.exe $root $gen 'Generate-DrivEnv.ps1' 'README.md' 'LICENSE' '/NFL' '/NDL' '/NP' '/R:1' '/W:1' | Out-Null
    foreach ($dir in 'scripts', 'tools', 'drive', 'vcpkg_overlays')
    {
        if ($LASTEXITCODE -lt 8) { & robocopy.exe (Join-Path $root $dir) (Join-Path $gen $dir) '/E' '/NFL' '/NDL' '/NP' '/R:1' '/W:1' | Out-Null }
    }
    if ($LASTEXITCODE -ge 8) { throw "Copying the generator into the drive failed (robocopy exit $LASTEXITCODE)." }
    New-Item -ItemType Directory -Path (Join-Path $gen 'config') -Force | Out-Null
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $gen 'config') -Force
    Info "Generator and configuration embedded in the copy (env\generator)."

    if ($RemoveProxy)
    {
        # Undo, in the copy, what step 2 wrote from environment.proxy_url: its profile.d script and dirmngr.conf (both
        # written whole), the [http] proxy of etc/gitconfig (the git identity stays) and the value in the configuration.
        Remove-Item -LiteralPath (Join-Path $mnt 'msys64\etc\profile.d\devsystem-proxy.sh'), (Join-Path $mnt 'msys64\etc\pacman.d\gnupg\dirmngr.conf') -Force -ErrorAction SilentlyContinue
        $gc = Join-Path $mnt 'msys64\etc\gitconfig'
        if (Test-Path -LiteralPath $gc)
        {
            $t = [regex]::Replace([IO.File]::ReadAllText($gc), '(?m)^[ \t]*proxy[ \t]*=.*(\r?\n|\z)', '')
            [IO.File]::WriteAllText($gc, [regex]::Replace($t, '(?m)^\[http\][ \t]*(\r?\n)*(?=\[|\z)', ''), (New-Object System.Text.UTF8Encoding($false)))
        }
        $cf = Join-Path $gen ("config\{0}" -f (Split-Path -Leaf $configPath))
        [IO.File]::WriteAllText($cf, [regex]::Replace([IO.File]::ReadAllText($cf), '("proxy_url"\s*:\s*)"[^"]*"', '$1""'), (New-Object System.Text.UTF8Encoding($false)))
        Info "Proxy removed from the copy ($proxyUrl): MSYS2 profile, dirmngr, git and the configuration."
    }
}
catch { Warn $_.Exception.Message; $err = $_.Exception.Message }
finally
{
    if ($attached) { try { Invoke-Diskpart @("select vdisk file=""$newVhd""", "detach vdisk") } catch { Warn "Could not detach ${newVhd}: $($_.Exception.Message)" } }
    Remove-Item -LiteralPath $mnt -Force -ErrorAction SilentlyContinue
}
if ($err) { Fail "Export failed: $err. The drive was not touched; the incomplete package is in $pkg." }

# -- manifest and verification ----------------------------------------------------------------
Info "Hashing the package..."
$hash = (Get-FileHash -LiteralPath $newVhd -Algorithm SHA256).Hash
$manifest = [ordered]@{
    Format = 1; Created = (Get-Date).ToString('s'); Generator = '3.0.0'
    Source = [ordered]@{ Computer = $env:COMPUTERNAME; User = $env:USERNAME; Os = [Environment]::OSVersion.Version.ToString(); Vhdx = $vhd }
    Drive  = [ordered]@{ Label = $label; Letter = $letter; FileSystem = 'NTFS'; CapacityBytes = $image.Size; DevDrive = $false }
    Vhdx   = [ordered]@{ File = (Split-Path -Leaf $newVhd); Bytes = (Get-Item -LiteralPath $newVhd).Length; Sha256 = $hash; Type = 'Dynamic'; Compression = $null; PackedBytes = $null }
    Config = [ordered]@{ File = (Split-Path -Leaf $configPath); Sha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash; Metadata = $cfg.metadata }
    Toolchains = @(foreach ($t in $targets) { [ordered]@{ Id = $t.Id; Key = $t.Key; Triplet = $t.Triplet } })
    Proxy  = [ordered]@{ Url = $proxyUrl; RemovedFromCopy = [bool]$RemoveProxy }
    LeftOut = @(foreach ($k in $excluded) { [ordered]@{ Category = $k; Bytes = $sizes[$k] } })
    Requires = [ordered]@{ Letter = $letter; Windows = 'Windows 10 or 11; a Dev Drive import needs Windows 11 22H2'; Admin = $true }
}

Info "Verifying: attaching the copy read-only..."
try
{
    $ro = Mount-DiskImage -ImagePath $newVhd -Access ReadOnly -NoDriveLetter -PassThru -ErrorAction Stop
    $rv = $ro | Get-Disk | Get-Partition | Get-Volume | Where-Object FileSystem | Select-Object -First 1
    $ok = $rv -and ($rv.FileSystem -eq 'NTFS') -and ($rv.FileSystemLabel -eq $label) -and [IO.Directory]::Exists("$($rv.Path)env\generator") -and [IO.Directory]::Exists("$($rv.Path)msys64")
    Dismount-DiskImage -ImagePath $newVhd -ErrorAction SilentlyContinue | Out-Null
    if (-not $ok) { Fail "The copy does not look right (file system, label or folders); the package is not valid." }
}
catch { Fail "Could not attach the copy read-only: $($_.Exception.Message)" }

if ($Compress)
{
    Info "Compressing the VHDX (zstd)..."
    $zstdPkg = Join-Path $pkg 'zstd'
    New-Item -ItemType Directory -Path $zstdPkg -Force | Out-Null
    Copy-Item -LiteralPath "$zstdDir\zstd.exe", "$zstdDir\libzstd.dll" -Destination $zstdPkg
    & (Join-Path $zstdPkg 'zstd.exe') -T0 -3 -q -o "$newVhd.zst" $newVhd
    if ($LASTEXITCODE) { Fail "zstd failed (exit $LASTEXITCODE); the uncompressed package is still valid in $pkg." }
    Remove-Item -LiteralPath $newVhd -Force
    $manifest.Vhdx.Compression = 'zstd'
    $manifest.Vhdx.PackedBytes = (Get-Item -LiteralPath "$newVhd.zst").Length
    Info ("Compressed: {0} -> {1}." -f (GB $manifest.Vhdx.Bytes), (GB $manifest.Vhdx.PackedBytes))
}
[IO.File]::WriteAllText((Join-Path $pkg 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

# The importer runs from the package itself: nothing needs to be installed on the other PC.
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Import-DevDrive.ps1') -Destination $pkg
[IO.File]::WriteAllText((Join-Path $pkg 'Import-DevDrive.cmd'), ("@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File ""%~dp0Import-DevDrive.ps1"" %*`r`n"))

Copy-Item -LiteralPath $logFile -Destination (Join-Path $pkg 'export.log') -Force
Log 'INFO' ("[OK] Package ready: {0} ({1}, SHA-256 {2}). The drive was not modified." -f $pkg, (GB $manifest.Vhdx.Bytes), $hash) 'Green'
if ($Archive)
{
    # Windows' tar (libarchive) writes a true Store zip with Zip64 only where needed; .NET's ZipFile on PowerShell 5.1
    # deflates even at NoCompression, and Compress-Archive stops at 2 GB.
    $zip = "$pkg.zip"
    Info "Packing the package into $zip (stored: the VHDX is already zstd'd)..."
    & $tar -a -c -f $zip --options zip:compression=store -C (Split-Path -Parent $pkg) (Split-Path -Leaf $pkg)
    if ($LASTEXITCODE) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue; Fail "tar failed (exit $LASTEXITCODE). The package folder is intact." }
    # Every file in, with its size, before the folder goes. Entry names use '/'.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try { $inZip = @{}; foreach ($e in $z.Entries) { $inZip[$e.FullName.Replace('/', '\')] = $e.Length } } finally { $z.Dispose() }
    $base = (Split-Path -Parent $pkg).TrimEnd('\').Length + 1
    $bad = @(Get-ChildItem -LiteralPath $pkg -Recurse -File | Where-Object { $inZip[$_.FullName.Substring($base)] -ne $_.Length })
    if ($bad.Count) { Remove-Item -LiteralPath $zip -Force; Fail "The archive did not match the package ($($bad.Count) files); it was removed and the folder kept." }
    Remove-Item -LiteralPath $pkg -Recurse -Force
    Log 'INFO' ("[OK] Archive ready: {0} ({1})." -f $zip, (GB (Get-Item -LiteralPath $zip).Length)) 'Green'
    Info "On the other PC: extract it (Extract All, or tar -xf <zip>) and double-click Import-DevDrive.cmd in the folder."
}
else { Info "On the other PC: copy the folder and double-click Import-DevDrive.cmd." }
Exit-Window 0
