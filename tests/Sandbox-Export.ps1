# ====================================================================
# SANDBOX TEST: EXPORT A THROWAWAY DRIVE (needs an elevated PowerShell)
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
#   powershell -ExecutionPolicy Bypass -File tests\Sandbox-Export.ps1
#
# Creates a 2 GB VHDX with a sample tree at a free letter, exports it with
# tools\Export-DevDrive.ps1 -Full -Force, checks the package, and checks
# that the source drive was not modified. Removes everything afterwards.
# ====================================================================

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check { param([string]$Name, [bool]$Ok) if ($Ok) { $script:pass++; Write-Host "  PASS  $Name" } else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red } }
function Diskpart { param([string[]]$Lines) $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllLines($f, $Lines); $o = & diskpart.exe /s $f 2>&1 | Out-String; Remove-Item $f; if ($LASTEXITCODE) { throw $o } }
# Folders by path, files by path, size and content hash. Not timestamps: NTFS updates a folder's time in its parent's
# index lazily, so one read right after creating files is stale (measured). Windows' own folders are left out.
function Snapshot { param([string]$Drive) @(Get-ChildItem -LiteralPath $Drive -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch 'System Volume Information|\$RECYCLE\.BIN' } |
    ForEach-Object { if ($_.PSIsContainer) { "{0}|d" -f $_.FullName } else { "{0}|{1}|{2}" -f $_.FullName, $_.Length, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } }) | Sort-Object }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host "Run this from an elevated PowerShell." -ForegroundColor Red; exit 1 }
$used   = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object Name)
$letter = @('Q', 'P', 'O', 'K', 'J') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
$box    = Join-Path $env:TEMP ("drivenv-sandbox-export-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$label  = 'SANDBOX_EXPORT'
$srcVhd = Join-Path $box "src\$label.vhdx"
New-Item -ItemType Directory -Path (Join-Path $box 'src'), (Join-Path $box 'out') -Force | Out-Null
try
{
    Write-Host "Source drive ${letter}: in $box"
    Diskpart @("create vdisk file=""$srcVhd"" maximum=2048 type=expandable", "select vdisk file=""$srcVhd""", "attach vdisk", "convert gpt",
               "create partition primary", "format quick fs=ntfs label=""$label""", "assign letter=$letter")
    $d = "${letter}:\"
    $tr = 'x64-mingw-ucrt-dynamic-release'
    $files = @{ 'msys64\usr\bin\bash.exe' = 1KB; 'vcpkg\installed\x\lib\libz.a' = 1MB; 'vcpkg\downloads\zlib.tar.gz' = 1MB; "bt\zlib\$tr.vcpkg_abi_info.txt" = 1KB
                "bt\zlib\$tr-rel\obj.o" = 1MB; "bt\$tr\MyProj\CMakeCache.txt" = 1KB; 'bt\detect_compiler\x.txt' = 1KB; 'env\x.env' = 1KB; 'logs\setup\a.log' = 1KB
                'logs\vcpkg\zlib\f.log' = 1KB; 'packages\vcpkg\aa\h.zip' = 1MB; 'tmp\t.txt' = 1KB; 'workspace\repo\file.c' = 1KB }
    foreach ($f in $files.Keys) { $p = Join-Path $d $f; New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null; [IO.File]::WriteAllBytes($p, (New-Object byte[] $files[$f])) }
    New-Item -ItemType Directory -Path "${d}vcpkg\packages\zlib_$tr\lib" -Force | Out-Null
    New-Item -ItemType HardLink -Path "${d}vcpkg\packages\zlib_$tr\lib\libz.a" -Target "${d}vcpkg\installed\x\lib\libz.a" | Out-Null

    $cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'config\drivenv-cfg_example.json') | ConvertFrom-Json
    $cfg.environment.dev_drive_letter = $letter; $cfg.environment.dev_drive_label = $label; $cfg.environment.vhd_root = (Join-Path $box 'src')
    $cfgPath = Join-Path $box 'sandbox-cfg.json'
    [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding($false)))

    $before = Snapshot $d
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\Export-DevDrive.ps1') -ConfigFile $cfgPath -Destination (Join-Path $box 'out') -Full -Force
    Check "export exits 0" ($LASTEXITCODE -eq 0)
    $diff = @(Compare-Object -ReferenceObject $before -DifferenceObject @(Snapshot $d))
    Check "the source drive was not modified" ($diff.Count -eq 0)
    foreach ($x in $diff) { Write-Host ("        {0} {1}" -f $(if ($x.SideIndicator -eq '=>') { 'after: ' } else { 'before:' }), $x.InputObject) -ForegroundColor Yellow }

    $pkg = Get-ChildItem (Join-Path $box 'out') -Directory | Select-Object -First 1
    $manifest = Get-Content -Raw -Encoding UTF8 (Join-Path $pkg.FullName 'manifest.json') | ConvertFrom-Json
    $copy = Join-Path $pkg.FullName "$label.vhdx"
    Check "manifest hash matches the VHDX" ($manifest.Vhdx.Sha256 -ceq (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash)
    Check "the copy is small (dynamic, only what was copied)" ((Get-Item $copy).Length -lt 200MB)

    $img = Mount-DiskImage -ImagePath $copy -Access ReadOnly -NoDriveLetter -PassThru
    try
    {
        $v = ($img | Get-Disk | Get-Partition | Get-Volume | Where-Object FileSystem | Select-Object -First 1).Path
        $has = { param($rel) [IO.File]::Exists($v + $rel) -or [IO.Directory]::Exists($v + $rel) }
        Check "copied: environment, records, workspace" ((& $has 'msys64\usr\bin\bash.exe') -and (& $has 'vcpkg\installed\x\lib\libz.a') -and (& $has 'env\x.env') -and (& $has 'logs\setup\a.log') -and (& $has 'workspace\repo\file.c'))
        Check "left out: vcpkg packages, port build trees, detect_compiler, tmp" (-not (& $has 'vcpkg\packages') -and -not (& $has 'bt\zlib') -and -not (& $has 'bt\detect_compiler') -and -not (& $has 'tmp'))
        Check "left out with -Full: downloads, user builds, failure logs, binary cache" (-not (& $has 'vcpkg\downloads') -and -not (& $has "bt\$tr") -and -not (& $has 'logs\vcpkg') -and -not (& $has 'packages\vcpkg'))
        Check "the generator and its configuration travel inside" ((& $has 'env\generator\Generate-DrivEnv.ps1') -and (& $has 'env\generator\config\sandbox-cfg.json') -and -not (& $has 'env\generator\logs'))
    }
    finally { Dismount-DiskImage -ImagePath $copy | Out-Null }
}
finally
{
    try { Diskpart @("select vdisk file=""$srcVhd""", "detach vdisk") } catch { }
    Remove-Item -LiteralPath $box -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "================ $pass passed, $fail failed ================"
if ($fail) { exit 1 }
