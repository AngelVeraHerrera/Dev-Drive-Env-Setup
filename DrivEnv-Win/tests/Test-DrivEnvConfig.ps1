# ====================================================================
# CONFIGURATION VALIDATOR AND TOOLCHAIN RESOLUTION TESTS
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
# Updated: 17/09/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Run it:  powershell -ExecutionPolicy Bypass -File tests\Test-DrivEnvConfig.ps1
# Exits 0 when every case passes, 1 otherwise, so it works as a gate.
#
# WHY THESE CASES AND NOT OTHERS
#
# The validator is the one file every step depends on, and its whole
# purpose is to refuse a configuration that would make a step quietly do
# less than it was asked to. A bug here is therefore invisible twice: the
# validator says nothing, and the step then says "success".
#
# Sections 9 to 11 exist because of specific defects that reached the
# repository and were caught in review, not because somebody enumerated
# the API. Each one is a case a reasonable person would not have thought
# to write:
#
#   * PowerShell UNROLLS a collection on the way out of a function, so
#     `return @(...)` hands back the ELEMENT when the result holds one and
#     $null when it holds none. Every array in a real configuration has
#     two or more entries, so the first version of these tests passed
#     while the merge was silently returning scalars for small lists.
#     Section 9 tests 0 and 1 elements ONLY, because those are the sizes
#     that break.
#
#   * @($null).Count is 1, not 0. A guard written as
#     `if (@($x).Count -eq 0)` therefore cannot tell "absent" from "empty"
#     and reports a missing key as present-and-fine. Section 10 covers it.
#
#   * Arrays APPEND when a profile is layered onto the shared
#     configuration, so re-stating a package does not override it -- it
#     adds a second pin of the same package. Section 11 covers it, and
#     also covers the case that must NOT fire: the shipped configurations
#     carry 'make' twice on purpose, once from mingw and once from msys.
#
# Section 1 is the one that matters most day to day: every configuration
# the repository ships must keep validating clean, or the change under
# test broke somebody's working drive.

$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $root 'scripts\DrivEnvConfig.ps1'
$cfgDir    = Join-Path $root 'config'
$fixtures  = Join-Path $PSScriptRoot 'fixtures'

if (-not (Test-Path -LiteralPath $validator)) { Write-Host "Cannot find $validator"; exit 1 }
. $validator

$script:pass = 0
$script:fail = 0

function Check
{
    param([string]$Name, [bool]$Ok, [string]$Detail = "")
    if ($Ok) { $script:pass++; Write-Host "  PASS  $Name" }
    else     { $script:fail++; Write-Host "  FAIL  $Name   $Detail" }
}

function Load       { param([string]$Path) return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) }
function Clone      { param($o) return ($o | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json) }
function HasProblem { param($cfg, [string]$needle) return @(Test-DrivEnvConfig -Config $cfg | Where-Object { $_ -like "*$needle*" }).Count -gt 0 }

# The comma matters here too: without it an empty JSON array comes back from this helper as $null and a
# one-element one as the element, which would test the harness rather than the code.
function ArrayOf    { param([string]$Json) return ,(($Json | ConvertFrom-Json).a) }

Write-Host "=== 1. NO REGRESSION: every shipped configuration still validates ==="
foreach ($f in (Get-ChildItem -LiteralPath $cfgDir -Filter '*.json' -File | Sort-Object Name))
{
    $probs = Test-DrivEnvConfig -Config (Load $f.FullName)
    Check "$($f.Name)" ($probs.Count -eq 0) ("-> " + ($probs -join ' | '))
}

Write-Host "=== 2. THE DUAL FIXTURE VALIDATES ==="
$dual  = Load (Join-Path $fixtures 'dual-toolchains.json')
$probs = Test-DrivEnvConfig -Config $dual
Check "dual-toolchains.json" ($probs.Count -eq 0) ("-> " + ($probs -join ' | '))

