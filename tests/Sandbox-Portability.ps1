# ====================================================================
# SANDBOX TEST: EXPORT AND IMPORT A THROWAWAY DRIVE (elevated PowerShell)
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
# Updated: 22/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
#   powershell -ExecutionPolicy Bypass -File tests\Sandbox-Portability.ps1
#
# Creates a 2 GB VHDX with a sample tree at a free letter, exports it with
# tools\Export-DevDrive.ps1 -Full -Archive -RemoveProxy -Force (a .zip with
# a zstd'd VHDX) and checks the source was not modified. Extracts the .zip
# and imports it (Image mode, the one this PC can run): first while the
# source still holds the letter (refused, nothing written), then once it
# is free. Removes everything afterwards, mount task and Defender
# exclusion included.
# -ZstdDir: where zstd.exe and libzstd.dll are taken from for the sample.
# ====================================================================

param ([string]$ZstdDir = 'D:\msys64\ucrt64\bin')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pass = 0; $fail = 0
function Check { param([string]$Name, [bool]$Ok) if ($Ok) { $script:pass++; Write-Host "  PASS  $Name" } else { $script:fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red } }
function Diskpart { param([string[]]$Lines) $f = [IO.Path]::GetTempFileName(); [IO.File]::WriteAllLines($f, $Lines); $o = & diskpart.exe /s $f 2>&1 | Out-String; Remove-Item $f; if ($LASTEXITCODE) { throw $o } }
# Folders by path, files by path, size and content hash. Not timestamps: NTFS updates a folder's time in its parent's
# index lazily, so one read right after creating files is stale (measured). Windows' own folders are left out.
function Snapshot { param([string]$Drive) @(Get-ChildItem -LiteralPath $Drive -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch 'System Volume Information|\$RECYCLE\.BIN' } |
    ForEach-Object { if ($_.PSIsContainer) { "{0}|d" -f $_.FullName } else { "{0}|{1}|{2}" -f $_.FullName, $_.Length, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } }) | Sort-Object }