Write-Host "=== 3. RESOLUTION: each toolchain projects to a 2.x-shaped configuration ==="
foreach ($id in @('clang', 'ucrt'))
{
    $r = Resolve-DrivEnvToolchain -Cfg $dual -Id $id
    Check "$id  plural keys removed" ((@($r.PSObject.Properties.Name) -notcontains 'toolchains') -and (@($r.PSObject.Properties.Name) -notcontains 'generate'))
    Check "$id  subsystem present"   (-not [string]::IsNullOrWhiteSpace($r.msys2.target.subsystem)) "= '$($r.msys2.target.subsystem)'"
    Check "$id  triplet present"     (-not [string]::IsNullOrWhiteSpace($r.vcpkg.target.triplet))   "= '$($r.vcpkg.target.triplet)'"
    Check "$id  resolved validates"  ((Test-DrivEnvConfig -Config $r).Count -eq 0) ("-> " + ((Test-DrivEnvConfig -Config $r) -join ' | '))
}

Write-Host "=== 4. MERGE: arrays append, everything else replaces ==="
$shared = $dual.msys2.packages.Count
$rc = Resolve-DrivEnvToolchain -Cfg $dual -Id 'clang'
$ru = Resolve-DrivEnvToolchain -Cfg $dual -Id 'ucrt'
Check "clang packages = shared + profile" ($rc.msys2.packages.Count -eq ($shared + $dual.toolchains.clang.msys2.packages.Count)) "= $($rc.msys2.packages.Count) (shared $shared)"
Check "ucrt  packages = shared + profile" ($ru.msys2.packages.Count -eq ($shared + $dual.toolchains.ucrt.msys2.packages.Count))  "= $($ru.msys2.packages.Count)"
Check "check_tools append"                ($rc.environment.verification.check_tools.Count -eq ($dual.environment.verification.check_tools.Count + 3)) "= $($rc.environment.verification.check_tools.Count)"
Check "triplet replaces, does not append" ($rc.vcpkg.target.triplet -is [string])
Check "the two triplets differ"           ($rc.vcpkg.target.triplet -ne $ru.vcpkg.target.triplet)

Write-Host "=== 5. ISOLATION: resolving one must not touch the original or the other ==="
$rc2 = Resolve-DrivEnvToolchain -Cfg $dual -Id 'clang'
Check "original keeps its shared packages" ($dual.msys2.packages.Count -eq $shared) "= $($dual.msys2.packages.Count)"
Check "original keeps 'toolchains'"        (@($dual.PSObject.Properties.Name) -contains 'toolchains')
Check "resolving twice is stable"          ($rc2.msys2.packages.Count -eq $rc.msys2.packages.Count)
$rc2.msys2.target.subsystem = 'MUTATED'
Check "mutating a resolved copy leaves the original alone" ($dual.toolchains.clang.msys2.target.subsystem -eq 'clang64') "= $($dual.toolchains.clang.msys2.target.subsystem)"
Check "mutating a resolved copy leaves the other copy alone" ($rc.msys2.target.subsystem -eq 'clang64') "= $($rc.msys2.target.subsystem)"

Write-Host "=== 6. NEGATIVE CASES: each mistake must produce ITS OWN message ==="
$c = Clone $dual; $c.PSObject.Properties.Remove('generate')
Check "toolchains without generate" (HasProblem $c "generate: required when 'toolchains' is present")

$c = Clone $dual; $c.PSObject.Properties.Remove('toolchains')
Check "generate without toolchains" (HasProblem $c "toolchains: required when 'generate' is present")

$c = Clone $dual; $c.generate = @('clang', 'clan')
Check "unknown id, with a suggestion" (HasProblem $c "is not a declared toolchain. Did you mean 'clang'")

$c = Clone $dual; $c.generate = @()
Check "empty generate" (HasProblem $c 'must name at least one toolchain')

$c = Clone $dual; $c.toolchains.ucrt.vcpkg.target.triplet = $dual.toolchains.clang.vcpkg.target.triplet
Check "two toolchains, one triplet" (HasProblem $c 'collides with toolchain')

$c = Clone $dual; $c.toolchains.ucrt.msys2.target.subsystem = 'clang64'
Check "two toolchains, one subsystem" (HasProblem $c 'resolves to the same MSYS2 prefix')

$c = Clone $dual; $c.toolchains.clang.vcpkg.target.PSObject.Properties.Remove('triplet')
Check "profile with no triplet" (HasProblem $c 'vcpkg.target.triplet: required')

$c = Clone $dual; $c.toolchains.clang.msys2.target.PSObject.Properties.Remove('subsystem')
Check "profile with neither subsystem nor profile" (HasProblem $c "one of 'subsystem' or the legacy 'profile' is required")

$c = Clone $dual; Add-Member -InputObject $c.toolchains.clang -MemberType NoteProperty -Name 'dev_drive_letter' -Value 'Z'
Check "a profile may not move the drive" (HasProblem $c 'unknown key')

$c = Clone $dual; Add-Member -InputObject $c.toolchains -MemberType NoteProperty -Name 'bad id' -Value $c.toolchains.clang
Check "id with a space" (HasProblem $c 'it names files and folders')

$c = Clone $dual; $c.toolchains.clang.msys2.packages[0].PSObject.Properties.Remove('version')
Check "pinned with no version inside a profile" (HasProblem $c "toolchains.clang.msys2.packages*.version: required when mode is 'pinned'")

Write-Host "=== 7. A 2.x CONFIGURATION: the old requirements are still enforced ==="
$base = Join-Path $cfgDir 'drivenv-cfg_example.json'

$c = Load $base; $c.vcpkg.target.PSObject.Properties.Remove('triplet')
Check "2.x with no triplet still fails" (HasProblem $c 'vcpkg.target.triplet: required')

$c = Load $base; $c.msys2.PSObject.Properties.Remove('target')
Check "2.x with no msys2.target still fails" (HasProblem $c 'msys2.target: required')

$c = Load $base; $c.msys2.packages = @()
Check "2.x with an empty package list still fails" (HasProblem $c 'msys2.packages: required and must not be empty')

Write-Host "=== 8. Get-DrivEnvGenerateList ==="
Check "dual fixture lists both, in order" (((Get-DrivEnvGenerateList -Cfg $dual) -join ',') -eq 'clang,ucrt')
Check "a 2.x configuration lists none"    ((Get-DrivEnvGenerateList -Cfg (Load $base)).Count -eq 0)

Write-Host "=== 9. ARRAY EDGES: 0 and 1 element, which is what PowerShell unrolling breaks ==="
$m00 = Merge-DrivEnvValue -Base (ArrayOf '{"a":[]}')  -Override (ArrayOf '{"a":[]}')
$m01 = Merge-DrivEnvValue -Base (ArrayOf '{"a":[]}')  -Override (ArrayOf '{"a":[1]}')
$m10 = Merge-DrivEnvValue -Base (ArrayOf '{"a":[1]}') -Override (ArrayOf '{"a":[]}')
$m11 = Merge-DrivEnvValue -Base (ArrayOf '{"a":[1]}') -Override (ArrayOf '{"a":[2]}')
Check "[] + []  stays an array" ($m00 -is [System.Array]) ("-> " + $(if ($null -eq $m00) { 'NULL' } else { $m00.GetType().Name }))
Check "[] + [1] stays an array" ($m01 -is [System.Array]) ("-> " + $(if ($null -eq $m01) { 'NULL' } else { $m01.GetType().Name }))
Check "[1] + [] stays an array" ($m10 -is [System.Array]) ("-> " + $(if ($null -eq $m10) { 'NULL' } else { $m10.GetType().Name }))
Check "[1] + [2] holds two"     (($m11 -is [System.Array]) -and ($m11.Count -eq 2))