function Invoke-Import {
    # Stdin piped: nothing the import starts (step 5 included) can wait for a key. The output is kept, to check WHY it
    # stopped: an exit code alone passed a refusal that was really a crash.
    $out = '' | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:pkg 'Import-DevDrive.ps1') -Destination $script:in -Mode Image -Force 2>&1 | Out-String
    $code = $LASTEXITCODE
    Write-Host $out
    return [pscustomobject]@{ Code = $code; Out = $out }
}
# Never Get-Content -Raw on the imported drive: -Raw is a FileSystem dynamic parameter, gone when the letter is not there.
function Read-Text { param([string]$Path) if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' } }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host "Run this from an elevated PowerShell." -ForegroundColor Red; exit 1 }
if (-not ((Test-Path "$ZstdDir\zstd.exe") -and (Test-Path "$ZstdDir\libzstd.dll"))) { Write-Host "No zstd.exe + libzstd.dll in $ZstdDir; pass -ZstdDir." -ForegroundColor Red; exit 1 }
$used   = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object Name)
$letter = @('Q', 'P', 'O', 'K', 'J') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
$box    = Join-Path $env:TEMP ("drivenv-sandbox-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$label  = 'SANDBOX_PORT'
$srcVhd = Join-Path $box "src\$label.vhdx"
$in     = Join-Path $box 'in'
$inVhd  = Join-Path $in "$label.vhdx"
$task   = "DrivEnv_{0}_{1}" -f $label, $letter
$proxy  = 'http://proxy.example:8080'
New-Item -ItemType Directory -Path (Join-Path $box 'src'), (Join-Path $box 'out'), (Join-Path $box 'unz') -Force | Out-Null
$srcAttached = $false
try
{
    Write-Host "Source drive ${letter}: in $box"
    Diskpart @("create vdisk file=""$srcVhd"" maximum=2048 type=expandable", "select vdisk file=""$srcVhd""", "attach vdisk", "convert gpt",
               "create partition primary", "format quick fs=ntfs label=""$label""", "assign letter=$letter")
    $srcAttached = $true
    $d = "${letter}:\"
    $tr = 'x64-mingw-ucrt-dynamic-release'
    $files = @{ 'msys64\usr\bin\bash.exe' = 1KB; 'vcpkg\installed\x\lib\libz.a' = 1MB; 'vcpkg\downloads\zlib.tar.gz' = 1MB; "bt\zlib\$tr.vcpkg_abi_info.txt" = 1KB
                "bt\zlib\$tr-rel\obj.o" = 1MB; "bt\$tr\MyProj\CMakeCache.txt" = 1KB; 'bt\detect_compiler\x.txt' = 1KB; 'env\x.env' = 1KB; 'logs\setup\a.log' = 1KB
                'logs\vcpkg\zlib\f.log' = 1KB; 'packages\vcpkg\aa\h.zip' = 1MB; 'tmp\t.txt' = 1KB; 'workspace\repo\file.c' = 1KB }
    foreach ($f in $files.Keys) { $p = Join-Path $d $f; New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null; [IO.File]::WriteAllBytes($p, (New-Object byte[] $files[$f])) }
    New-Item -ItemType Directory -Path "${d}vcpkg\packages\zlib_$tr\lib", "${d}msys64\ucrt64\bin", "${d}msys64\etc\profile.d", "${d}msys64\etc\pacman.d\gnupg" -Force | Out-Null
    New-Item -ItemType HardLink -Path "${d}vcpkg\packages\zlib_$tr\lib\libz.a" -Target "${d}vcpkg\installed\x\lib\libz.a" | Out-Null
    Copy-Item "$ZstdDir\zstd.exe", "$ZstdDir\libzstd.dll" -Destination "${d}msys64\ucrt64\bin"
    # The proxy as step 2 writes it, so -RemoveProxy has something to remove.
    [IO.File]::WriteAllText("${d}msys64\etc\profile.d\devsystem-proxy.sh", "export http_proxy=""$proxy""`n")
    [IO.File]::WriteAllText("${d}msys64\etc\pacman.d\gnupg\dirmngr.conf", "http-proxy $proxy`n")
    [IO.File]::WriteAllText("${d}msys64\etc\gitconfig", "[http]`n`tproxy = $proxy`n[user]`n`tname = Sandbox`n")

    $cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $root 'config\drivenv-cfg_example.json') | ConvertFrom-Json
    $cfg.environment.dev_drive_letter = $letter; $cfg.environment.dev_drive_label = $label; $cfg.environment.vhd_root = (Join-Path $box 'src')
    $cfg.environment.proxy_url = $proxy
    $cfgPath = Join-Path $box 'sandbox-cfg.json'
    [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 50), (New-Object System.Text.UTF8Encoding($false)))

    # -- export ------------------------------------------------------------------------------------
    $before = Snapshot $d
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\Export-DevDrive.ps1') -ConfigFile $cfgPath -Destination (Join-Path $box 'out') -Full -Archive -RemoveProxy -Force
    Check "export exits 0" ($LASTEXITCODE -eq 0)
    $diff = @(Compare-Object -ReferenceObject $before -DifferenceObject @(Snapshot $d))
    Check "the source drive was not modified" ($diff.Count -eq 0)
    foreach ($x in $diff) { Write-Host ("        {0} {1}" -f $(if ($x.SideIndicator -eq '=>') { 'after: ' } else { 'before:' }), $x.InputObject) -ForegroundColor Yellow }

    $zip = @(Get-ChildItem (Join-Path $box 'out') -Filter '*.zip')
    Check "-Archive: one .zip, no folder left" (($zip.Count -eq 1) -and (@(Get-ChildItem (Join-Path $box 'out') -Directory).Count -eq 0))
    & (Join-Path $env:SystemRoot 'System32\tar.exe') -x -f $zip[0].FullName -C (Join-Path $box 'unz')
    $script:pkg = (Get-ChildItem (Join-Path $box 'unz') -Directory | Select-Object -First 1).FullName
    $has = { param($rel) Test-Path -LiteralPath (Join-Path $pkg $rel) }
    Check "the .zip holds a zstd'd VHDX, zstd and the importer" ((& $has "$label.vhdx.zst") -and -not (& $has "$label.vhdx") -and (& $has 'zstd\zstd.exe') -and (& $has 'zstd\libzstd.dll') -and
                                                              (& $has 'Import-DevDrive.cmd') -and (& $has 'Import-DevDrive.ps1') -and (& $has 'manifest.json'))
    Check "the package is small (dynamic, compressed)" ($zip[0].Length -lt 50MB)

    # -- import ------------------------------------------------------------------------------------
    $r = Invoke-Import
    Check "import refuses a letter in use, saying what holds it, writing nothing" (($r.Code -eq 1) -and ($r.Out -match 'is held by') -and -not (Test-Path -LiteralPath $inVhd))
    Diskpart @("select vdisk file=""$srcVhd""", "detach vdisk"); $srcAttached = $false
    Check "import exits 0, or 2 (step 5 cannot validate a sample drive)" (@(0, 2) -contains (Invoke-Import).Code)
    # Every check below needs the drive there: an absent drive would pass the 'left out' ones for nothing.
    $here = (Get-DiskImage -ImagePath $inVhd -ErrorAction SilentlyContinue).Attached -and (Test-Path "${d}env\generator")
    Check "imported at ${letter}: from $inVhd" ($here -and (Test-Path "${d}workspace\repo\file.c"))
    Check "copied: environment, records, workspace" ($here -and (Test-Path "${d}msys64\usr\bin\bash.exe") -and (Test-Path "${d}vcpkg\installed\x\lib\libz.a") -and (Test-Path "${d}env\x.env") -and (Test-Path "${d}logs\setup\a.log"))
    Check "left out: vcpkg packages, port build trees, detect_compiler, tmp" ($here -and -not (Test-Path "${d}vcpkg\packages") -and -not (Test-Path "${d}bt\zlib") -and -not (Test-Path "${d}bt\detect_compiler") -and -not (Test-Path "${d}tmp"))
    Check "left out with -Full: downloads, user builds, failure logs, binary cache" ($here -and -not (Test-Path "${d}vcpkg\downloads") -and -not (Test-Path "${d}bt\$tr") -and -not (Test-Path "${d}logs\vcpkg") -and -not (Test-Path "${d}packages\vcpkg"))
    $json = Read-Text "${d}env\generator\config\sandbox-cfg.json"
    $emb = if ($json) { $json | ConvertFrom-Json } else { $null }
    Check "the generator travels; its config now points at this PC's VHDX" ($here -and (Test-Path "${d}env\generator\Generate-DrivEnv.ps1") -and ($emb.environment.vhd_root -eq $in.Replace('\', '/')))
    $gitcfg = Read-Text "${d}msys64\etc\gitconfig"
    Check "-RemoveProxy: no proxy in the copy (profile.d, dirmngr, gitconfig, config); the git identity stays" ($here -and -not (Test-Path "${d}msys64\etc\profile.d\devsystem-proxy.sh") -and
        -not (Test-Path "${d}msys64\etc\pacman.d\gnupg\dirmngr.conf") -and ($gitcfg -notmatch 'proxy') -and ($gitcfg -match 'name = Sandbox') -and $emb -and ([string]$emb.environment.proxy_url -eq ''))
    $t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Check "mount task registered for the imported VHDX" ($t -and ([string]$t.Actions[0].Arguments -match [regex]::Escape("Mount-DiskImage -ImagePath '$inVhd'")))
    Check "import record on the drive" (@(Get-ChildItem "${d}installation\import_*.log" -ErrorAction SilentlyContinue).Count -eq 1)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Check "the drive is handed to environment.owner ('current': $me), not left to Administrators" ($here -and
        ((Get-Acl -LiteralPath "${d}workspace\repo\file.c").Owner -eq $me) -and ((Get-Acl -LiteralPath "${d}msys64\usr\bin\bash.exe").Owner -eq $me))
}
finally
{
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    try { Remove-MpPreference -ExclusionPath "${letter}:\" -ErrorAction Stop } catch { }
    Dismount-DiskImage -ImagePath $inVhd -ErrorAction SilentlyContinue | Out-Null
    if ($srcAttached) { try { Diskpart @("select vdisk file=""$srcVhd""", "detach vdisk") } catch { } }
    Remove-Item -LiteralPath $box -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "================ $pass passed, $fail failed ================"
if ($fail) { exit 1 }