$g1 = Get-DrivEnvGenerateList -Cfg ('{"generate":["clang"]}' | ConvertFrom-Json)
Check "generate with ONE id returns an array" ($g1 -is [System.Array]) ("-> " + $g1.GetType().Name)
Check "generate with one id keeps the whole id" (($g1.Count -eq 1) -and ($g1[0] -eq 'clang'))
$g0 = Get-DrivEnvGenerateList -Cfg ('{}' | ConvertFrom-Json)
Check "generate absent returns an empty array" (($g0 -is [System.Array]) -and ($g0.Count -eq 0))

Write-Host "=== 10. ABSENT IS NOT EMPTY, AND AN EMPTY MAP HAS NO KEYS ==="
$c = Clone $dual; $c.msys2.PSObject.Properties.Remove('packages')
foreach ($id in @('clang', 'ucrt')) { $c.toolchains.$id.msys2.PSObject.Properties.Remove('packages') }
Check "no packages anywhere is caught" (HasProblem $c 'msys2.packages: required and must not be empty')

$c = Load $base; $c.msys2.PSObject.Properties.Remove('packages')
Check "2.x with the packages key ABSENT is caught" (HasProblem $c 'msys2.packages: required and must not be empty')

$c = Clone $dual; $c.toolchains = ('{}' | ConvertFrom-Json)
Check "empty toolchains: no phantom id"          (-not (HasProblem $c 'it names files and folders'))
Check "empty toolchains: the unknown id is said" (HasProblem $c 'is not a declared toolchain')

$c = Clone $dual
$c.toolchains.ucrt.msys2.target.PSObject.Properties.Remove('subsystem')
Add-Member -InputObject $c.toolchains.ucrt.msys2.target -MemberType NoteProperty -Name 'profile' -Value 'clang'
Check "legacy profile 'clang' collides with subsystem 'clang64'" (HasProblem $c 'resolves to the same MSYS2 prefix')

$c = Clone $dual; $c.generate = @('clang', 'clang')
$dup = @(Test-DrivEnvConfig -Config $c)
Check "a duplicated id is said once"          (@($dup | Where-Object { $_ -like '*named more than once*' }).Count -eq 1)
Check "a duplicated id does not self-collide" (@($dup | Where-Object { $_ -like '*collides*' -or $_ -like '*same MSYS2 prefix*' }).Count -eq 0) ("-> " + ($dup -join ' | '))

$c = Clone $dual; $c.toolchains.clang.vcpkg.target.PSObject.Properties.Remove('triplet')
$tri = @(Test-DrivEnvConfig -Config $c | Where-Object { $_ -like '*triplet*' })
Check "a missing triplet is said once, not twice" ($tri.Count -eq 1) ("-> " + ($tri -join ' | '))

$c = Clone $dual; $c.toolchains.clang.vcpkg.PSObject.Properties.Remove('target'); $c.vcpkg.PSObject.Properties.Remove('target')
Check "a wholly absent vcpkg.target is caught" (HasProblem $c 'vcpkg.target: required')

Write-Host "=== 11. A PROFILE ADDS TO THE SHARED LIST, IT DOES NOT REPLACE AN ENTRY ==="
$c = Clone $dual
$c.toolchains.clang.msys2.packages = @($c.toolchains.clang.msys2.packages) + @('{"name":"cmake","mode":"pinned","version":"9.9.9-1"}' | ConvertFrom-Json)
Check "re-pinning a shared package is caught" (HasProblem $c "'cmake' from repo 'mingw' appears twice")
Check "only the offending toolchain is named" (@(Test-DrivEnvConfig -Config $c | Where-Object { $_ -like '*appears twice*' }).Count -eq 1)
Check "the deliberate mingw+msys 'make' pair does NOT fire" ((Test-DrivEnvConfig -Config $dual).Count -eq 0) ("-> " + ((Test-DrivEnvConfig -Config $dual) -join ' | '))

Write-Host "=== 12. THE @() TRAP, IN BOTH DIRECTIONS ==="
# Get-DrivEnvGenerateList comma-wraps its return so it always yields an array. That guarantee is exactly what
# makes the repository's usual defensive @(...) wrap WRONG here: @() collects the one emitted object -- which is
# the array -- into a new array. It reached the runner as a Toolchain column reading "System.Object[]" and one
# launch carrying -Toolchain "clang ucrt". Both halves are asserted so neither can be "fixed" back.
$bare    = Get-DrivEnvGenerateList -Cfg $dual
$wrapped = @(Get-DrivEnvGenerateList -Cfg $dual)
Check "unwrapped gives the ids"            (($bare.Count -eq 2) -and ($bare[0] -eq 'clang'))
Check "wrapping in @() NESTS, so do not"   (($wrapped.Count -eq 1) -and ($wrapped[0] -is [System.Array]))

Check "relative config resolves under config/" ((Resolve-DrivEnvConfigPath -ConfigFile 'x.json' -GeneratorRoot 'V:\gen') -eq 'V:\gen\config\x.json')
Check "absolute config is taken as given"      ((Resolve-DrivEnvConfigPath -ConfigFile 'D:\a\b.json' -GeneratorRoot 'V:\gen') -eq 'D:\a\b.json')

Write-Host "=== 13. THE RUNNER'S PLAN (via -DryRun, which launches nothing) ==="
$runner  = Join-Path $root 'Generate-DrivEnv.ps1'
$dualCfg = Join-Path $fixtures 'dual-toolchains.json'

function PlanOrder
{
    # The "Order" line of a dry run, e.g. "1 2:clang 3:clang ... 6".
    param([string[]]$Arguments)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $runner @Arguments -DryRun 2>&1
    $line = $out | Where-Object { $_ -match '^\s*Order\s*:' } | Select-Object -First 1
    if (-not $line) { return "" }
    return ($line -replace '^\s*Order\s*:\s*', '').Trim()
}

Check "dual: toolchain-major, drive steps once" `
    ((PlanOrder @('-ConfigFile', $dualCfg)) -eq '1 2:clang 3:clang 4:clang 5:clang 2:ucrt 3:ucrt 4:ucrt 5:ucrt 6')

Check "dual, -Toolchain ucrt -From 4" `
    ((PlanOrder @('-ConfigFile', $dualCfg, '-From', '4', '-Toolchain', 'ucrt')) -eq '4:ucrt 5:ucrt 6')

Check "dual, -Skip 3 leaves a hole in each toolchain" `
    ((PlanOrder @('-ConfigFile', $dualCfg, '-Skip', '3')) -eq '1 2:clang 4:clang 5:clang 2:ucrt 4:ucrt 5:ucrt 6')

# A 2.x configuration prints no Order line at all, because there is nothing to order: the plan is the step list.
Check "2.x: no toolchain ordering is printed" ((PlanOrder @('-ConfigFile', 'drivenv-cfg_example.json')) -eq "")

Write-Host "=== 14. A STEP'S OWN -Toolchain HANDLING (step 5, -ValidateOnly, nothing is touched) ==="
function StepCode
{
    param([string[]]$Arguments)
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\5-Verify_Env.ps1') @Arguments -ValidateOnly 2>&1
    return $LASTEXITCODE
}

Check "dual without -Toolchain is refused"      ((StepCode @('-ConfigFile', $dualCfg)) -eq 1)
Check "dual with a real id is accepted"         ((StepCode @('-ConfigFile', $dualCfg, '-Toolchain', 'ucrt')) -eq 0)
Check "dual with an unknown id is refused"      ((StepCode @('-ConfigFile', $dualCfg, '-Toolchain', 'msvc')) -eq 1)
Check "2.x without -Toolchain still works"      ((StepCode @('-ConfigFile', 'drivenv-cfg_example.json')) -eq 0)
Check "2.x with -Toolchain is refused"          ((StepCode @('-ConfigFile', 'drivenv-cfg_example.json', '-Toolchain', 'ucrt')) -eq 1)

Write-Host ""
Write-Host "================ $script:pass passed, $script:fail failed ================"
if ($script:fail -gt 0) { exit 1 }
exit 0
