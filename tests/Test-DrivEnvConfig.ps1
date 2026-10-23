# ====================================================================
# CONFIGURATION VALIDATOR AND TOOLCHAIN RESOLUTION TESTS
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Run it:  powershell -ExecutionPolicy Bypass -File tests\Test-DrivEnvConfig.ps1
# Exits 0 when every case passes, 1 otherwise. DRIVENV_TEST_SDKTOOL and
# DRIVENV_TEST_BASH enable the real sdktool and bash cases.
#
# Many cases come from defects found in review: PowerShell unrolling a
# returned array (lists are tried at sizes 0, 1 and 2, comma-returning
# functions in both @() directions), @($null).Count being 1, arrays
# appending when a profile is layered. Section 1 keeps every shipped
# configuration validating clean; tests/fixtures/single-toolchain.json is a
# frozen configuration without 'toolchains'. Names are compared exactly.

$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent $PSScriptRoot
$validator = Join-Path $root 'scripts\DrivEnvConfig.ps1'
$cfgDir    = Join-Path $root 'config'
$fixtures  = Join-Path $PSScriptRoot 'fixtures'

if (-not (Test-Path -LiteralPath $validator)) { Write-Host "Cannot find $validator"; exit 1 }
. $validator

$script:pass = 0
$script:skip = 0
$script:fail = 0

function Check
{
    param([string]$Name, [bool]$Ok, [string]$Detail = "")
    if ($Ok) { $script:pass++; Write-Host "  PASS  $Name" }
    else     { $script:fail++; Write-Host "  FAIL  $Name   $Detail" }
}

function Load       { param([string]$Path) return (Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json) }
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
Check "id with a space" (HasProblem $c 'it travels on the command line as -Toolchain')

$c = Clone $dual; $c.toolchains.clang.msys2.packages[0].PSObject.Properties.Remove('version')
Check "pinned with no version inside a profile" (HasProblem $c "toolchains.clang.msys2.packages*.version: required when mode is 'pinned'")

Write-Host "=== 7. A 2.x CONFIGURATION: the old requirements are still enforced ==="
$base = Join-Path $fixtures 'single-toolchain.json'

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
Check "empty toolchains: no phantom id"          (-not (HasProblem $c 'it travels on the command line as -Toolchain'))
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
    # A RUNNER THAT FAILED PRINTS NO ORDER LINE EITHER, so without this a check expecting "no ordering" would pass on
    # any crash. $null equals nothing a check compares it with, '' included.
    if ($LASTEXITCODE -ne 0) { return $null }
    $line = $out | Where-Object { $_ -match '^\s*Order\s*:' } | Select-Object -First 1
    if (-not $line) { return "" }
    return ($line -replace '^\s*Order\s*:\s*', '').Trim()
}

# Owner decision 2026-10-16: every MSYS2 environment first, then vcpkg toolchain by toolchain.
Check "dual: every step 2 first, then 3-5 toolchain by toolchain, drive steps once" `
    ((PlanOrder @('-ConfigFile', $dualCfg)) -eq '1 2:clang 2:ucrt 3:clang 4:clang 5:clang 3:ucrt 4:ucrt 5:ucrt 6 7')

Check "dual, -Toolchain ucrt -From 4" `
    ((PlanOrder @('-ConfigFile', $dualCfg, '-From', '4', '-Toolchain', 'ucrt')) -eq '4:ucrt 5:ucrt 6 7')

Check "dual, -Skip 3 leaves a hole in each toolchain" `
    ((PlanOrder @('-ConfigFile', $dualCfg, '-Skip', '3')) -eq '1 2:clang 2:ucrt 4:clang 5:clang 4:ucrt 5:ucrt 6 7')

# What "resume with" prints after a stop. FOUND IN USE: after a -From 3 run stopped in clang, it told the owner to
# resume ucrt from 3 -- a toolchain whose step 2 had never run.
$tc = @('clang', 'ucrt')
Check "resume: a stop in a toolchain's vcpkg part -> it to its end, then the ones behind it from 3" `
    (((Get-DrivEnvResumeArguments -Number 4 -Id 'clang' -Toolchains $tc) -join '|') -ceq '-From 4 -To 5 -Toolchain clang|-From 3 -Toolchain ucrt')
Check "...the last toolchain: just it, on through the drive steps" `
    (((Get-DrivEnvResumeArguments -Number 5 -Id 'ucrt' -Toolchains $tc) -join '|') -ceq '-From 5 -Toolchain ucrt')
Check "...a stop in step 2: step 2 again for every toolchain, none skipped" `
    (((Get-DrivEnvResumeArguments -Number 2 -Id 'ucrt' -Toolchains $tc) -join '|') -ceq '-From 2 -Toolchain clang,ucrt')
Check "...a drive step: from it, for this run's toolchains; a 2.x configuration: no -Toolchain" `
    ((((Get-DrivEnvResumeArguments -Number 6 -Id '' -Toolchains $tc) -join '|') -ceq '-From 6 -Toolchain clang,ucrt') -and
     (((Get-DrivEnvResumeArguments -Number 4 -Id '' -Toolchains @() -join '|')) -ceq '-From 4'))
Check "...and each line, run as a plan, does what it says" `
    (((PlanOrder (@('-ConfigFile', $dualCfg) + ('-From 4 -To 5 -Toolchain clang' -split ' '))) -eq '4:clang 5:clang') -and
     ((PlanOrder (@('-ConfigFile', $dualCfg) + ('-From 3 -Toolchain ucrt' -split ' '))) -eq '3:ucrt 4:ucrt 5:ucrt 6 7') -and
     ((PlanOrder (@('-ConfigFile', $dualCfg) + ('-From 2 -Toolchain clang,ucrt' -split ' '))) -eq '2:clang 2:ucrt 3:clang 4:clang 5:clang 3:ucrt 4:ucrt 5:ucrt 6 7'))

# A 2.x configuration prints no Order line at all, because there is nothing to order: the plan is the step list.
Check "2.x: no toolchain ordering is printed" ((PlanOrder @('-ConfigFile', $base)) -eq "")

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
Check "2.x without -Toolchain still works"      ((StepCode @('-ConfigFile', $base)) -eq 0)
Check "2.x with -Toolchain is refused"          ((StepCode @('-ConfigFile', $base, '-Toolchain', 'ucrt')) -eq 1)

# FOUND BY REVIEW. Step 2 must build the IgnorePkg union from the configuration AS READ: from its projected $Cfg it
# would hold this toolchain's pins only, and the other toolchain's pinned compiler would go in this run's upgrade.
# -ValidateOnly prints the union, so the wiring is checkable without a drive.
function Step2Union
{
    param([string[]]$Arguments)
    # Local to this function: a native command's stderr under 'Stop' is an exception in Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    $out  = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\2-Setup_MSYS2.ps1') @Arguments -ValidateOnly 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $line = @($out | ForEach-Object { "$_" } | Where-Object { $_ -match 'IgnorePkg for the drive' }) | Select-Object -First 1
    if (-not $line) { return $null }
    # Cut after the message's own colon: the timestamp in front of it holds colons too.
    return ,@(($line -replace '^.*once installed:\s*', '' -replace '\]\s*$', '') -split '\s+' | Where-Object { $_ })
}
$s2c = Step2Union @('-ConfigFile', $dualCfg, '-Toolchain', 'clang')
Check "step 2 for clang names ucrt's pins too"   (($null -ne $s2c) -and ($s2c -ccontains 'mingw-w64-ucrt-x86_64-gcc') -and ($s2c -ccontains 'mingw-w64-clang-x86_64-clang')) ("-> " + (@($s2c) -join ' '))
$s2u = Step2Union @('-ConfigFile', $dualCfg, '-Toolchain', 'ucrt')
Check "...and for ucrt, clang's"                 (($null -ne $s2u) -and ($s2u -ccontains 'mingw-w64-clang-x86_64-clang'))
$narrow = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-narrow-" + [guid]::NewGuid().ToString('N') + ".json")
try
{
    $c = Clone $dual; $c.generate = @('ucrt')
    [System.IO.File]::WriteAllText($narrow, ($c | ConvertTo-Json -Depth 100))
    $s2n = Step2Union @('-ConfigFile', $narrow, '-Toolchain', 'ucrt')
    Check "...and with 'generate' narrowed to ucrt, still clang's" (($null -ne $s2n) -and ($s2n -ccontains 'mingw-w64-clang-x86_64-clang'))
}
finally { Remove-Item -LiteralPath $narrow -Force -ErrorAction SilentlyContinue }

# FOUND BY REVIEW, and only checkable from the source: pacman is needed to run it. The union goes into pacman.conf
# only through Set-Msys2InstalledPins -- written whole, before the git install, it broke every fresh drive -- and it
# goes in twice: before the core upgrade and after the pinned install.
$step2Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\2-Setup_MSYS2.ps1'), [ref]$null, [ref]$null)
$calls = @($step2Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
$rawWrites = @($calls | Where-Object { ($_.GetCommandName() -eq 'Set-Msys2IgnorePkg') -and ($_.Extent.Text -match '\$ignoreUnion') })
$pinWrites = @($calls | Where-Object { ($_.GetCommandName() -eq 'Set-Msys2InstalledPins') -and ($_.Extent.Text -match '-Pins \$ignoreUnion') })
Check "step 2 never writes the raw union into pacman.conf" ($rawWrites.Count -eq 0)
Check "...it writes the installed pins twice"             ($pinWrites.Count -eq 2)

# FOUND BY REVIEW. The two checks above stop at the call sites; the fix lives INSIDE Set-Msys2InstalledPins, and in
# WHERE the two calls stand. So: inside, what reaches pacman.conf is the variable assigned from
# Select-DrivEnvInstalledPins; the first call comes before the core upgrade, the second after the pinned "pacman -U"
# and before the latest-mode install; and git is asked for after its install.
$pinFn = $step2Ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Set-Msys2InstalledPins') }, $true) | Select-Object -First 1
$inner = if ($pinFn) { @($pinFn.Body.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Set-Msys2IgnorePkg') }, $true)) } else { @() }
$fromSel = if ($pinFn) { @($pinFn.Body.FindAll({ param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left.Extent.Text -eq '$protect') -and ($n.Right.Extent.Text -match '^Select-DrivEnvInstalledPins ') }, $true)) } else { @() }
Check "Set-Msys2InstalledPins writes ONLY the installed pins" `
    (($inner.Count -eq 1) -and ($inner[0].Extent.Text -match '-Packages \$protect\b') -and ($fromSel.Count -eq 1))
$src2   = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\2-Setup_MSYS2.ps1')
$sorted = @($pinWrites | Sort-Object { $_.Extent.StartOffset })
$upg    = $src2.IndexOf('Running core system upgrade pass'); $pinU = $src2.IndexOf('"-U --noconfirm "'); $latest = $src2.IndexOf('# Install LATEST packages')
Check "...the first before the core upgrade, the second between the pinned and the latest installs" `
    (($sorted.Count -eq 2) -and ($upg -gt 0) -and ($sorted[0].Extent.StartOffset -lt $upg) -and
     ($sorted[1].Extent.StartOffset -gt $pinU) -and ($sorted[1].Extent.StartOffset -lt $latest))
Check "...and git is asked for after its install"         ($src2 -match '"pacman -Q \$gitPkgName"')

function Obj    { param([string]$Json) return ($Json | ConvertFrom-Json) }
function Throws { param([scriptblock]$Block) try { $null = & $Block; return $false } catch { return $true } }
function Joined { param($List) return (@($List) -join '|') }

Write-Host "=== 15. Get-DrivEnvToolchainKey: ONE rule for subsystem, legacy profile and nothing ==="
Check "subsystem as written"                  ((Get-DrivEnvToolchainKey -Target (Obj '{"subsystem":"clang64"}')) -ceq 'clang64')
Check "subsystem trimmed and lowered"         ((Get-DrivEnvToolchainKey -Target (Obj '{"subsystem":"  CLANG64 "}')) -ceq 'clang64')
Check "legacy profile means <profile>64"      ((Get-DrivEnvToolchainKey -Target (Obj '{"profile":"ucrt"}')) -ceq 'ucrt64')
Check "legacy profile trimmed BEFORE the 64"  ((Get-DrivEnvToolchainKey -Target (Obj '{"profile":" Ucrt "}')) -ceq 'ucrt64')
Check "subsystem wins over profile"           ((Get-DrivEnvToolchainKey -Target (Obj '{"subsystem":"clang64","profile":"ucrt"}')) -ceq 'clang64')
Check "a blank subsystem falls back"          ((Get-DrivEnvToolchainKey -Target (Obj '{"subsystem":"  ","profile":"ucrt"}')) -ceq 'ucrt64')
Check "neither: empty"                        ((Get-DrivEnvToolchainKey -Target (Obj '{}')) -ceq '')
Check "nothing at all: empty, no throw"       ((Get-DrivEnvToolchainKey) -ceq '')
Check "a configuration with no msys2: empty"  ((Get-DrivEnvToolchainKey -Cfg (Obj '{}')) -ceq '')
Check "-Cfg reads msys2.target (2.x fixture)" ((Get-DrivEnvToolchainKey -Cfg (Load $base)) -ceq 'ucrt64')
Check "-Cfg on each projected toolchain"      (((Get-DrivEnvToolchainKey -Cfg $rc) -ceq 'clang64') -and ((Get-DrivEnvToolchainKey -Cfg $ru) -ceq 'ucrt64'))

Write-Host "=== 16. Resolve-DrivEnvMsys2Target and Get-DrivEnvMsys2PackageName ==="
$t = Resolve-DrivEnvMsys2Target -Target (Obj '{"subsystem":"mingw64"}')
Check "a hashtable, so it is never unrolled"  ($t -is [hashtable])
Check "the table: mingw64 has NO infix"       (($t.Prefix -ceq 'mingw-w64-x86_64') -and ($t.Subpath -ceq 'mingw/mingw64') -and ($t.Arch -ceq 'x86_64') -and ($t.Family -ceq 'gcc'))
$t = Resolve-DrivEnvMsys2Target -Target (Obj '{"profile":"clang"}')
Check "a legacy profile reaches the table"    (($t.Subsystem -ceq 'clang64') -and ($t.Prefix -ceq 'mingw-w64-clang-x86_64') -and ($t.Family -ceq 'clang'))
$t = Resolve-DrivEnvMsys2Target -Target (Obj '{"subsystem":"newsys64","package_prefix":" mingw-w64-new-x86_64 ","repo_subpath":" /mingw/newsys64/ ","arch":" x86_64 ","family":" CLANG "}')
Check "overrides: trimmed, slashes off the subpath, family lowered" `
    (($t.Prefix -ceq 'mingw-w64-new-x86_64') -and ($t.Subpath -ceq 'mingw/newsys64') -and ($t.Arch -ceq 'x86_64') -and ($t.Family -ceq 'clang'))
$t = Resolve-DrivEnvMsys2Target -Target (Obj '{"subsystem":"newsys64"}')
Check "unknown subsystem: empty fields, no abort" (($t.Subsystem -ceq 'newsys64') -and ($t.Prefix -ceq '') -and ($t.Subpath -ceq '') -and ($t.Arch -ceq '') -and ($t.Family -ceq ''))
$t = Resolve-DrivEnvMsys2Target -Target $null
Check "no target: everything empty"           (($t.Subsystem -ceq '') -and ($t.Prefix -ceq ''))

Check "mingw, the default repo, gets the prefix" ((Get-DrivEnvMsys2PackageName -Package (Obj '{"name":"cmake"}') -Prefix 'mingw-w64-clang-x86_64') -ceq 'mingw-w64-clang-x86_64-cmake')
Check "msys is the name verbatim"             ((Get-DrivEnvMsys2PackageName -Package (Obj '{"name":"make","repo":"msys"}') -Prefix 'mingw-w64-clang-x86_64') -ceq 'make')
Check "name and repo trimmed"                 ((Get-DrivEnvMsys2PackageName -Package (Obj '{"name":" gcc ","repo":" MINGW "}') -Prefix 'mingw-w64-ucrt-x86_64') -ceq 'mingw-w64-ucrt-x86_64-gcc')
Check "an unknown repo names nothing"         ((Get-DrivEnvMsys2PackageName -Package (Obj '{"name":"x","repo":"aur"}') -Prefix 'p') -ceq '')
Check "mingw with no prefix names nothing"    ((Get-DrivEnvMsys2PackageName -Package (Obj '{"name":"x"}') -Prefix '') -ceq '')

Write-Host "=== 17. Get-DrivEnvToolchainTargets: sizes 0, 1 and 2, and the @() trap ==="
$tg0 = Get-DrivEnvToolchainTargets -Cfg $null
Check "size 0 (no configuration) is an EMPTY ARRAY" (($tg0 -is [System.Array]) -and ($tg0.Count -eq 0))
$tg1 = Get-DrivEnvToolchainTargets -Cfg (Load $base)
Check "size 1: a 2.x file is ONE toolchain, still an array" (($tg1 -is [System.Array]) -and ($tg1.Count -eq 1) -and ($tg1[0] -is [pscustomobject]))
Check "2.x: Id empty, Key and Triplet from the file" (($tg1[0].Id -ceq '') -and ($tg1[0].Key -ceq 'ucrt64') -and ($tg1[0].Triplet -ceq 'x64-mingw-ucrt-dynamic-release'))
$one = Clone $dual; $one.generate = @('ucrt')
$tg1g = Get-DrivEnvToolchainTargets -Cfg $one
Check "size 1: a one-id generate" (($tg1g -is [System.Array]) -and ($tg1g.Count -eq 1) -and ($tg1g[0].Id -ceq 'ucrt') -and ($tg1g[0].Key -ceq 'ucrt64'))
$tg2 = Get-DrivEnvToolchainTargets -Cfg $dual
Check "size 2: in generate order"            ((Joined ($tg2 | ForEach-Object { $_.Id })) -ceq 'clang|ucrt')
Check "keys are subsystems, not ids"         ((Joined ($tg2 | ForEach-Object { $_.Key })) -ceq 'clang64|ucrt64')
Check "each toolchain's own triplet"         ((Joined ($tg2 | ForEach-Object { $_.Triplet })) -ceq 'x64-mingw-clang-dynamic-release|x64-mingw-ucrt-dynamic-release')
Check "each Cfg is a projection"             (@($tg2 | Where-Object { @($_.Cfg.PSObject.Properties.Name) -contains 'toolchains' }).Count -eq 0)
Check "the configuration passed in is untouched" (@($dual.PSObject.Properties.Name) -contains 'toolchains')
$w0 = @(Get-DrivEnvToolchainTargets -Cfg $null)
$w1 = @(Get-DrivEnvToolchainTargets -Cfg (Load $base))
$w2 = @(Get-DrivEnvToolchainTargets -Cfg $dual)
Check "wrapping in @() NESTS, size 0"        (($w0.Count -eq 1) -and ($w0[0] -is [System.Array]))
Check "wrapping in @() NESTS, size 1"        (($w1.Count -eq 1) -and ($w1[0] -is [System.Array]))
Check "wrapping in @() NESTS, size 2"        (($w2.Count -eq 1) -and ($w2[0] -is [System.Array]))

Write-Host "=== 18. Get-DrivEnvToolchainNames: exact names, ALWAYS suffixed, and the %~n0 round trip ==="
$nc = Get-DrivEnvToolchainNames -Cfg $rc
$nu = Get-DrivEnvToolchainNames -Cfg $ru
Check "a hashtable"                  ($nc -is [hashtable])
Check "Key / Prefix / Stem"          (($nc.Key -ceq 'clang64') -and ($nc.Prefix -ceq 'degorasslr') -and ($nc.Stem -ceq 'degorasslr_clang64'))
Check "EnvFile"                      ($nc.EnvFile             -ceq 'N:\env\degorasslr_clang64_env_variables.env') "= $($nc.EnvFile)"
Check "LauncherDir"                  ($nc.LauncherDir         -ceq 'N:\env\launcher')
Check "Launcher"                     ($nc.Launcher            -ceq 'N:\env\launcher\degorasslr_clang64_env_launcher.bat')
Check "DriveShortcut"                ($nc.DriveShortcut       -ceq 'N:\degorasslr_clang64_env_launcher.lnk')
Check "DesktopShortcutName"          ($nc.DesktopShortcutName -ceq 'DegorasSLR clang64 Environment.lnk')
Check "PackagesExport"               ($nc.PackagesExport      -ceq 'degorasslr_clang64_packages')
Check "VcpkgReference"               ($nc.VcpkgReference      -ceq 'N:\env\degorasslr_clang64_vcpkg_reference.json')
Check "ManifestName"                 ($nc.ManifestName        -ceq 'degorasslr-clang64')
Check "InventoryDir"                 ($nc.InventoryDir        -ceq 'N:\installation')
Check "ucrt EnvFile"                 ($nu.EnvFile             -ceq 'N:\env\degorasslr_ucrt64_env_variables.env')
Check "no Legacy entry"              (-not $nc.ContainsKey('Legacy'))
Check "Bootstrap, step 2's"          ($nc.Bootstrap           -ceq 'N:\env\launcher\degorasslr_clang64_env_launcher_bootstrap.sh')
# Owner decision 2026-10-15: one Qt Creator launcher per toolchain, opening Qt Creator in that toolchain's environment.
Check "Qt Creator's launcher, its launch script and shortcuts, per toolchain" `
    (($nc.QtLauncher -ceq 'N:\env\launcher\degorasslr_clang64_qtcreator.bat') -and ($nc.QtLauncherTail -ceq 'N:\env\launcher\degorasslr_clang64_qtcreator_launcher.sh') -and
     ($nc.QtShortcut -ceq 'N:\degorasslr_clang64_qtcreator.lnk') -and ($nc.QtDesktopShortcutName -ceq 'DegorasSLR clang64 Qt Creator.lnk'))
Check "PackagesExport is the name step 2 already writes" ($nc.PackagesExport -ceq ("{0}_{1}_packages" -f 'DegorasSLR'.ToLowerInvariant(), 'clang64'))

$perToolchain = @('Key', 'Stem', 'EnvFile', 'Launcher', 'Bootstrap', 'DriveShortcut', 'DesktopShortcutName', 'PackagesExport', 'VcpkgReference', 'ManifestName',
                  'QtLauncher', 'QtLauncherTail', 'QtShortcut', 'QtDesktopShortcutName')
Check "two toolchains share no per-toolchain name" (@($perToolchain | Where-Object { $nc[$_] -eq $nu[$_] }).Count -eq 0)
Check "and do share the drive's folders"           (($nc.LauncherDir -ceq $nu.LauncherDir) -and ($nc.InventoryDir -ceq $nu.InventoryDir) -and ($nc.Prefix -ceq $nu.Prefix))

$ns = Get-DrivEnvToolchainNames -Cfg (Load $base)
Check "ALWAYS suffixed: a 2.x configuration too" ($ns.EnvFile -ceq 'R:\env\degorasslr_ucrt64_env_variables.env') "= $($ns.EnvFile)"
$c = Load $base; $c.msys2.target.PSObject.Properties.Remove('subsystem'); Add-Member -InputObject $c.msys2.target -MemberType NoteProperty -Name 'profile' -Value 'ucrt'
Check "the legacy profile names the same files"  ((Get-DrivEnvToolchainNames -Cfg $c).EnvFile -ceq $ns.EnvFile)
$c = Clone $rc; $c.environment.dev_env_name = '  DegorasSLR '; $c.environment.dev_drive_letter = 'n'
$np = Get-DrivEnvToolchainNames -Cfg $c
Check "name trimmed, letter upper-cased"         (($np.EnvFile -ceq $nc.EnvFile) -and ($np.DesktopShortcutName -ceq $nc.DesktopShortcutName))
$c = Clone $rc; $c.msys2.target = (Obj '{}')
Check "no key: no names"                         ($null -eq (Get-DrivEnvToolchainNames -Cfg $c))
$c = Clone $rc; $c.environment.dev_env_name = '  '
Check "no dev_env_name: no names"                ($null -eq (Get-DrivEnvToolchainNames -Cfg $c))

# The .bat derives everything from its own name: %~n0, minus '_env_launcher', is the Stem. These hold the names
# table to that rule.
$suffix   = '_env_launcher'
$selfName = [System.IO.Path]::GetFileNameWithoutExtension($nc.Launcher)
Check "%~n0 ends with it"                         ($selfName.EndsWith($suffix, [StringComparison]::Ordinal))
Check "%~n0 minus '_env_launcher' is the Stem"    ($selfName.Substring(0, $selfName.Length - $suffix.Length) -ceq $nc.Stem)
Check "Stem + '_env_variables.env' is the EnvFile leaf" (($nc.Stem + '_env_variables.env') -ceq [System.IO.Path]::GetFileName($nc.EnvFile))
Check "the launcher sits in LauncherDir, the .env beside it" (([System.IO.Path]::GetDirectoryName($nc.Launcher) -ceq $nc.LauncherDir) -and ([System.IO.Path]::GetDirectoryName($nc.LauncherDir) -ceq [System.IO.Path]::GetDirectoryName($nc.EnvFile)))

foreach ($f in (Get-ChildItem -LiteralPath $cfgDir -Filter '*.json' -File | Sort-Object Name))
{
    $targets = Get-DrivEnvToolchainTargets -Cfg (Load $f.FullName)
    $missing = @($targets | Where-Object { $null -eq (Get-DrivEnvToolchainNames -Cfg $_.Cfg) })
    Check "$($f.Name): every toolchain has names" (($targets.Count -gt 0) -and ($missing.Count -eq 0))
}

Write-Host "=== 19. Get-DrivEnvRecordName ==="
Check "the key goes before the extension" ((Get-DrivEnvRecordName -Name 'vcpkg_packages.txt'  -Key 'clang64') -ceq 'vcpkg_packages_clang64.txt')
Check ".json too"                         ((Get-DrivEnvRecordName -Name 'vcpkg_packages.json' -Key 'ucrt64')  -ceq 'vcpkg_packages_ucrt64.json')
Check "verification"                      ((Get-DrivEnvRecordName -Name 'verification.txt'    -Key 'clang64') -ceq 'verification_clang64.txt')
Check "no extension"                      ((Get-DrivEnvRecordName -Name 'environment'         -Key 'clang64') -ceq 'environment_clang64')
Check "no key: the name unchanged"        ((Get-DrivEnvRecordName -Name 'vcpkg_baseline.txt'  -Key '')        -ceq 'vcpkg_baseline.txt')

Write-Host "=== 20. THE WORKSPACE FOLDER AND THE DRIVE HEADER ==="
Check "absent: 'workspace'"                    ((Resolve-DrivEnvWorkspaceFolder -Cfg (Obj '{}')) -ceq 'workspace')
Check "as configured"                          ((Resolve-DrivEnvWorkspaceFolder -Cfg $dual) -ceq 'workspace_degoras')
Check "backslashes and edge slashes normalised" ((Resolve-DrivEnvWorkspaceFolder -Cfg (Obj '{"workspace":{"default_folder":" \\src\\ws\\ "}}')) -ceq 'src/ws')
Check "a drive letter is refused"              ((Resolve-DrivEnvWorkspaceFolder -Cfg (Obj '{"workspace":{"default_folder":"C:/ws"}}')) -ceq '')
Check "a '..' segment is refused"              ((Resolve-DrivEnvWorkspaceFolder -Cfg (Obj '{"workspace":{"default_folder":"a/../b"}}')) -ceq '')
Check "only slashes is refused"                ((Resolve-DrivEnvWorkspaceFolder -Cfg (Obj '{"workspace":{"default_folder":" // "}}')) -ceq '')

$h = Get-DrivEnvDriveEnvValues -Cfg $dual
Check "an ordered table"                       ($h -is [System.Collections.Specialized.OrderedDictionary])
Check "five keys, in this order"               ((Joined $h.Keys) -ceq 'DEVDRIVE_NAME|DEVDRIVE_LETTER|DEVSYSTEM_NAME|DEVSYSTEM_DEPLOYS|DEVSYSTEM_WORKSPACE')
Check "values"                                 (($h['DEVDRIVE_NAME'] -ceq 'DEV_DEGORAS_SLR') -and ($h['DEVDRIVE_LETTER'] -ceq 'N:') -and ($h['DEVSYSTEM_NAME'] -ceq 'DegorasSLR') -and
                                                ($h['DEVSYSTEM_DEPLOYS'] -ceq 'N:/deploys') -and ($h['DEVSYSTEM_WORKSPACE'] -ceq 'N:/workspace_degoras'))
Check "DEVSYSTEM_BUILDTREES is NOT in it"      (-not $h.Contains('DEVSYSTEM_BUILDTREES'))
$c = Clone $dual; $c.workspace.default_folder = 'C:/ws'
Check "an invalid workspace: no header"        ($null -eq (Get-DrivEnvDriveEnvValues -Cfg $c))

Write-Host "=== 21. Set-DrivEnvFileValues -First ==="
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try
{
    $f = Join-Path $tmp 'new.env'
    Set-DrivEnvFileValues -Path $f -Values ([ordered]@{ DEVDRIVE_LETTER = 'N:' }) -Section 'drive' -First
    Check "a new file holds just the block" ((Joined (Get-Content -LiteralPath $f)) -ceq '# >>> drivenv:drive|DEVDRIVE_LETTER=N:|# <<< drivenv:drive')

    $f = Join-Path $tmp 'existing.env'
    Set-DrivEnvFileValues -Path $f -Lines @('MSYS2_ENV=clang64', 'PATH=${BASE_PATH}') -Section 'msys2'
    Set-DrivEnvFileValues -Path $f -Values ([ordered]@{ VCPKG_DEFAULT_TRIPLET = 't' }) -Section 'vcpkg'
    Set-DrivEnvFileValues -Path $f -Values ([ordered]@{ DEVDRIVE_LETTER = 'N:' }) -Section 'drive' -First
    $l1 = @(Get-Content -LiteralPath $f)
    Check "a section never seen goes on TOP"         (($l1[0] -ceq '# >>> drivenv:drive') -and ($l1[1] -ceq 'DEVDRIVE_LETTER=N:') -and ($l1[2] -ceq '# <<< drivenv:drive'))
    Check "followed by exactly one blank line"       (($l1[3] -ceq '') -and ($l1[4] -ceq '# >>> drivenv:msys2'))
    Check "PATH is still last"                       ($l1[-1] -ceq 'PATH=${BASE_PATH}')

    Set-DrivEnvFileValues -Path $f -Values ([ordered]@{ DEVDRIVE_LETTER = 'R:' }) -Section 'drive' -First
    $l2 = @(Get-Content -LiteralPath $f)
    Check "a rewrite stays in its slot, nothing stacks" (($l2.Count -eq $l1.Count) -and ($l2[1] -ceq 'DEVDRIVE_LETTER=R:') -and ($l2[4] -ceq '# >>> drivenv:msys2'))

    Set-DrivEnvFileValues -Path $f -Values ([ordered]@{ X = '1' }) -Section 'extra'
    $l3 = @(Get-Content -LiteralPath $f)
    Check "without -First a new section is still appended" (($l3[0] -ceq '# >>> drivenv:drive') -and ($l3[-2] -ceq '# <<< drivenv:extra') -and ($l3[-1] -ceq 'PATH=${BASE_PATH}'))
}
finally
{
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "=== 22. Resolve-DrivEnvBuildtreesRoot: EnvValue and ToolchainWindows ==="
$bt = Resolve-DrivEnvBuildtreesRoot -Cfg (Obj '{"vcpkg":{"buildtrees_root":"bt"}}') -DriveLetter 'N'
Check "'bt': Folder, Windows and Posix unchanged"   (($bt.Folder -ceq 'bt') -and ($bt.Windows -ceq 'N:/bt') -and ($bt.Posix -ceq '/n/bt'))
Check "'bt': EnvValue is the literal, unexpanded text" ($bt.EnvValue -ceq '${DEVDRIVE_LETTER}/bt/${VCPKG_DEFAULT_TRIPLET}') "= $($bt.EnvValue)"
Check "no -Triplet: no ToolchainWindows"             (-not $bt.ContainsKey('ToolchainWindows'))
$bt = Resolve-DrivEnvBuildtreesRoot -Cfg (Obj '{"vcpkg":{"buildtrees_root":"buildtrees"}}') -DriveLetter 'N:' -Triplet ' x64-mingw-clang-dynamic-release '
Check "'buildtrees': EnvValue"                       ($bt.EnvValue -ceq '${DEVDRIVE_LETTER}/buildtrees/${VCPKG_DEFAULT_TRIPLET}')
Check "'buildtrees': ToolchainWindows"               ($bt.ToolchainWindows -ceq 'N:/buildtrees/x64-mingw-clang-dynamic-release')
$bt = Resolve-DrivEnvBuildtreesRoot -Cfg (Obj '{"vcpkg":{}}') -DriveLetter 'N'
Check "absent: the 'bt' default"                     (($bt.Folder -ceq 'bt') -and ($bt.EnvValue -ceq '${DEVDRIVE_LETTER}/bt/${VCPKG_DEFAULT_TRIPLET}'))
$bt = Resolve-DrivEnvBuildtreesRoot -Cfg (Obj '{"vcpkg":{"buildtrees_root":"N:/scratch/bt"}}') -DriveLetter 'N' -Triplet 't'
Check "'N:/scratch/bt': the letter goes, the chain stays" (($bt.Windows -ceq 'N:/scratch/bt') -and ($bt.EnvValue -ceq '${DEVDRIVE_LETTER}/scratch/bt/${VCPKG_DEFAULT_TRIPLET}') -and ($bt.ToolchainWindows -ceq 'N:/scratch/bt/t'))

Write-Host "=== 23. Get-DrivEnvCustomFolders: the drive's folders and each toolchain's ==="
$cf1 = Obj '{"environment":{"custom_folders":["logs/gstreamer/${DEVSYSTEM_TOOLCHAIN_ID}/dot"]}}'
$cf2 = Obj '{"environment":{"custom_folders":[" \\workspace_x\\ ","logs/gstreamer/${DEVSYSTEM_TOOLCHAIN_ID}/dot","logs/a","  ","${DEVSYSTEM_TOOLCHAIN_ID}"]}}'
$cfn = Get-DrivEnvCustomFolders -Cfg (Obj '{"environment":{}}')
Check "size 0: no key at all, an EMPTY ARRAY"        (($cfn -is [System.Array]) -and ($cfn.Count -eq 0))
$d0 = Get-DrivEnvCustomFolders -Cfg $cf1
Check "size 0: the drive skips a token entry"        (($d0 -is [System.Array]) -and ($d0.Count -eq 0))
$k1 = Get-DrivEnvCustomFolders -Cfg $cf1 -ToolchainKey 'clang64'
Check "size 1: the token becomes the key"            (($k1 -is [System.Array]) -and ($k1.Count -eq 1) -and ($k1[0] -ceq 'logs/gstreamer/clang64/dot'))
$d2 = Get-DrivEnvCustomFolders -Cfg $cf2
Check "size 2: the drive's own, normalised, in order" ((Joined $d2) -ceq 'workspace_x|logs/a')
$k2 = Get-DrivEnvCustomFolders -Cfg $cf2 -ToolchainKey 'ucrt64'
Check "size 2: the toolchain's own, in order"        ((Joined $k2) -ceq 'logs/gstreamer/ucrt64/dot|ucrt64')
$wk0 = @(Get-DrivEnvCustomFolders -Cfg $cf1)
$wk1 = @(Get-DrivEnvCustomFolders -Cfg $cf1 -ToolchainKey 'clang64')
Check "wrapping in @() NESTS, size 0"                (($wk0.Count -eq 1) -and ($wk0[0] -is [System.Array]))
Check "wrapping in @() NESTS, size 1"                (($wk1.Count -eq 1) -and ($wk1[0] -is [System.Array]))

Write-Host "=== 24. THE IgnorePkg UNION AND THE pacman.conf EDIT ==="
$u2 = Get-DrivEnvIgnorePkgUnion -Cfg $dual
Check "dual: every pin of both toolchains"        ($u2.Count -eq 36) "= $($u2.Count)"
Check "both prefixes of a shared mingw pin"       (($u2 -ccontains 'mingw-w64-clang-x86_64-cmake') -and ($u2 -ccontains 'mingw-w64-ucrt-x86_64-cmake'))
Check "each toolchain's own compiler"             (($u2 -ccontains 'mingw-w64-clang-x86_64-clang') -and ($u2 -ccontains 'mingw-w64-ucrt-x86_64-gcc'))
Check "the shared msys 'make' appears once"       (@($u2 | Where-Object { $_ -ceq 'make' }).Count -eq 1)
Check "sorted"                                    ((Joined $u2) -ceq (Joined ($u2 | Sort-Object)))
# FOUND BY REVIEW. Narrowing 'generate' to rebuild one toolchain is what the key is for, and the other toolchain is
# still on the drive: a union of the GENERATED ids alone dropped its pins right before "pacman -Su".
$u1g = Get-DrivEnvIgnorePkgUnion -Cfg $one
Check "a one-id generate still carries the other DECLARED toolchain's pins" (($u1g.Count -eq 36) -and ($u1g -ccontains 'mingw-w64-clang-x86_64-clang')) "= $($u1g.Count)"
# The fixture spells package_prefix out, which names the pins whatever the subsystem says; so it goes too.
$c = Clone $dual; $c.generate = @('ucrt'); $c.toolchains.clang.msys2.target.subsystem = 'newsys64'
$c.toolchains.clang.msys2.target.PSObject.Properties.Remove('package_prefix')
Check "a declared toolchain not generated, with no prefix, is skipped, not thrown" `
    ((-not (Throws { Get-DrivEnvIgnorePkgUnion -Cfg $c })) -and (@(Get-DrivEnvIgnorePkgUnion -Cfg $c)[0] -ccontains 'mingw-w64-ucrt-x86_64-gcc') -and
     (@(@(Get-DrivEnvIgnorePkgUnion -Cfg $c)[0] | Where-Object { $_ -like 'mingw-w64-clang-*' }).Count -eq 0))
$c = Clone $dual; $c.toolchains.clang.msys2.target.subsystem = 'newsys64'
$c.toolchains.clang.msys2.target.PSObject.Properties.Remove('package_prefix')
Check "...but a GENERATED one with no prefix still throws" (Throws { Get-DrivEnvIgnorePkgUnion -Cfg $c })
$us = Get-DrivEnvIgnorePkgUnion -Cfg (Load $base)
Check "2.x: its pins, the 'latest' one left out"  (($us.Count -eq 19) -and ($us -notcontains 'mingw-w64-ucrt-x86_64-tree')) "= $($us.Count)"
$c = Load $base; foreach ($p in $c.msys2.packages) { $p.mode = 'latest' }
$u0 = Get-DrivEnvIgnorePkgUnion -Cfg $c
Check "size 0: nothing pinned is an EMPTY ARRAY, not null" (($u0 -is [System.Array]) -and ($u0.Count -eq 0))
$c = Load $base; $c.msys2.packages = @($c.msys2.packages[0])
$u1 = Get-DrivEnvIgnorePkgUnion -Cfg $c
Check "size 1 stays an array"                     (($u1 -is [System.Array]) -and ($u1.Count -eq 1) -and ($u1[0] -ceq 'mingw-w64-ucrt-x86_64-headers'))
$wu = @(Get-DrivEnvIgnorePkgUnion -Cfg $dual)
Check "wrapping in @() NESTS"                     (($wu.Count -eq 1) -and ($wu[0] -is [System.Array]))
$c = Load $base; $c.msys2.target.subsystem = 'newsys64'
Check "a toolchain with no prefix throws"         (Throws { Get-DrivEnvIgnorePkgUnion -Cfg $c })

$marker = '# DrivEnv: pinned by the configuration, kept from being upgraded by pacman -Syu.'
$stock  = @('[options]', '#IgnorePkg   =', '#IgnoreGroup =', '', '[msys]', 'Include = /etc/pacman.d/mirrorlist.msys')
$r1 = Update-DrivEnvIgnorePkgLines -Lines $stock -Packages @('b', 'a', 'a', ' ')
Check "set: replaces the commented line, sorted and unique" (($r1.Status -ceq 'set') -and ((Joined $r1.Lines) -ceq (Joined @('[options]', $marker, 'IgnorePkg   = a b', '#IgnoreGroup =', '', '[msys]', 'Include = /etc/pacman.d/mirrorlist.msys'))))
$r2 = Update-DrivEnvIgnorePkgLines -Lines $r1.Lines -Packages @('c')
Check "a re-run replaces, it does not stack"      (($r2.Lines.Count -eq $r1.Lines.Count) -and (@($r2.Lines | Where-Object { $_ -ceq $marker }).Count -eq 1) -and ($r2.Lines -ccontains 'IgnorePkg   = c'))
$r3 = Update-DrivEnvIgnorePkgLines -Lines $r2.Lines -Packages @()
Check "an empty union clears it back to stock"    (($r3.Status -ceq 'cleared') -and ((Joined $r3.Lines) -ceq (Joined $stock)))
$r4 = Update-DrivEnvIgnorePkgLines -Lines $stock -Packages @()
Check "a file it never wrote is left alone"       (($r4.Status -ceq 'unchanged') -and ((Joined $r4.Lines) -ceq (Joined $stock)))
$r5 = Update-DrivEnvIgnorePkgLines -Lines @('[options]', 'Architecture = auto', '[msys]') -Packages @('a')
Check "no IgnorePkg line: directly under [options]" ((Joined $r5.Lines) -ceq (Joined @('[options]', $marker, 'IgnorePkg   = a', 'Architecture = auto', '[msys]')))
$r6 = Update-DrivEnvIgnorePkgLines -Lines @('[msys]') -Packages @('a')
Check "no [options]: nowhere to put it, unchanged" (($r6.Status -ceq 'no-options') -and ((Joined $r6.Lines) -ceq '[msys]'))
Check "Lines is a string array even for one line" ($r6.Lines -is [string[]])

# FOUND BY REVIEW. pacman reads a configuration line into 4096 bytes and cuts the rest off; IgnorePkg accumulates
# across lines, so a long list is spread over several, and the whole block is what a re-run replaces.
$names = @('aaaa', 'bbbb', 'cccc', 'dddd', 'eeee')
$m1 = Update-DrivEnvIgnorePkgLines -Lines $stock -Packages $names -MaxLineLength 24
$managed = @($m1.Lines | Where-Object { $_ -match '^IgnorePkg' })
Check "a long list: several lines, none past the limit, every name once" `
    (($managed.Count -eq 3) -and (@($managed | Where-Object { $_.Length -gt 24 }).Count -eq 0) -and
     ((Joined (($managed | ForEach-Object { $_ -replace '^IgnorePkg\s*=\s*', '' }) -join ' ' -split ' ')) -ceq (Joined $names))) ("-> " + (Joined $managed))
Check "...the block sits where the commented line was" ((Joined $m1.Lines[0..4]) -ceq (Joined @('[options]', $marker, 'IgnorePkg   = aaaa bbbb', 'IgnorePkg   = cccc dddd', 'IgnorePkg   = eeee')))
$m2 = Update-DrivEnvIgnorePkgLines -Lines $m1.Lines -Packages @('zz') -MaxLineLength 24
Check "a shorter re-run leaves none of the old lines behind" ((Joined $m2.Lines) -ceq (Joined @('[options]', $marker, 'IgnorePkg   = zz', '#IgnoreGroup =', '', '[msys]', 'Include = /etc/pacman.d/mirrorlist.msys')))
$m3 = Update-DrivEnvIgnorePkgLines -Lines $m1.Lines -Packages @()
Check "clearing a multi-line block restores stock" (($m3.Status -ceq 'cleared') -and ((Joined $m3.Lines) -ceq (Joined $stock)))
$m4 = Update-DrivEnvIgnorePkgLines -Lines $stock -Packages @('a-very-long-package-name-past-the-limit') -MaxLineLength 10
Check "a name longer than the limit still gets its line" ($m4.Lines -ccontains 'IgnorePkg   = a-very-long-package-name-past-the-limit')
$m5 = Update-DrivEnvIgnorePkgLines -Lines (@('[options]', $marker, 'IgnorePkg   = old') + @('IgnorePkg = mine')) -Packages @('new')
Check "a hand-written IgnorePkg after the block is not taken for ours" ((Joined $m5.Lines) -ceq (Joined @('[options]', $marker, 'IgnorePkg   = new', 'IgnorePkg = mine')))

Write-Host "=== 24b. Select-DrivEnvInstalledPins: name only what is installed ==="
# FOUND BY REVIEW. IgnorePkg also stops pacman RESOLVING a dependency to a package not installed yet: with the
# dual union in pacman.conf and nothing installed, "pacman -S --needed <git>" could not satisfy cc-libs, curl and
# libwinpthread. So step 2 names only installed pins.
$pi = Select-DrivEnvInstalledPins -Pins @('b', 'a', 'c', ' ', 'a') -Installed @('a', 'c', 'x', '')
Check "only the installed ones, sorted and unique"   ((Joined $pi) -ceq 'a|c')
$pi0 = Select-DrivEnvInstalledPins -Pins @('a') -Installed @()
Check "nothing installed: an EMPTY ARRAY"            (($pi0 -is [System.Array]) -and ($pi0.Count -eq 0))
$pi1 = Select-DrivEnvInstalledPins -Pins @('a', 'b') -Installed @('b')
Check "size 1 stays an array"                        (($pi1 -is [System.Array]) -and ($pi1.Count -eq 1) -and ($pi1[0] -ceq 'b'))
$wpi = @(Select-DrivEnvInstalledPins -Pins @('a') -Installed @('a'))
Check "wrapping in @() NESTS"                        (($wpi.Count -eq 1) -and ($wpi[0] -is [System.Array]))
$pfresh = Select-DrivEnvInstalledPins -Pins (Get-DrivEnvIgnorePkgUnion -Cfg $dual) -Installed @('bash', 'pacman', 'msys2-runtime')
Check "a fresh drive names nothing, so pacman.conf is left as shipped" ((Update-DrivEnvIgnorePkgLines -Lines $stock -Packages $pfresh).Status -ceq 'unchanged')

Write-Host "=== 25. Select-DrivEnvToolchainPackages ==="
$q = @('bash 5.2.037-2', 'mingw-w64-clang-x86_64-clang 22.1.8-2', 'mingw-w64-ucrt-x86_64-gcc 16.2.0-3', 'make 4.4.1-3', '', 'mingw-w64-ucrt-x86_64x-odd 1-1', 'mingw-w64-cross-gcc 16.2.0-1')
$s2 = Select-DrivEnvToolchainPackages -Lines $q -Prefix 'mingw-w64-clang-x86_64'
# FOUND BY REVIEW: dropping every 'mingw-w64-' name lost the msys repository's mingw-w64-cross-* packages from every
# record. Only ANOTHER SUBSYSTEM'S packages, by its exact prefix, are dropped -- a near-prefix is not one.
Check "own prefix and the msys base, cross packages included; not another subsystem's, by its exact prefix" `
    ((Joined $s2) -ceq 'bash 5.2.037-2|mingw-w64-clang-x86_64-clang 22.1.8-2|make 4.4.1-3|mingw-w64-ucrt-x86_64x-odd 1-1|mingw-w64-cross-gcc 16.2.0-1') ("-> " + (Joined $s2))
$s1 = Select-DrivEnvToolchainPackages -Lines @('mingw-w64-ucrt-x86_64-gcc 16.2.0-3') -Prefix 'mingw-w64-ucrt-x86_64'
Check "size 1 stays an array"                     (($s1 -is [System.Array]) -and ($s1.Count -eq 1))
$s0 = Select-DrivEnvToolchainPackages -Lines @('mingw-w64-ucrt-x86_64-gcc 16.2.0-3') -Prefix 'mingw-w64-clang-x86_64'
Check "size 0 is an EMPTY ARRAY"                  (($s0 -is [System.Array]) -and ($s0.Count -eq 0))
$ws = @(Select-DrivEnvToolchainPackages -Lines $q -Prefix 'mingw-w64-clang-x86_64')
Check "wrapping in @() NESTS"                     (($ws.Count -eq 1) -and ($ws[0] -is [System.Array]))

Write-Host "=== 26. TRIPLETS: per package, and per toolchain ==="
Check "an override wins, trimmed"     ((Get-DrivEnvPackageTriplet -Package (Obj '{"name":"zlib","triplet":" x64-mingw-ucrt-static-release "}') -Default 'd') -ceq 'x64-mingw-ucrt-static-release')
Check "absent: the default"           ((Get-DrivEnvPackageTriplet -Package (Obj '{"name":"zlib"}') -Default 'd') -ceq 'd')
Check "blank: the default"            ((Get-DrivEnvPackageTriplet -Package (Obj '{"name":"zlib","triplet":"  "}') -Default 'd') -ceq 'd')
$tt0 = Get-DrivEnvToolchainTriplets -Cfg (Obj '{}')
Check "size 0 is an EMPTY ARRAY"      (($tt0 -is [System.Array]) -and ($tt0.Count -eq 0))
$tt1 = Get-DrivEnvToolchainTriplets -Cfg $rc
Check "size 1 stays an array"         (($tt1 -is [System.Array]) -and ($tt1.Count -eq 1) -and ($tt1[0] -ceq 'x64-mingw-clang-dynamic-release'))
$c = Clone $rc
Add-Member -InputObject $c.vcpkg.packages[0] -MemberType NoteProperty -Name 'triplet' -Value 'x64-mingw-ucrt-static-release'
Add-Member -InputObject $c.vcpkg.packages[1] -MemberType NoteProperty -Name 'triplet' -Value 'X64-MINGW-CLANG-DYNAMIC-RELEASE'
$tt2 = Get-DrivEnvToolchainTriplets -Cfg $c
Check "size 2: main first, an override after, a case-only repeat dropped" ((Joined $tt2) -ceq 'x64-mingw-clang-dynamic-release|x64-mingw-ucrt-static-release')
$wt = @(Get-DrivEnvToolchainTriplets -Cfg $rc)
Check "wrapping in @() NESTS"         (($wt.Count -eq 1) -and ($wt[0] -is [System.Array]))

Write-Host "=== 27. ConvertFrom-DrivEnvVcpkgListJson: keyed by name AND triplet ==="
$e = ConvertFrom-DrivEnvVcpkgListJson -Text '{}'
Check "'{}' is an EMPTY table, never null" (($e -is [hashtable]) -and ($e.Count -eq 0))
$j = '{"zlib:x64-mingw-clang-dynamic-release":{"package_name":"zlib","triplet":"x64-mingw-clang-dynamic-release","version":"1.3.1","port_version":0,"features":[]},' +
     '"zlib:x64-mingw-ucrt-dynamic-release":{"package_name":"zlib","triplet":"x64-mingw-ucrt-dynamic-release","version":"1.3.1","port_version":2,"features":["core"]}}'
$v = ConvertFrom-DrivEnvVcpkgListJson -Text $j
Check "one port, two triplets, two entries"    (($v.Count -eq 2) -and $v.ContainsKey('zlib:x64-mingw-clang-dynamic-release') -and $v.ContainsKey('zlib:x64-mingw-ucrt-dynamic-release'))
Check "a name alone is not a key"              (-not $v.ContainsKey('zlib'))
Check "port_version 0 adds nothing"            ($v['zlib:x64-mingw-clang-dynamic-release'].Version -ceq '1.3.1')
Check "port_version 2 adds '#2'"               ($v['zlib:x64-mingw-ucrt-dynamic-release'].Version -ceq '1.3.1#2')
Check "fields carried"                         (($v['zlib:x64-mingw-ucrt-dynamic-release'].Name -ceq 'zlib') -and ($v['zlib:x64-mingw-ucrt-dynamic-release'].Triplet -ceq 'x64-mingw-ucrt-dynamic-release'))
Check "features stay arrays at sizes 0 and 1"  (($v['zlib:x64-mingw-clang-dynamic-release'].Features -is [System.Array]) -and ($v['zlib:x64-mingw-clang-dynamic-release'].Features.Count -eq 0) -and
                                                ($v['zlib:x64-mingw-ucrt-dynamic-release'].Features -is [System.Array]) -and ($v['zlib:x64-mingw-ucrt-dynamic-release'].Features[0] -ceq 'core'))
Check "invalid JSON throws"                    (Throws { ConvertFrom-DrivEnvVcpkgListJson -Text 'not json' })
Check "no output throws"                       (Throws { ConvertFrom-DrivEnvVcpkgListJson -Text '' })

Write-Host "=== 27b. Get-DrivEnvPackageCheck: step 5's verdict, keyed by name AND triplet ==="
# FOUND BY REVIEW. This decision was inline in step 5, out of the tests' reach, and it is the one that used to pass a
# package installed only for the OTHER toolchain.
$clangT = 'x64-mingw-clang-dynamic-release'
$onlyUcrt = ConvertFrom-DrivEnvVcpkgListJson -Text ('{"zlib:x64-mingw-ucrt-dynamic-release":{"package_name":"zlib","triplet":"x64-mingw-ucrt-dynamic-release","version":"1.3.1","port_version":0,"features":[]},' +
                                                    '"fmt:x64-mingw-clang-dynamic-release":{"package_name":"fmt","triplet":"x64-mingw-clang-dynamic-release","version":"12.2.0","port_version":1,"features":[]},' +
                                                    '"zstd:x64-mingw-static":{"package_name":"zstd","triplet":"x64-mingw-static","version":"1.5.7","port_version":0,"features":[]}}')
$pc = Get-DrivEnvPackageCheck -Listed $onlyUcrt -Package (Obj '{"name":"zlib"}') -DefaultTriplet $clangT
Check "installed only for ucrt: FAILS for clang, naming where it is" (($pc.State -ceq 'fail') -and ($pc.Name -ceq 'zlib') -and ($pc.Detail -ceq "not installed for $clangT (installed for: x64-mingw-ucrt-dynamic-release)")) ("-> " + $pc.Detail)
$pc = Get-DrivEnvPackageCheck -Listed $onlyUcrt -Package (Obj '{"name":"fmt"}') -DefaultTriplet $clangT
Check "installed for its triplet: ok, with the version" (($pc.State -ceq 'ok') -and ($pc.Detail -ceq '12.2.0#1'))
$pc = Get-DrivEnvPackageCheck -Listed $onlyUcrt -Package (Obj '{"name":"zstd","triplet":"x64-mingw-static"}') -DefaultTriplet $clangT
Check "an override is looked up under its own triplet, and shown with it" (($pc.State -ceq 'ok') -and ($pc.Name -ceq 'zstd:x64-mingw-static'))
$pc = Get-DrivEnvPackageCheck -Listed $onlyUcrt -Package (Obj '{"name":"zstd"}') -DefaultTriplet $clangT
Check "...and without the override, not found under the default" ($pc.State -ceq 'fail')
$pc = Get-DrivEnvPackageCheck -Listed (ConvertFrom-DrivEnvVcpkgListJson -Text '{}') -Package (Obj '{"name":"fmt"}') -DefaultTriplet $clangT
Check "an empty tree: every package FAILS, nothing is skipped" (($pc.State -ceq 'fail') -and ($pc.Detail -ceq "not installed for $clangT"))
Check "an entry with no name: no verdict"       ($null -eq (Get-DrivEnvPackageCheck -Listed $onlyUcrt -Package (Obj '{"name":" "}') -DefaultTriplet $clangT))
Check "a JSON array throws"                    (Throws { ConvertFrom-DrivEnvVcpkgListJson -Text '[1,2]' })

Write-Host "=== 28. Get-DrivEnvBuildtreeCleanupPlan ==="
$TC = 'x64-mingw-clang-dynamic-release'
$TU = 'x64-mingw-ucrt-dynamic-release'
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('build') -FileNames @('CMakeCache.txt') -OwnTriplets @($TC) -LastToolchain $true -Mode 'all'
Check "no stamp (a user project): never a candidate, even last and 'all'" (-not $p.Candidate)
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('src') -FileNames @('vcpkg_abi_info.txt') -OwnTriplets @($TC) -LastToolchain $true -Mode 'all'
Check "the stamp is '<triplet>.vcpkg_abi_info.txt' exactly"           (-not $p.Candidate)
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('src', "$TC-rel", "$TC-dbg", "$TU-rel") -FileNames @("$TC.vcpkg_abi_info.txt", "$TU.vcpkg_abi_info.txt", "install-$TC-rel-out.log") -OwnTriplets @($TC) -LastToolchain $false -Mode 'all'
Check "not last: only its own trees; src and the other's stay, even in 'all'" ($p.Candidate -and (-not $p.RemoveWhole) -and ((Joined ($p.RemoveDirs | Sort-Object)) -ceq "$TC-dbg|$TC-rel"))
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('src', "$TU-rel") -FileNames @("$TU.vcpkg_abi_info.txt") -OwnTriplets @($TC) -LastToolchain $false -Mode 'logs'
Check "not last: a port only another toolchain stamped is left alone"  (-not $p.Candidate)
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('src', "$TC-rel", "$TU-rel") -FileNames @("$TC.vcpkg_abi_info.txt", "$TU.vcpkg_abi_info.txt") -OwnTriplets @($TU) -LastToolchain $true -Mode 'all'
Check "last, another's tree remains: only its own"                    ($p.Candidate -and (-not $p.RemoveWhole) -and ((Joined $p.RemoveDirs) -ceq "$TU-rel"))
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('src', "$TU-rel") -FileNames @("$TC.vcpkg_abi_info.txt", "$TU.vcpkg_abi_info.txt") -OwnTriplets @($TU) -LastToolchain $true -Mode 'all'
Check "last, nothing else remains, 'all': the whole directory"        ($p.Candidate -and $p.RemoveWhole)
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('src', "$TU-rel") -FileNames @("$TU.vcpkg_abi_info.txt", 'config-x.log') -OwnTriplets @($TU) -LastToolchain $true -Mode 'logs'
Check "last, nothing else remains, 'logs': every subdirectory, files kept" ($p.Candidate -and (-not $p.RemoveWhole) -and ((Joined $p.RemoveDirs) -ceq "src|$TU-rel"))
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('src', "$TC-rel", 'x64-mingw-ucrt-static-release-rel') -FileNames @("$TC.vcpkg_abi_info.txt", 'x64-mingw-ucrt-static-release.vcpkg_abi_info.txt') -OwnTriplets @($TC, 'x64-mingw-ucrt-static-release') -LastToolchain $true -Mode 'logs'
Check "2.x with an override: both triplets are its own, today's behaviour" ($p.Candidate -and ((Joined $p.RemoveDirs) -ceq "src|$TC-rel|x64-mingw-ucrt-static-release-rel"))
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('x64-mingw-dynamic-rel', 'x64-mingw-dynamic-release-rel') -FileNames @('x64-mingw-dynamic.vcpkg_abi_info.txt', 'x64-mingw-dynamic-release.vcpkg_abi_info.txt') -OwnTriplets @('x64-mingw-dynamic') -LastToolchain $false -Mode 'all'
Check "exact names: a triplet that prefixes another never takes its tree" ((Joined $p.RemoveDirs) -ceq 'x64-mingw-dynamic-rel')
Check "RemoveDirs is an array even with one entry" ($p.RemoveDirs -is [System.Array])

Write-Host "=== 29. TOOLCHAIN SCOPE ==="
Check "under"                                  (Test-DrivEnvPathUnder -Path 'N:\msys64\clang64\bin\clang.exe' -Root 'N:/msys64/clang64')
Check "case and slashes do not matter"         (Test-DrivEnvPathUnder -Path 'n:/MSYS64/Clang64/bin/a.exe' -Root 'N:\msys64\clang64\')
Check "a sibling sharing the prefix is not"    (-not (Test-DrivEnvPathUnder -Path 'N:\msys64\clang64x\bin\a.exe' -Root 'N:\msys64\clang64'))
Check "the root itself is not under itself"    (-not (Test-DrivEnvPathUnder -Path 'N:\msys64\clang64' -Root 'N:\msys64\clang64'))
Check "blank and malformed are under nothing"  ((-not (Test-DrivEnvPathUnder -Path '' -Root 'N:\')) -and (-not (Test-DrivEnvPathUnder -Path 'N:\a|b' -Root 'N:\')))

$scope = @{
    ToolchainRoot  = 'N:/msys64/clang64'
    InstalledRoots = @('N:/vcpkg/installed/x64-mingw-clang-dynamic-release', 'N:/vcpkg/installed/x64-mingw-ucrt-static-release')
    VcpkgRoot      = 'N:/vcpkg'
    DriveLetter    = 'N'
    ToolchainKey   = 'clang64'
}
Check "its own prefix: allowed"                ((Get-DrivEnvToolchainScopeViolation -Source 'N:\msys64\clang64\bin\clang.exe' @scope) -ceq '')
Check "its own installed tree: allowed"        ((Get-DrivEnvToolchainScopeViolation -Source 'N:\vcpkg\installed\x64-mingw-clang-dynamic-release\tools\x.exe' @scope) -ceq '')
Check "an override's tree: allowed"            ((Get-DrivEnvToolchainScopeViolation -Source 'N:\vcpkg\installed\x64-mingw-ucrt-static-release\bin\z.exe' @scope) -ceq '')
Check "vcpkg.exe itself: allowed"              ((Get-DrivEnvToolchainScopeViolation -Source 'N:\vcpkg\vcpkg.exe' @scope) -ceq '')
Check "another triplet under vcpkg: refused"   ((Get-DrivEnvToolchainScopeViolation -Source 'N:\vcpkg\installed\x64-mingw-ucrt-dynamic-release\bin\x.exe' @scope) -like '*outside toolchain clang64*')
Check "the other subsystem: on the drive, outside the toolchain" ((Get-DrivEnvToolchainScopeViolation -Source 'N:\msys64\ucrt64\bin\gcc.exe' @scope) -ceq 'found at N:\msys64\ucrt64\bin\gcc.exe, which is on N: but outside toolchain clang64')
Check "off the drive: outside the drive"       ((Get-DrivEnvToolchainScopeViolation -Source 'C:\Program Files\Git\mingw64\bin\curl.exe' @scope) -ceq 'found at C:\Program Files\Git\mingw64\bin\curl.exe, which is outside N:')
Check "nothing resolved: refused"              ((Get-DrivEnvToolchainScopeViolation -Source '' @scope) -ne '')

Write-Host "=== 30. Install-DrivEnvLauncherSet (in a temporary directory) ==="
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-test-" + [guid]::NewGuid().ToString('N'))
try
{
    $tpl = Join-Path $tmp 'templates'
    New-Item -ItemType Directory -Path $tpl -Force | Out-Null
    foreach ($n in @('env_launcher.bat', 'env_launcher_bootstrap.sh', 'qtcreator_launcher.bat', 'README.txt')) { Set-Content -LiteralPath (Join-Path $tpl $n) -Value $n }

    $names = @{ Stem = 'degorasslr_clang64'; LauncherDir = (Join-Path $tmp 'launcher') }
    $script:reported = @()
    Install-DrivEnvLauncherSet -TemplateDir $tpl -Names $names -Report { param($m) $script:reported += $m }
    $deployed = @(Get-ChildItem -LiteralPath $names.LauncherDir -File | ForEach-Object { $_.Name } | Sort-Object)
    Check "every env_launcher .bat and .sh as <Stem>_<template>; not Qt Creator's, nothing else" ((Joined $deployed) -ceq 'degorasslr_clang64_env_launcher.bat|degorasslr_clang64_env_launcher_bootstrap.sh')
    Check "the content is the template's"         ((Get-Content -LiteralPath (Join-Path $names.LauncherDir 'degorasslr_clang64_env_launcher.bat')) -ceq 'env_launcher.bat')
    Check "reported once per file"                ($script:reported.Count -eq 2)

    $empty = Join-Path $tmp 'empty'
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    Check "no template: throws"                   (Throws { Install-DrivEnvLauncherSet -TemplateDir $empty -Names $names })
    Check "no template directory: throws"         (Throws { Install-DrivEnvLauncherSet -TemplateDir (Join-Path $tmp 'missing') -Names $names })
    Check "no names: throws"                      (Throws { Install-DrivEnvLauncherSet -TemplateDir $tpl -Names $null })

    # The real templates, deployed under the real names table: the Launcher it names must be a file the set produced.
    $real = $nc.Clone(); $real['LauncherDir'] = Join-Path $tmp 'real'
    Install-DrivEnvLauncherSet -TemplateDir (Join-Path $root 'drive\launchers') -Names $real
    Check "the real set produces the Launcher the names table points at" `
        (Test-Path -LiteralPath (Join-Path $real['LauncherDir'] ([System.IO.Path]::GetFileName($nc.Launcher))))
    # Qt Creator belongs to the drive, not to a toolchain: no Qt Creator launcher per toolchain.
    Check "the real set deploys no Qt Creator launcher"   (@(Get-ChildItem -LiteralPath $real['LauncherDir'] -File -Filter '*qtcreator*').Count -eq 0)
    # FOUND BY REVIEW. Everything the .bat names from its stem must be deployed beside it under that stem.
    Check "...and every file the .bat names from its stem" `
        ((Test-Path -LiteralPath (Join-Path $real['LauncherDir'] ($nc.Stem + '_env_launcher_bootstrap.sh'))) -and
         (Test-Path -LiteralPath (Join-Path $real['LauncherDir'] ($nc.Stem + '_env_launcher_bashrc.sh'))))
}
finally
{
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "=== 31. VALIDATOR: the toolchain key, triplets, folder tokens, the workspace ==="
$c = Clone $dual; $c.toolchains.clang.msys2.target.subsystem = 'clang 64'
Check "a key with a space is refused, prefix and subpath notwithstanding" (HasProblem $c "the toolchain key 'clang 64'")
$c = Load $base; $c.msys2.target.subsystem = 'ucrt/64'
Check "the key rule holds for a 2.x configuration too"   (HasProblem $c "the toolchain key 'ucrt/64'")
$c = Load $base; $c.msys2.target.PSObject.Properties.Remove('subsystem'); Add-Member -InputObject $c.msys2.target -MemberType NoteProperty -Name 'profile' -Value ' ucrt '
Check "a padded legacy profile validates (key 'ucrt64', not 'ucrt 64')" ((Test-DrivEnvConfig -Config $c).Count -eq 0) ("-> " + ((Test-DrivEnvConfig -Config $c) -join ' | '))
$c = Load $base; $c.msys2.target.subsystem = ' UCRT64 '
Check "case and padding are the key's business, not an error" (-not (HasProblem $c 'the toolchain key'))
$c = Load $base; $c.msys2.target = @($c.msys2.target)
$arr = @(Test-DrivEnvConfig -Config $c)
Check "a target written as an array: the type error, and no second message about its key" `
    ((@($arr | Where-Object { $_ -like 'msys2.target: expected object*' }).Count -eq 1) -and (@($arr | Where-Object { $_ -like '*toolchain key*' }).Count -eq 0)) ("-> " + ($arr -join ' | '))

$c = Clone $dual; $c.toolchains.ucrt.vcpkg.target.triplet = 'x64 mingw'
Check "a triplet with a space is refused"                 (HasProblem $c "vcpkg.target.triplet: 'x64 mingw' must start with a letter or digit")
$c = Load $base; $c.vcpkg.target.triplet = 'x64/mingw'
Check "...in a 2.x configuration too"                     (HasProblem $c "vcpkg.target.triplet: 'x64/mingw' must start with a letter or digit")
$c = Load $base; Add-Member -InputObject $c.vcpkg.packages[0] -MemberType NoteProperty -Name 'triplet' -Value 'bad triplet'
# No '[0]' in a needle: HasProblem matches with -like, where brackets are a character class.
Check "a per-package override is held to the same rule"   (HasProblem $c ".triplet: 'bad triplet' must start with a letter or digit")

# FOUND BY REVIEW. '.' and '..' are made of allowed characters, and '..' as a triplet makes DEVSYSTEM_BUILDTREES the
# drive root. A triplet must start with a letter or digit, as the toolchain key must.
foreach ($bad in @('..', '.', '.x64'))
{
    $c = Load $base; $c.vcpkg.target.triplet = $bad
    Check "triplet '$bad' is refused"                     (HasProblem $c "vcpkg.target.triplet: '$bad' must start with a letter or digit")
}
$c = Load $base; Add-Member -InputObject $c.vcpkg.packages[0] -MemberType NoteProperty -Name 'triplet' -Value '..'
Check "...and as a per-package override"                  (HasProblem $c ".triplet: '..' must start with a letter or digit")

# FOUND BY REVIEW. A field of the wrong type gets the type walk's message, and no second one about a value nobody wrote.
$c = Load $base; $c.msys2.target.subsystem = @('clang64', 'ucrt64')
$arr = @(Test-DrivEnvConfig -Config $c)
Check "a subsystem written as an array: the type error, nothing about a key" `
    ((@($arr | Where-Object { $_ -like 'msys2.target.subsystem: expected*' }).Count -eq 1) -and (@($arr | Where-Object { $_ -like '*toolchain key*' }).Count -eq 0)) ("-> " + ($arr -join ' | '))
$c = Load $base; $c.msys2.target.subsystem = (Obj '{"a":1}')
$arr = @(Test-DrivEnvConfig -Config $c)
Check "...written as an object, the same"                 ((@($arr | Where-Object { $_ -like 'msys2.target.subsystem: expected*' }).Count -eq 1) -and (@($arr | Where-Object { $_ -like '*toolchain key*' }).Count -eq 0)) ("-> " + ($arr -join ' | '))
$c = Load $base; $c.vcpkg.target.triplet = @('a', 'b')
$arr = @(Test-DrivEnvConfig -Config $c)
Check "a triplet written as an array: the type error only" `
    ((@($arr | Where-Object { $_ -like 'vcpkg.target.triplet: expected*' }).Count -eq 1) -and (@($arr | Where-Object { $_ -like '*must start with a letter or digit*' }).Count -eq 0)) ("-> " + ($arr -join ' | '))

$c = Load $base; $c.environment.custom_folders = @('logs/gstreamer/${DEVSYSTEM_TOOLCHAIN_ID}/dot')
Check "custom_folders may carry the toolchain token"      ((Test-DrivEnvConfig -Config $c).Count -eq 0) ("-> " + ((Test-DrivEnvConfig -Config $c) -join ' | '))
$c = Load $base; $c.environment.custom_folders = @('logs/${DEVDRIVE_LETTER}/dot')
Check "...and no other variable"                          (HasProblem $c 'may carry no variable but ${DEVSYSTEM_TOOLCHAIN_ID}')
$c = Load $base; $c.environment.custom_folders = @('logs/${devsystem_toolchain_id}')
Check "the token is case-sensitive, as bash is"           (HasProblem $c 'may carry no variable but')
$c = Load $base; $c.environment.custom_folders = @('logs/a|b')
Check "an illegal path character does not crash the validator" (-not (Throws { Test-DrivEnvConfig -Config $c }))
$c = Load $base; $c.environment.custom_folders = @('/logs')
Check "a rooted custom folder is still refused"           (HasProblem $c "'/logs' must be relative to the drive root")
# FOUND BY REVIEW. A custom folder is checked as it will be used, trimmed and with forward slashes, because
# Get-DrivEnvCustomFolders trims and does not check again. Untrimmed, ' C:/logs' passed as relative.
$c = Load $base; $c.environment.custom_folders = @(' C:/logs')
Check "a padded drive letter is refused"                  (HasProblem $c "' C:/logs' must be relative to the drive root")
$c = Load $base; $c.environment.custom_folders = @(' C:/x/${DEVSYSTEM_TOOLCHAIN_ID}')
Check "...with the toolchain token too"                   (HasProblem $c 'must be relative to the drive root')
$c = Load $base; $c.environment.custom_folders = @('logs\..\x')
Check "'..' between backslashes is refused"               (HasProblem $c "must not contain '..'")

$c = Load $base; $c.workspace.default_folder = 'C:/ws'
Check "workspace.default_folder: a drive letter is refused" (HasProblem $c "workspace.default_folder: 'C:/ws' must be relative")
$c = Load $base; $c.workspace.default_folder = '/ws'
Check "...a leading slash too"                            (HasProblem $c "workspace.default_folder: '/ws' must be relative")
$c = Load $base; $c.workspace.default_folder = 'a/../b'
Check "...and '..'"                                       (HasProblem $c "workspace.default_folder: 'a/../b' must not contain '..'")

# FOUND BY REVIEW. msys packages land in the one /usr every toolchain shares; pinned differently by two toolchains,
# the package is whatever was built last, under the one IgnorePkg name both share.
function MsysPkg { param([string]$Mode, [string]$Version = '') if ($Version) { Obj ('{"name":"diffutils","repo":"msys","mode":"' + $Mode + '","version":"' + $Version + '"}') } else { Obj ('{"name":"diffutils","repo":"msys","mode":"' + $Mode + '"}') } }
$c = Clone $dual
$c.toolchains.clang.msys2.packages = @($c.toolchains.clang.msys2.packages) + @(MsysPkg 'pinned' '3.10-1')
$c.toolchains.ucrt.msys2.packages  = @($c.toolchains.ucrt.msys2.packages)  + @(MsysPkg 'pinned' '3.12-1')
Check "an msys package pinned differently by two toolchains is refused" (HasProblem $c "'diffutils' from repo 'msys' is 'pinned 3.12-1' here and 'pinned 3.10-1' in toolchain 'clang'")
$c = Clone $dual
$c.toolchains.clang.msys2.packages = @($c.toolchains.clang.msys2.packages) + @(MsysPkg 'pinned' '3.10-1')
$c.toolchains.ucrt.msys2.packages  = @($c.toolchains.ucrt.msys2.packages)  + @(MsysPkg 'latest')
Check "...and pinned by one, 'latest' in the other"       (HasProblem $c "'diffutils' from repo 'msys' is 'latest' here")
$c = Clone $dual
$c.toolchains.clang.msys2.packages = @($c.toolchains.clang.msys2.packages) + @(MsysPkg 'pinned' '3.10-1')
$c.toolchains.ucrt.msys2.packages  = @($c.toolchains.ucrt.msys2.packages)  + @(MsysPkg 'pinned' '3.10-1')
Check "...the same pin in both is fine"                   (-not (HasProblem $c "from repo 'msys' is"))
$c = Clone $dual; $c.generate = @('ucrt')
$c.toolchains.clang.msys2.packages = @($c.toolchains.clang.msys2.packages) + @(MsysPkg 'pinned' '3.10-1')
$c.toolchains.ucrt.msys2.packages  = @($c.toolchains.ucrt.msys2.packages)  + @(MsysPkg 'pinned' '3.12-1')
Check "...and a declared toolchain counts even when not generated" (HasProblem $c "from repo 'msys' is")

# FOUND BY REVIEW. vcpkg.packages is shared, so an override names one installed tree for every toolchain: the second
# toolchain's step 4 found the first one's build "already installed", and its step 5 passed it.
$c = Clone $dual; Add-Member -InputObject $c.vcpkg.packages[0] -MemberType NoteProperty -Name 'triplet' -Value 'x64-mingw-static'
Check "a per-package override in a dual configuration is refused" (HasProblem $c "is a per-package override, refused in a configuration declaring more than one toolchain")
$c = Clone $dual; $c.generate = @('clang'); Add-Member -InputObject $c.vcpkg.packages[0] -MemberType NoteProperty -Name 'triplet' -Value 'x64-mingw-static'
Check "...also when only one of them is generated today"  (HasProblem $c "is a per-package override, refused")
$c = Load $base; Add-Member -InputObject $c.vcpkg.packages[0] -MemberType NoteProperty -Name 'triplet' -Value 'x64-mingw-static'
Check "...and still allowed with one toolchain"           ((Test-DrivEnvConfig -Config $c).Count -eq 0) ("-> " + ((Test-DrivEnvConfig -Config $c) -join ' | '))

Write-Host "=== 32. env_launcher.bat ITSELF: run through cmd, stopped before it launches anything ==="
# FOUND BY REVIEW. Section 18 holds the names table to the rule; this holds the .bat to it, by running it. Every case
# below refuses before the final `start`: the last one gets as far as reading its env file, which names an MSYS2
# root holding no msys2_shell.cmd. DEV_ENV_NO_PAUSE keeps its refusals from waiting for a key.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-bat-" + [guid]::NewGuid().ToString('N') + " with space!")
$env:DEV_ENV_NO_PAUSE = '1'
try
{
    function RunBat { param([string]$Bat) $ErrorActionPreference = 'Continue'; $o = & cmd.exe /d /c ('"' + $Bat + '"') 2>&1 | ForEach-Object { "$_" }; return @{ Out = ($o -join "`n"); Code = $LASTEXITCODE } }

    $launcherDir = Join-Path $tmp 'env\launcher'
    New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
    $tplBat = Join-Path $root 'drive\launchers\env_launcher.bat'

    $bat = Join-Path $launcherDir 'launcher.bat'; Copy-Item -LiteralPath $tplBat -Destination $bat
    $r = RunBat $bat
    Check "a launcher not named <stem>_env_launcher.bat refuses" (($r.Code -eq 1) -and ($r.Out -match 'must be named')) ("-> " + $r.Out)

    $bat = Join-Path $launcherDir 'abc_clang64_env_launcher.bat'; Copy-Item -LiteralPath $tplBat -Destination $bat
    $r = RunBat $bat
    Check "no env file: refuses, naming <stem>_env_variables.env one directory up" `
        (($r.Code -eq 1) -and $r.Out.Contains((Join-Path $tmp 'env\abc_clang64_env_variables.env'))) ("-> " + $r.Out)

    $fakeMsys = Join-Path $tmp 'nomsys'
    New-Item -ItemType Directory -Path $fakeMsys -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $tmp 'env\abc_clang64_env_variables.env'), "DEVSYSTEM_NAME=T`nMSYS2_ROOT=$($fakeMsys -replace '\\', '/')`nMSYS2_ENV=clang64`n")
    [System.IO.File]::WriteAllText((Join-Path $tmp 'env\abc_ucrt64_env_variables.env'), "DEVSYSTEM_NAME=decoy`nMSYS2_ROOT=X:/decoy`nMSYS2_ENV=ucrt64`n")
    $r = RunBat $bat
    Check "no bootstrap: refuses, naming <stem>_env_launcher_bootstrap.sh beside it" `
        (($r.Code -eq 1) -and $r.Out.Contains((Join-Path $launcherDir 'abc_clang64_env_launcher_bootstrap.sh'))) ("-> " + $r.Out)

    Set-Content -LiteralPath (Join-Path $launcherDir 'abc_clang64_env_launcher_bootstrap.sh') -Value 'x'
    $r = RunBat $bat
    Check "its OWN env file is read -- the MSYS2 root it names, not the decoy's -- in a path with a space and a '!'" `
        (($r.Code -eq 1) -and $r.Out.Contains((Join-Path $fakeMsys 'msys2_shell.cmd')) -and ($r.Out -notmatch 'decoy')) ("-> " + $r.Out)
}
finally
{
    Remove-Item Env:DEV_ENV_NO_PAUSE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "=== 33. env_launcher_bootstrap.sh ITSELF, under a bash ==="
# The bootstrap's choice of env file and its refusals, run for real with DRIVENV_TEST_BASH, MSYS2's or Git's
# usr\bin\bash.exe (never bin\bash.exe, which forces MSYSTEM, nor the PATH bash, usually WSL's). Skipped without one.
$testBash = $null
$candidates = @($env:DRIVENV_TEST_BASH, 'C:\msys64\usr\bin\bash.exe')
$gitExe = Get-Command git.exe -ErrorAction SilentlyContinue
# FOUND BY REVIEW: git.exe is <Git>\cmd\git.exe from a Windows shell but <Git>\mingw64\bin\git.exe from Git Bash, so
# the Git root is looked for upward from wherever it resolved, not at a fixed depth.
if ($gitExe)
{
    $up = Split-Path -Parent $gitExe.Source
    for ($i = 0; ($i -lt 4) -and $up; $i++) { $candidates += (Join-Path $up 'usr\bin\bash.exe'); $up = Split-Path -Parent $up }
}
foreach ($cand in $candidates) { if ($cand -and (Test-Path -LiteralPath $cand)) { $testBash = $cand; break } }

if (-not $testBash)
{
    $script:skip++; Write-Host "  SKIP  no MSYS2 or Git bash found (set DRIVENV_TEST_BASH); the bootstrap cases did not run"
}
else
{
    Write-Host "  (bash: $testBash)"
    function PosixOf { param([string]$P) $p = $P -replace '\\', '/'; return ('/' + $p.Substring(0, 1).ToLowerInvariant() + $p.Substring(2)) }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-boot-" + [guid]::NewGuid().ToString('N'))
    try
    {
        New-Item -ItemType Directory -Path (Join-Path $tmp 'env\launcher') -Force | Out-Null
        $boot = Join-Path $tmp 'env\launcher\abc_clang64_env_launcher_bootstrap.sh'
        Copy-Item -LiteralPath (Join-Path $root 'drive\launchers\env_launcher_bootstrap.sh') -Destination $boot
        $drive = $tmp -replace '\\', '/'
        $common = "DEVDRIVE_LETTER=$drive`nDEVSYSTEM_NAME=T`nBASE_PATH=/usr/bin`nPATH=`${BASE_PATH}`n"
        [System.IO.File]::WriteAllText((Join-Path $tmp 'env\abc_clang64_env_variables.env'), $common + "DEVSYSTEM_TOOLCHAIN_ID=clang64`nMSYS2_ENV=clang64`nMARKER=clang-file`n")
        [System.IO.File]::WriteAllText((Join-Path $tmp 'env\abc_ucrt64_env_variables.env'),  $common + "DEVSYSTEM_TOOLCHAIN_ID=ucrt64`nMSYS2_ENV=ucrt64`nMARKER=decoy`n")
        [System.IO.File]::WriteAllText((Join-Path $tmp 'env\noid_env_variables.env'),         $common + "MSYS2_ENV=clang64`nMARKER=noid`n")
        $runner = Join-Path $tmp 'runner.sh'
        # /usr/bin first, as the launcher's login shell has it: run directly, this bash has no dirname to call.
        [System.IO.File]::WriteAllText($runner, 'export PATH="/usr/bin:$PATH"' + "`n" + '. "$PROBE_BOOT"' + "`n")

        function RunBoot
        {
            param([string]$Msystem, [string]$EnvFile, [string]$Boot)
            $ErrorActionPreference = 'Continue'
            $env:MSYSTEM = $Msystem; $env:DEV_ENV_NO_PAUSE = '1'; $env:PROBE_BOOT = (PosixOf $Boot)
            if ($EnvFile) { $env:DP_ENVFILE = $EnvFile } else { Remove-Item Env:DP_ENVFILE -ErrorAction SilentlyContinue }
            $o = & $testBash -c (". " + (PosixOf $runner)) 2>&1 | ForEach-Object { "$_" }
            Remove-Item Env:DP_ENVFILE, Env:MSYSTEM, Env:PROBE_BOOT, Env:DEV_ENV_NO_PAUSE -ErrorAction SilentlyContinue
            return ($o -join "`n")
        }

        $o = RunBoot 'CLANG64' (PosixOf (Join-Path $tmp 'env\abc_clang64_env_variables.env')) $boot
        Check "DP_ENVFILE: that file is loaded, the other toolchain's beside it is not" (($o -match '\[ENV\] MARKER=clang-file') -and ($o -notmatch 'decoy')) ("-> " + $o)
        $o = RunBoot 'CLANG64' '' $boot
        Check "no DP_ENVFILE: the bootstrap's own name picks the file" (($o -match '\[ENV\] MARKER=clang-file') -and ($o -notmatch 'decoy')) ("-> " + $o)
        $o = RunBoot 'UCRT64' (PosixOf (Join-Path $tmp 'env\abc_clang64_env_variables.env')) $boot
        Check "a UCRT64 shell refuses clang's env file" ($o -match 'This shell is UCRT64, but the env file is for CLANG64') ("-> " + $o)
        $o = RunBoot 'CLANG64' (PosixOf (Join-Path $tmp 'env\noid_env_variables.env')) $boot
        Check "an env file without DEVSYSTEM_TOOLCHAIN_ID is refused" ($o -match 'DEVSYSTEM_TOOLCHAIN_ID not set') ("-> " + $o)
        $odd = Join-Path $tmp 'env\launcher\odd.sh'; Copy-Item -LiteralPath $boot -Destination $odd
        $o = RunBoot 'CLANG64' '' $odd
        Check "no DP_ENVFILE and no recognisable name: refused" ($o -match 'Cannot tell which environment to load') ("-> " + $o)
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "=== 34. Save-VcpkgFailureLogs -Since: only what the attempt wrote ==="
# FOUND BY REVIEW. A port's directory keeps the logs of every earlier run and of the other triplet.
. (Join-Path $root 'scripts\DrivEnvLogs.ps1')
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-logs-" + [guid]::NewGuid().ToString('N'))
try
{
    $bt = Join-Path $tmp 'bt'
    New-Item -ItemType Directory -Path (Join-Path $bt 'qtbase') -Force | Out-Null
    $old = Join-Path $bt 'qtbase\build-x64-mingw-ucrt-dynamic-release-rel-err.log'
    Set-Content -LiteralPath $old -Value 'old'
    (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-3)
    $since = (Get-Date).AddSeconds(-2)
    Set-Content -LiteralPath (Join-Path $bt 'qtbase\build-x64-mingw-clang-dynamic-release-rel-err.log') -Value 'new'

    # The log root is the drive's; a function of the same name in this child scope points it at the temporary tree.
    $saved = & {
        function Get-DrivEnvLogRoot { param($DriveLetter) return (Join-Path $tmp 'logs') }
        $a = Save-VcpkgFailureLogs -PortName 'qtbase' -Attempt 1 -BuildtreesRoot $bt -DriveLetter 'Z' -Since $since
        $b = Save-VcpkgFailureLogs -PortName 'qtbase' -Attempt 2 -BuildtreesRoot $bt -DriveLetter 'Z'
        @{ A = $a; B = $b }
    }
    Check "-Since: the attempt's own log only" ((Joined (@(Get-ChildItem -LiteralPath $saved.A -File | ForEach-Object { $_.Name }))) -ceq 'build-x64-mingw-clang-dynamic-release-rel-err.log')
    Check "no -Since: every log, as before"      (@(Get-ChildItem -LiteralPath $saved.B -File).Count -eq 2)
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "=== 35. DEVSYSTEM_BUILDTREES: written by step 3, after the triplet it expands ==="
# FOUND BY REVIEW. Its value refers to ${VCPKG_DEFAULT_TRIPLET}, and both expanders read the file once, top to bottom.
$step3 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\3-Clone_VCPKG.ps1'), [ref]$null, [ref]$null)
$assign = $step3.FindAll({ param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
                                     ($n.Left.Extent.Text -eq '$vcpkgEnvValues') }, $true) | Select-Object -First 1
$hash = if ($assign) { $assign.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) | Select-Object -First 1 } else { $null }
$keys = if ($hash) { @($hash.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text.Trim('"', "'") }) } else { @() }
$bi = [array]::IndexOf($keys, 'DEVSYSTEM_BUILDTREES'); $ti = [array]::IndexOf($keys, 'VCPKG_DEFAULT_TRIPLET')
Check "step 3's vcpkg section holds it, after VCPKG_DEFAULT_TRIPLET" (($bi -ge 0) -and ($ti -ge 0) -and ($bi -gt $ti)) ("-> " + ($keys -join ','))
Check "...from Resolve-DrivEnvBuildtreesRoot's EnvValue" (($bi -ge 0) -and ($hash.KeyValuePairs[$bi].Item2.Extent.Text -match '\.EnvValue$'))
Check "step 1 no longer writes it" (-not ((Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\1-Setup_DevDrive.ps1')) -match '"DEVSYSTEM_BUILDTREES='))

Write-Host "=== 36. C3: every step names this toolchain's files from ONE table ==="
$k = 'clang64'; $p = 'N:\env\x_clang64_env_variables.env'
Check "identity: the file says this toolchain"        ((Get-DrivEnvEnvFileProblem -EnvMap @{ DEVSYSTEM_TOOLCHAIN_ID = 'clang64'; MSYS2_ENV = 'CLANG64' } -Key $k -Path $p) -ceq '')
Check "identity: another toolchain's file is named as such" ((Get-DrivEnvEnvFileProblem -EnvMap @{ DEVSYSTEM_TOOLCHAIN_ID = 'ucrt64'; MSYS2_ENV = 'ucrt64' } -Key $k -Path $p) -like "*DEVSYSTEM_TOOLCHAIN_ID=ucrt64, but this run is for toolchain 'clang64'*")
Check "identity: MSYS2_ENV is held to it too"          ((Get-DrivEnvEnvFileProblem -EnvMap @{ DEVSYSTEM_TOOLCHAIN_ID = 'clang64'; MSYS2_ENV = 'ucrt64' } -Key $k -Path $p) -like '*MSYS2_ENV=ucrt64*')
Check "identity: a file without the id sends you to step 2" ((Get-DrivEnvEnvFileProblem -EnvMap @{ MSYS2_ENV = 'clang64' } -Key $k -Path $p) -like '*defines no DEVSYSTEM_TOOLCHAIN_ID; step 2 writes it*')
Check "identity: no map is a problem, not a pass"      ((Get-DrivEnvEnvFileProblem -EnvMap $null -Key $k -Path $p) -ne '')
Check "the pre-3.0.0 env file, for the hint only"      ((Get-DrivEnvLegacyEnvFile -Cfg (Obj '{"environment":{"dev_drive_letter":"n:","dev_env_name":" DegorasSLR "}}')) -ceq 'N:\env\degorasslr_env_variables.env')
Check "...and nothing from a blank name"               ((Get-DrivEnvLegacyEnvFile -Cfg (Obj '{"environment":{"dev_drive_letter":"N","dev_env_name":" "}}')) -ceq '')

# Steps 2 to 5 print the env file they will use under -ValidateOnly, so the wiring is checkable without a drive: each
# must name exactly the file the names table names.
function StepEnvFile
{
    param([string]$Step, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $script = Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter "$Step-*.ps1" | Select-Object -First 1
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script.FullName @Arguments -ValidateOnly 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { return @{ Env = $null; Out = $out } }
    $line = @($out | Where-Object { $_ -match 'Env file for this toolchain: ' }) | Select-Object -First 1
    $envf = if ($line) { ($line -replace '^.*Env file for this toolchain:\s*', '' -replace '\]\s*$', '').Trim() } else { $null }
    return @{ Env = $envf; Out = $out }
}
foreach ($id in @('clang', 'ucrt'))
{
    $want = (Get-DrivEnvToolchainNames -Cfg (Resolve-DrivEnvToolchain -Cfg $dual -Id $id)).EnvFile
    foreach ($s in @('2', '3', '4', '5'))
    {
        $r = StepEnvFile $s @('-ConfigFile', $dualCfg, '-Toolchain', $id)
        Check "step $s for $id reads $([System.IO.Path]::GetFileName($want))" ($r.Env -ceq $want) ("-> " + $r.Env)
    }
}
$r = StepEnvFile '2' @('-ConfigFile', $base)
Check "a 2.x configuration is suffixed too"            ($r.Env -ceq (Get-DrivEnvToolchainNames -Cfg (Load $base)).EnvFile) ("-> " + $r.Env)

# ONE BASELINE PER DRIVE. FOUND BY REVIEW: only the second toolchain used to look at the first one's record, so
# building them in the other order, or narrowing 'generate', gave one drive two baselines. Every OTHER declared
# toolchain is consulted now, by whichever runs.
$clangEnv = (Get-DrivEnvToolchainNames -Cfg (Resolve-DrivEnvToolchain -Cfg $dual -Id 'clang')).EnvFile
$ucrtEnv  = (Get-DrivEnvToolchainNames -Cfg (Resolve-DrivEnvToolchain -Cfg $dual -Id 'ucrt')).EnvFile
$r = StepEnvFile '3' @('-ConfigFile', $dualCfg, '-Toolchain', 'ucrt')
Check "step 3 for ucrt consults clang's env file for the baseline" (@($r.Out | Where-Object { $_ -like "*also consults: $clangEnv (toolchain 'clang')*" }).Count -eq 1)
$r = StepEnvFile '3' @('-ConfigFile', $dualCfg, '-Toolchain', 'clang')
Check "...and step 3 for clang, the first, consults ucrt's"        (@($r.Out | Where-Object { $_ -like "*also consults: $ucrtEnv (toolchain 'ucrt')*" }).Count -eq 1)
$narrow = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-narrow3-" + [guid]::NewGuid().ToString('N') + ".json")
try
{
    $c = Clone $dual; $c.generate = @('ucrt')
    [System.IO.File]::WriteAllText($narrow, ($c | ConvertTo-Json -Depth 100))
    $r = StepEnvFile '3' @('-ConfigFile', $narrow, '-Toolchain', 'ucrt')
    Check "...and with 'generate' narrowed to ucrt, still clang's"  (@($r.Out | Where-Object { $_ -like "*also consults: $clangEnv*" }).Count -eq 1)
}
finally { Remove-Item -LiteralPath $narrow -Force -ErrorAction SilentlyContinue }
$r = StepEnvFile '3' @('-ConfigFile', $base)
Check "a 2.x configuration consults nobody"            (@($r.Out | Where-Object { $_ -like "*also consults*" }).Count -eq 0)

$full = 'a' * 40; $other = 'b' * 40
$d = Get-DrivEnvBaselineDecision -Mode 'latest' -Siblings @()
Check "latest, nobody recorded: resolve"               (($d.Action -ceq 'resolve') -and ($d.Warnings.Count -eq 0))
$d = Get-DrivEnvBaselineDecision -Mode 'latest' -Siblings @([pscustomobject]@{ Id = 'clang'; Baseline = '' }, [pscustomobject]@{ Id = 'msvc'; Baseline = 'not-a-commit' })
Check "latest, nothing usable recorded: resolve"       ($d.Action -ceq 'resolve')
$d = Get-DrivEnvBaselineDecision -Mode ' Latest ' -Siblings @([pscustomobject]@{ Id = 'clang'; Baseline = " $full " })
Check "latest, a sibling recorded one: REUSE it"       (($d.Action -ceq 'reuse') -and ($d.Commit -ceq $full) -and ($d.From -ceq 'clang') -and ($d.Warnings.Count -eq 0))
$d = Get-DrivEnvBaselineDecision -Mode 'latest' -Siblings @([pscustomobject]@{ Id = 'clang'; Baseline = $full }, [pscustomobject]@{ Id = 'ucrt'; Baseline = $other })
Check "latest, two siblings disagree: the first, and a warning naming the other's -Toolchain" `
    (($d.Commit -ceq $full) -and ($d.Warnings.Count -eq 1) -and ($d.Warnings[0] -like "*-Toolchain ucrt*"))
$d = Get-DrivEnvBaselineDecision -Mode 'fixed' -Fixed $full -Siblings @([pscustomobject]@{ Id = 'clang'; Baseline = $other })
Check "fixed, a sibling at another commit: the configured one, and a warning with its -Toolchain" `
    (($d.Action -ceq 'fixed') -and ($d.Commit -ceq $full) -and ($d.Warnings.Count -eq 1) -and ($d.Warnings[0] -like "*run steps 3 and 4 with -Toolchain clang*") -and ($d.Warnings[0] -like "*vcpkg remove --recurse*"))
$d = Get-DrivEnvBaselineDecision -Mode 'fixed' -Fixed 'AAAAAAA' -Siblings @([pscustomobject]@{ Id = 'clang'; Baseline = $full })
Check "fixed and ABBREVIATED, the sibling at that very commit: no false warning" (($d.Commit -ceq 'AAAAAAA') -and ($d.Warnings.Count -eq 0))
$d = Get-DrivEnvBaselineDecision -Mode 'fixed' -Fixed $full -Siblings @()
Check "fixed, nobody recorded: the configured one, silently" (($d.Commit -ceq $full) -and ($d.Warnings.Count -eq 0))

# No numbered step builds a per-toolchain name of its own any more: a name built anywhere but the table is a file
# some other step cannot find.
$builders = @()
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' | Where-Object { $_.Name -match '^[1-6]-' }))
{
    foreach ($hit in (Select-String -LiteralPath $f.FullName -Pattern "_env_variables\.env[`"']|_env_launcher\.(bat|lnk)[`"']|Environment\.lnk[`"']"))
    {
        if ($hit.Line -notmatch '^\s*#') { $builders += ("{0}:{1}" -f $f.Name, $hit.LineNumber) }
    }
}
Check "no step builds an env file, launcher or shortcut name itself" ($builders.Count -eq 0) ("-> " + ($builders -join ', '))

# FOUND BY REVIEW. What -ValidateOnly prints is only worth checking if it is what the step OPENS. So, in steps 2 to 5:
# $envFilePath is assigned exactly once, from $names.EnvFile, BEFORE the -ValidateOnly exit (whose message prints it);
# every Read-EnvFile and Set-DrivEnvFileValues of the env file goes through it; the pre-3.0.0 path is never opened;
# and steps 3 to 5 abort on Get-DrivEnvEnvFileProblem before they read anything out of the file.
function StepAst { param([string]$Step) $f = Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter "$Step-*.ps1" | Select-Object -First 1; return [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null) }
function AllOf  { param($Ast, [scriptblock]$Pred) return @($Ast.FindAll($Pred, $true)) }
foreach ($s in @('2', '3', '4', '5'))
{
    $ast = StepAst $s
    $assigns = AllOf $ast { param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left.Extent.Text -eq '$envFilePath') }
    $exitIf  = AllOf $ast { param($n) ($n -is [System.Management.Automation.Language.IfStatementAst]) -and ($n.Clauses[0].Item1.Extent.Text -eq '$ValidateOnly') } | Select-Object -First 1
    Check "step ${s}: `$envFilePath assigned once, from `$names.EnvFile, before -ValidateOnly prints it" `
        (($assigns.Count -eq 1) -and ($assigns[0].Right.Extent.Text -eq '$names.EnvFile') -and ($null -ne $exitIf) -and
         ($assigns[0].Extent.StartOffset -lt $exitIf.Extent.StartOffset) -and ($exitIf.Extent.Text -match '\$envFilePath'))

    $envCalls = AllOf $ast { param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and (@('Read-EnvFile', 'Set-DrivEnvFileValues', 'Test-EnvFileDefines') -contains $n.GetCommandName()) }
    $stray = @($envCalls | Where-Object { $_.Extent.Text -notmatch '\$envFilePath' -and $_.Extent.Text -notmatch '\$s\.EnvFile' })
    Check "step ${s}: every env-file read or write goes through `$envFilePath" ($stray.Count -eq 0) ("-> " + (($stray | ForEach-Object { $_.Extent.Text }) -join ' | '))

    $legacyUse = AllOf $ast { param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and (@('Read-EnvFile', 'Set-DrivEnvFileValues') -contains $n.GetCommandName()) -and ($n.Extent.Text -match '\$legacy') }
    Check "step ${s}: the pre-3.0.0 file is named, never opened" ($legacyUse.Count -eq 0)

    if ($s -ne '2')
    {
        $gate = AllOf $ast { param($n) ($n -is [System.Management.Automation.Language.IfStatementAst]) -and ($n.Clauses[0].Item1.Extent.Text -eq '$identity') -and ($n.Clauses[0].Item2.Extent.Text -match 'Abort-WithError') }
        $check = AllOf $ast { param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Get-DrivEnvEnvFileProblem') -and ($n.Extent.Text -match '-Key \$names\.Key') }
        $firstUse = AllOf $ast { param($n) ($n -is [System.Management.Automation.Language.IndexExpressionAst]) -and ($n.Target.Extent.Text -eq '$envMap') } | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
        Check "step ${s}: aborts on Get-DrivEnvEnvFileProblem before reading the file's values" `
            (($gate.Count -eq 1) -and ($check.Count -eq 1) -and ($null -ne $firstUse) -and ($gate[0].Extent.StartOffset -lt $firstUse.Extent.StartOffset))
    }
}

# Step 2 is the only writer of the drive header and of the launcher set now that step 1 does neither.
$ast2 = StepAst '2'
$hdr = AllOf $ast2 { param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Set-DrivEnvFileValues') -and ($n.Extent.Text -match '-Section "drive"') -and ($n.Extent.Text -match '-First') }
Check "step 2 writes the drive header with -First"      ($hdr.Count -eq 1)
$m2 = AllOf $ast2 { param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Set-DrivEnvFileValues') -and ($n.Extent.Text -match '-Section "msys2"') -and ($n.Extent.Text -match '-Values \$msys2Values') }
$m2v = AllOf $ast2 { param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left.Extent.Text -eq '$msys2Values') -and ($n.Right.Extent.Text -match '^Get-DrivEnvMsys2EnvValues -Key \$names\.Key') }
Check "...its msys2 block from Get-DrivEnvMsys2EnvValues, keyed by `$names.Key" (($m2.Count -eq 1) -and ($m2v.Count -eq 1))
Check "...deploys the launcher set"                     ((AllOf $ast2 { param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Install-DrivEnvLauncherSet') -and ($n.Extent.Text -match '-Names \$names') }).Count -eq 1)
$tp = AllOf $ast2 { param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left.Extent.Text -eq '$targetPath') }
Check "...points both shortcuts at `$names.Launcher"      (($tp.Count -eq 1) -and ($tp[0].Right.Extent.Text -eq '$names.Launcher'))
$legacyIf = AllOf $ast2 { param($n) ($n -is [System.Management.Automation.Language.IfStatementAst]) -and ($n.Clauses[0].Item1.Extent.Text -match 'legacyEnvFile') -and ($n.Clauses[0].Item2.Extent.Text -match 'Abort-WithError') }
$firstWrite = AllOf $ast2 { param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and (@('Set-DrivEnvFileValues', 'Set-Msys2InstalledPins', 'Install-DrivEnvLauncherSet') -contains $n.GetCommandName()) } | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
$exit2 = AllOf $ast2 { param($n) ($n -is [System.Management.Automation.Language.IfStatementAst]) -and ($n.Clauses[0].Item1.Extent.Text -eq '$ValidateOnly') } | Select-Object -First 1
Check "...and refuses a pre-3.0.0 drive after -ValidateOnly, before it writes anything" `
    (($legacyIf.Count -eq 1) -and ($legacyIf[0].Extent.StartOffset -gt $exit2.Extent.StartOffset) -and ($legacyIf[0].Extent.StartOffset -lt $firstWrite.Extent.StartOffset))
$step1 = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\1-Setup_DevDrive.ps1')
Check "step 1 copies no launcher and writes no env file" (($step1 -notmatch 'drive.launchers') -and ($step1 -notmatch 'StreamWriter'))

Write-Host "=== 37. ONE TOOLCHAIN'S .env, composed in step order and expanded by the real bootstrap ==="
# Step 2 writes the drive header (-First) and its msys2 block, step 3 its vcpkg block, and a re-run of step 2 must
# leave the order alone: the bootstrap expands ${...} once, top to bottom. The values come from the same helpers the
# steps call; the bootstrap then has to turn DEVSYSTEM_BUILDTREES into this toolchain's own folder.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-env-" + [guid]::NewGuid().ToString('N'))
try
{
    $rcu   = Resolve-DrivEnvToolchain -Cfg $dual -Id 'ucrt'
    $nu    = Get-DrivEnvToolchainNames -Cfg $rcu
    $envf  = Join-Path $tmp ([System.IO.Path]::GetFileName($nu.EnvFile))
    $trip  = ([string]$rcu.vcpkg.target.triplet).Trim()
    $bt    = Resolve-DrivEnvBuildtreesRoot -Cfg $rcu -DriveLetter $rcu.environment.dev_drive_letter -Triplet $trip
    # The msys2 block from the very function step 2 writes it with (FOUND BY REVIEW: this used to be hand-written here,
    # so what step 2 wrote and what steps 3 to 5 check could drift apart unseen).
    $sub   = Resolve-DrivEnvMsys2Target -Target $rcu.msys2.target
    $msys2 = Get-DrivEnvMsys2EnvValues -Key $nu.Key -Family $sub.Family -Msys2Root 'R:\msys64' -BasePath '/usr/bin'
    $vcpkg = [ordered]@{ VCPKG_DEFAULT_TRIPLET = $trip; VCPKG_BIN = 'x'; DEVSYSTEM_BUILDTREES = $bt.EnvValue; PATH = '${BASE_PATH}' }

    Set-DrivEnvFileValues -Path $envf -Values (Get-DrivEnvDriveEnvValues -Cfg $rcu) -Section 'drive' -First
    Set-DrivEnvFileValues -Path $envf -Values $msys2 -Section 'msys2'
    Set-DrivEnvFileValues -Path $envf -Values $vcpkg -Section 'vcpkg'
    $once = Get-Content -Raw -LiteralPath $envf
    Set-DrivEnvFileValues -Path $envf -Values (Get-DrivEnvDriveEnvValues -Cfg $rcu) -Section 'drive' -First
    Set-DrivEnvFileValues -Path $envf -Values $msys2 -Section 'msys2'
    Check "a re-run of step 2 after step 3 changes nothing"  ((Get-Content -Raw -LiteralPath $envf) -ceq $once)

    # What step 2 writes is what steps 3 to 5 accept -- for this toolchain, and for no other.
    $map = @{}
    foreach ($l in (Get-Content -LiteralPath $envf)) { $i = $l.IndexOf('='); if (($i -gt 0) -and -not $l.StartsWith('#')) { $map[$l.Substring(0, $i)] = $l.Substring($i + 1) } }
    Check "the identity gate accepts the file for its own key"  ((Get-DrivEnvEnvFileProblem -EnvMap $map -Key $nu.Key -Path $envf) -ceq '')
    Check "...and refuses it for the other toolchain's"         ((Get-DrivEnvEnvFileProblem -EnvMap $map -Key 'clang64' -Path $envf) -ne '')
    Check "DEVSYSTEM_TOOLCHAIN_ROOT is <msys64>/<key>"            ($map['DEVSYSTEM_TOOLCHAIN_ROOT'] -ceq "R:/msys64/$($nu.Key)")

    $lines = @(Get-Content -LiteralPath $envf)
    $at = { param($k) for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like "$k=*") { return $i } }; return -1 }
    Check "drive header, then msys2, then vcpkg, PATH last" `
        (((& $at 'DEVDRIVE_LETTER') -lt (& $at 'MSYS2_ENV')) -and ((& $at 'MSYS2_ENV') -lt (& $at 'VCPKG_DEFAULT_TRIPLET')) -and
         ((& $at 'VCPKG_DEFAULT_TRIPLET') -lt (& $at 'DEVSYSTEM_BUILDTREES')) -and ((& $at 'PATH') -eq ($lines.Count - 1)))

    if ($testBash)
    {
        # Loaded by the real bootstrap: only its [ENV] lines are read, which it prints as it expands each value --
        # before it creates anything under DEVDRIVE_ROOT, a drive letter this machine may not have.
        New-Item -ItemType Directory -Path (Join-Path $tmp 'launcher') -Force | Out-Null
        $bootc = Join-Path $tmp ('launcher\' + $nu.Stem + '_env_launcher_bootstrap.sh')
        Copy-Item -LiteralPath (Join-Path $root 'drive\launchers\env_launcher_bootstrap.sh') -Destination $bootc
        $runc = Join-Path $tmp 'runner.sh'
        [System.IO.File]::WriteAllText($runc, 'export PATH="/usr/bin:$PATH"' + "`n" + '. "$PROBE_BOOT"' + "`n")
        $ErrorActionPreference = 'Continue'
        $env:MSYSTEM = 'UCRT64'; $env:DEV_ENV_NO_PAUSE = '1'; $env:PROBE_BOOT = (PosixOf $bootc); $env:DP_ENVFILE = (PosixOf $envf)
        $o = (& $testBash -c (". " + (PosixOf $runc)) 2>&1 | ForEach-Object { "$_" }) -join "`n"
        Remove-Item Env:DP_ENVFILE, Env:MSYSTEM, Env:PROBE_BOOT, Env:DEV_ENV_NO_PAUSE -ErrorAction SilentlyContinue
        $ErrorActionPreference = 'Stop'
        $letterLc = ([string]$rcu.environment.dev_drive_letter).Trim().TrimEnd(':').ToLowerInvariant()
        $wantBt = "/$letterLc/$($bt.Folder)/$trip"
        Check "the bootstrap expands DEVSYSTEM_BUILDTREES to this triplet's folder ($wantBt)" ($o.Contains("[ENV] DEVSYSTEM_BUILDTREES=$wantBt")) ("-> " + $o)
        Check "...and the drive header it refers to came first" ($o.Contains("[ENV] DEVDRIVE_LETTER=/$letterLc`n") -or $o.Contains("[ENV] DEVDRIVE_LETTER=/$letterLc`r"))
    }
    else
    {
        $script:skip++; Write-Host "  SKIP  no bash: the bootstrap expansion of the composed file did not run"
    }
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "=== 38. C3 REVIEW: what the second adversarial review found untested or wrong ==="
# Step 5's verdicts, with no guard of the step's own on an empty listing.
$pkgs = @((Obj '{"name":"fmt"}'), (Obj '{"name":"zlib"}'), (Obj '{"name":" "}'))
$pr = Get-DrivEnvPackageResults -Listed (ConvertFrom-DrivEnvVcpkgListJson -Text '{}') -Packages $pkgs -DefaultTriplet $clangT
Check "an empty listing: one FAIL per named package"    (($pr.Count -eq 2) -and (@($pr | Where-Object { $_.State -ceq 'fail' }).Count -eq 2))
$pr = Get-DrivEnvPackageResults -Listed $null -Packages $pkgs -DefaultTriplet $clangT
Check "no listing at all: no verdicts, an EMPTY ARRAY"  (($pr -is [System.Array]) -and ($pr.Count -eq 0))
$pr = Get-DrivEnvPackageResults -Listed $onlyUcrt -Packages @((Obj '{"name":"fmt"}')) -DefaultTriplet $clangT
Check "size 1 stays an array of one verdict"            (($pr -is [System.Array]) -and ($pr.Count -eq 1) -and ($pr[0].State -ceq 'ok'))
$ast5 = StepAst '5'
$guards = AllOf $ast5 { param($n) ($n -is [System.Management.Automation.Language.IfStatementAst]) -and ($n.Clauses[0].Item1.Extent.Text -match '\$listed') -and ($n.Extent.Text -match 'Get-DrivEnvPackageResults') }
Check "step 5 takes every verdict from the helper, under no guard of its own" `
    (($guards.Count -eq 0) -and ((AllOf $ast5 { param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Get-DrivEnvPackageCheck') }).Count -eq 0))

# A custom variable over a name step 2 writes would be deleted the next time step 2 runs.
$c = Load $base; Add-Member -InputObject $c.environment.custom_variables -MemberType NoteProperty -Name 'DEVSYSTEM_DEPLOYS' -Value 'x'
Check "custom_variables may not override a name step 2 writes" (HasProblem $c 'environment.custom_variables.DEVSYSTEM_DEPLOYS: reserved')
$c = Load $base; Add-Member -InputObject $c.environment.custom_variables -MemberType NoteProperty -Name 'path' -Value 'x'
Check "...nor PATH, in any case"                         (HasProblem $c 'use environment.custom_path_entries')
$c = Load $base; Add-Member -InputObject $c.environment.custom_variables -MemberType NoteProperty -Name 'MY_SDK_ROOT' -Value 'x'
Check "...while a name of its own is fine"               ((Test-DrivEnvConfig -Config $c).Count -eq 0)

# The build trees: a port every OTHER toolchain has stamped is one nobody needs the sources of, whatever the order.
$CT = 'x64-mingw-clang-dynamic-release'; $UT = 'x64-mingw-ucrt-dynamic-release'
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('src', "$CT-rel") -FileNames @("$CT.vcpkg_abi_info.txt", "$UT.vcpkg_abi_info.txt") -OwnTriplets @($CT) -LastToolchain $false -Mode 'logs' -OtherTriplets @($UT)
Check "not last, but ucrt has built the port already: src goes too" ((Joined $p.RemoveDirs) -ceq "src|$CT-rel")
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('src', "$CT-rel") -FileNames @("$CT.vcpkg_abi_info.txt") -OwnTriplets @($CT) -LastToolchain $false -Mode 'logs' -OtherTriplets @($UT)
Check "...and while ucrt has not, src stays for it"      ((Joined $p.RemoveDirs) -ceq "$CT-rel")
$p = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames @('src', "$CT-rel") -FileNames @("$CT.vcpkg_abi_info.txt") -OwnTriplets @($CT) -LastToolchain $false -Mode 'all' -OtherTriplets @()
Check "...with no other toolchain named, the old rule"   ((Joined $p.RemoveDirs) -ceq "$CT-rel")

# The env file is read as UTF-8: a rewrite must not double-encode what it did not write. (Pre-existing, measured.)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-utf8-" + [guid]::NewGuid().ToString('N') + ".env")
try
{
    $label = 'DEV_' + [char]0x00D1 + 'AND' + [char]0x00DA
    Set-DrivEnvFileValues -Path $tmp -Values ([ordered]@{ DEVDRIVE_NAME = $label }) -Section 'drive' -First
    Set-DrivEnvFileValues -Path $tmp -Values ([ordered]@{ MSYS2_ENV = 'clang64' }) -Section 'msys2'
    Set-DrivEnvFileValues -Path $tmp -Values ([ordered]@{ VCPKG_ROOT = 'x' }) -Section 'vcpkg'
    Check "a non-ASCII label survives two rewrites"      (@([System.IO.File]::ReadAllLines($tmp, (New-Object System.Text.UTF8Encoding($false))) | Where-Object { $_ -ceq "DEVDRIVE_NAME=$label" }).Count -eq 1)
}
finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

# Step 6: the first EXISTING toolchain env file, in 'generate' order.
$cand = Get-DrivEnvEnvFileCandidates -Cfg $dual
Check "step 6's candidates: every generated toolchain's, in 'generate' order" ((Joined $cand) -ceq "$clangEnv|$ucrtEnv")
Check "...the first that exists: only the second does"    ((Select-DrivEnvFirstExisting -Paths $cand -Exists { param($x) $x -ceq $ucrtEnv }) -ceq $ucrtEnv)
Check "...both do: the first"                            ((Select-DrivEnvFirstExisting -Paths $cand -Exists { param($x) $true }) -ceq $clangEnv)
Check "...none does: blank"                              ((Select-DrivEnvFirstExisting -Paths $cand -Exists { param($x) $false }) -ceq '')
$r6 = & {
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\6-Clone_Repos.ps1') -ConfigFile $dualCfg -ValidateOnly 2>&1 | ForEach-Object { "$_" }
}
$c6 = @($r6 | Where-Object { $_ -match 'Env file candidate, in this order: ' } | ForEach-Object { ($_ -replace '^.*in this order:\s*', '' -replace '\]\s*$', '').Trim() })
Check "step 6 -ValidateOnly prints those candidates, in that order" ((Joined $c6) -ceq "$clangEnv|$ucrtEnv")
$ast6 = StepAst '6'
Check "...and chooses with Select-DrivEnvFirstExisting"  ((AllOf $ast6 { param($n) ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -and ($n.Left.Extent.Text -eq '$envFilePath') -and ($n.Right.Extent.Text -match '^Select-DrivEnvFirstExisting -Paths \$envCandidates') }).Count -eq 1)

# Declared targets: the generated first, then the rest.
$c = Clone $dual; $c.generate = @('ucrt')
$dt = Get-DrivEnvDeclaredTargets -Cfg $c
Check "declared targets: the generated one first, then the other, flagged" `
    (($dt.Count -eq 2) -and ($dt[0].Id -ceq 'ucrt') -and $dt[0].Generated -and ($dt[1].Id -ceq 'clang') -and (-not $dt[1].Generated) -and ($dt[1].Key -ceq 'clang64'))
$dt1 = Get-DrivEnvDeclaredTargets -Cfg (Load $base)
Check "...a 2.x configuration: itself, once"            (($dt1 -is [System.Array]) -and ($dt1.Count -eq 1) -and ($dt1[0].Id -ceq ''))
$mv = Get-DrivEnvMsys2EnvValues -Key 'clang64' -Family 'clang' -Msys2Root 'N:\msys64\' -BasePath '/b'
Check "the msys2 block, exactly"                         ((Joined @($mv.Keys | ForEach-Object { "$_=$($mv[$_])" })) -ceq 'DEVSYSTEM_TOOLCHAIN_ROOT=N:/msys64/clang64|DEVSYSTEM_TOOLCHAIN=clang|DEVSYSTEM_TOOLCHAIN_ID=clang64|MSYS2_ROOT=N:/msys64|MSYS2_BASH=N:/msys64/usr/bin/bash.exe|MSYS2_ENV=clang64|BASE_PATH=/b')

# The launcher pauses on a refusal, so a window opened from a shortcut keeps its message; DEV_ENV_NO_PAUSE turns it off.
# Measured by the lines the run prints -- pause's own prompt is in the system language -- with an Enter on stdin.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-pause-" + [guid]::NewGuid().ToString('N'))
try
{
    New-Item -ItemType Directory -Path (Join-Path $tmp 'env\launcher') -Force | Out-Null
    $bat = Join-Path $tmp 'env\launcher\abc_clang64_env_launcher.bat'
    Copy-Item -LiteralPath (Join-Path $root 'drive\launchers\env_launcher.bat') -Destination $bat
    $runPause = {
        param([string]$NoPause)
        $ErrorActionPreference = 'Continue'
        if ($null -eq $NoPause) { Remove-Item Env:DEV_ENV_NO_PAUSE -ErrorAction SilentlyContinue } else { $env:DEV_ENV_NO_PAUSE = $NoPause }
        $o = "`r`n" | & cmd.exe /d /c ('"' + $bat + '"') 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() }
        Remove-Item Env:DEV_ENV_NO_PAUSE -ErrorAction SilentlyContinue
        return ,@($o)
    }
    $quiet = & $runPause '1'; $paused = & $runPause $null; $zero = & $runPause '0'
    Check "a refusal waits for a key"                       ($paused.Count -gt $quiet.Count) ("-> quiet $($quiet.Count), paused $($paused.Count)")
    Check "...DEV_ENV_NO_PAUSE=0 waits too, =1 does not"    ($zero.Count -eq $paused.Count)
}
finally
{
    Remove-Item Env:DEV_ENV_NO_PAUSE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== 39. C4: every per-toolchain output carries the key, and holds only its toolchain ==="
Check "a step's log name carries the key"              ((Get-DrivEnvLogName -Timestamp '20261008_101010' -Role 'vcpkg-deps-setup' -Key ' clang64 ') -ceq '20261008_101010_vcpkg-deps-setup_clang64.log')
Check "...and a drive step's does not"                  ((Get-DrivEnvLogName -Timestamp '20261008_101010' -Role 'workspace-repos-clone') -ceq '20261008_101010_workspace-repos-clone.log')

$invJson = '{"fmt:x64-mingw-clang-dynamic-release":{"package_name":"fmt","triplet":"x64-mingw-clang-dynamic-release","version":"12.2.0","port_version":1,"features":[]},' +
           '"fmt:x64-mingw-ucrt-dynamic-release":{"package_name":"fmt","triplet":"x64-mingw-ucrt-dynamic-release","version":"12.2.0","port_version":1,"features":[]},' +
           '"curl:x64-mingw-clang-dynamic-release":{"package_name":"curl","triplet":"x64-mingw-clang-dynamic-release","version":"8.22.0","port_version":0,"features":["ssl","http2"]}}'
$inv = ConvertTo-DrivEnvVcpkgInventory -Text $invJson -Triplets @('X64-MINGW-CLANG-DYNAMIC-RELEASE')
Check "the record lists this toolchain's ports only, readable, sorted" `
    ((Joined $inv.Lines) -ceq 'curl[ssl,http2]:x64-mingw-clang-dynamic-release  8.22.0|fmt:x64-mingw-clang-dynamic-release  12.2.0#1')
$kept = @(($inv.Json | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
Check "...and its JSON keeps exactly those entries"     ((Joined $kept) -ceq 'curl:x64-mingw-clang-dynamic-release|fmt:x64-mingw-clang-dynamic-release')
$inv0 = ConvertTo-DrivEnvVcpkgInventory -Text $invJson -Triplets @('x64-mingw-static')
Check "...none of its triplets installed: '{}', no lines" (($inv0.Json -ceq '{}') -and ($inv0.Lines.Count -eq 0))
Check "...output that is not JSON throws"               (Throws { ConvertTo-DrivEnvVcpkgInventory -Text 'nope' -Triplets @('x') })

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-flk-" + [guid]::NewGuid().ToString('N'))
try
{
    New-Item -ItemType Directory -Path (Join-Path $tmp 'bt\zlib') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tmp 'bt\zlib\build-x-rel-err.log') -Value 'e'
    $leaf = & {
        function Get-DrivEnvLogRoot { param($DriveLetter) return (Join-Path $tmp 'logs') }
        Split-Path -Leaf (Save-VcpkgFailureLogs -PortName 'zlib' -Attempt 2 -BuildtreesRoot (Join-Path $tmp 'bt') -DriveLetter 'Z' -ToolchainKey 'ucrt64')
    }
    Check "a failed attempt's folder says whose it was"  ($leaf -match '^attempt2_ucrt64_\d{8}_\d{6}$') ("-> " + $leaf)
}
finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# Wired in the steps, which run only on a drive: checked from the source.
foreach ($s in @(@{ N = '2'; R = 'msys2-env-setup' }, @{ N = '3'; R = 'vcpkg-clone-setup' }, @{ N = '4'; R = 'vcpkg-deps-setup' }, @{ N = '5'; R = 'generic_devdrive-verify' }))
{
    $logCalls = AllOf (StepAst $s.N) { param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.GetCommandName() -eq 'Get-DrivEnvLogName') -and ($n.Extent.Text -match "-Role `"$($s.R)`"") -and ($n.Extent.Text -match '-Key \$names\.Key') }
    Check "step $($s.N)'s log is named with the key"   ($logCalls.Count -eq 1)
}
$src4 = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\4-Deps_VCPKG.ps1')
Check "step 4's records carry the key"                  ((@([regex]::Matches($src4, 'Get-DrivEnvRecordName -Name "(vcpkg_packages\.txt|vcpkg_packages\.json|msys2_packages\.txt|environment\.txt)"\s+-Key \$names\.Key')).Count -eq 4))
Check "...the baseline record stays the drive's, unsuffixed" ($src4 -match 'Write-InventoryFile -Name "vcpkg_baseline\.txt"')
Check "...the packages are narrowed to this toolchain"  (($src4 -match 'ConvertTo-DrivEnvVcpkgInventory -Text .* -Triplets \$ownTriplets') -and ($src4 -match 'Select-DrivEnvToolchainPackages -Lines'))
Check "...the reference manifest is the toolchain's"    (($src4 -match '\$manifestPath = \$names\.VcpkgReference') -and ($src4 -match 'ConvertTo-ManifestName \$names\.ManifestName'))
Check "...failed attempts are kept under the key"       ($src4 -match '-ToolchainKey \$names\.Key')
$src5 = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\5-Verify_Env.ps1')
Check "step 5's report is verification_<key>.txt"       ($src5 -match 'Get-DrivEnvRecordName -Name "verification\.txt" -Key \$names\.Key')
$src2 = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\2-Setup_MSYS2.ps1')
Check "step 2's packages export holds this toolchain's packages" ($src2 -match 'Select-DrivEnvToolchainPackages -Lines .* -Prefix \$msysSub\.Prefix')
# FOUND BY REVIEW: skipping only this drive's msys64 let the other toolchain's vcpkg bin and tools directories in.
Check "...and its BASE_PATH takes nothing from this drive at all" ($src2 -match 'Test-DrivEnvPathUnder -Path \$trimmed -Root \$devDrive')

Write-Host "=== 40. QT CREATOR (step 7): one for the drive, one kit per toolchain ==="
$example = Load (Join-Path $cfgDir 'drivenv-cfg_example.json')
function WithQt { param($Qt) $c = Clone $example; $c.ide_integration.qtcreator = $Qt; return $c }

# The validator: what each source needs.
Check "the shipped example validates with Qt Creator from ucrt64" ((Test-DrivEnvConfig -Config $example).Count -eq 0)
Check "msys2 without a subsystem is refused"            (HasProblem (WithQt (Obj '{"source":"msys2"}')) "qtcreator.subsystem: required when source is 'msys2'")
Check "msys2 from a subsystem no toolchain has is refused" (HasProblem (WithQt (Obj '{"source":"msys2","subsystem":"mingw64"}')) "'mingw64' is not the subsystem of any declared toolchain")
$c = WithQt (Obj '{"source":"msys2","subsystem":"clang64"}')
Check "msys2 from a toolchain that does not list qt-creator is refused" (HasProblem $c "needs 'qt-creator' in toolchains.clang.msys2.packages")
Check "msys2 with a path or sdktool is refused"         (HasProblem (WithQt (Obj '{"source":"msys2","subsystem":"ucrt64","path":"C:/x/qtcreator.exe"}')) "qtcreator.path: only for source 'external'")
Check "external without a path is refused"              (HasProblem (WithQt (Obj '{"source":"external"}')) "qtcreator.path: required when source is 'external'")
Check "external with a relative path is refused"        (HasProblem (WithQt (Obj '{"source":"external","path":"Qt/qtcreator.exe"}')) "must be an absolute path to qtcreator.exe")
Check "external with an absolute path is fine"          ((Test-DrivEnvConfig -Config (WithQt (Obj '{"source":"external","path":"C:/Qt/Tools/QtCreator/bin/qtcreator.exe"}'))).Count -eq 0)
Check "an unknown source is refused"                    (HasProblem (WithQt (Obj '{"source":"vscode"}')) "is not one of: msys2, external, none")
# Owner decision 2026-10-19: the drive's kits also in the user's own Qt Creator, opt-in.
Check "register_in_user_settings: fine with a Qt Creator integration" `
    ((Test-DrivEnvConfig -Config (WithQt (Obj '{"source":"msys2","subsystem":"ucrt64","register_in_user_settings":true}'))).Count -eq 0)
Check "...refused with source none, which makes no kits" (HasProblem (WithQt (Obj '{"source":"none","register_in_user_settings":true}')) 'register_in_user_settings: needs a Qt Creator integration')

# What step 7 resolves.
$qs = Get-DrivEnvQtCreatorSetup -Cfg $example
Check "msys2: the package's qtcreator.exe and sdktool.exe" (($qs.QtCreator -ceq 'R:\msys64\ucrt64\bin\qtcreator.exe') -and ($qs.Sdktool -ceq 'R:\msys64\ucrt64\bin\sdktool.exe'))
Check "the drive's settings: user, installer, and sdktool's path inside it" `
    (($qs.UserSettings -ceq 'R:\env\qtcreator\settings') -and ($qs.InstallSettings -ceq 'R:\env\qtcreator\install') -and ($qs.SdkPath -ceq 'R:\env\qtcreator\install\QtProject\qtcreator'))
Check "the drive's launcher directory and prefix, for the per-toolchain launchers" (($qs.LauncherDir -ceq 'R:\env\launcher') -and ($qs.Prefix -ceq 'degorasslr') -and ($qs.Drive -ceq 'R:'))
Check "...each toolchain's launcher from the names table" `
    ((Joined @($qs.Toolchains | ForEach-Object { $_.Names.QtLauncher })) -ceq 'R:\env\launcher\degorasslr_clang64_qtcreator.bat|R:\env\launcher\degorasslr_ucrt64_qtcreator.bat')
Check "one kit per declared toolchain, named after its key" ((Joined @($qs.Toolchains | ForEach-Object { "$($_.Id)=$($_.KitName)" })) -ceq 'clang=DegorasSLR clang64|ucrt=DegorasSLR ucrt64')
Check "msys2: the toolchain that brings Qt Creator is known" (($null -ne $qs.Holder) -and ($qs.Holder.Id -ceq 'ucrt'))
# FOUND BY REVIEW: Qt Creator shows an error dialog at every start when the installer settings have no QtCreator.ini.
Check "...and the installer settings' QtCreator.ini, which step 7 creates" ($qs.InstallIni -ceq 'R:\env\qtcreator\install\QtProject\QtCreator.ini')
$qe = Get-DrivEnvQtCreatorSetup -Cfg (WithQt (Obj '{"source":"external","path":"Z:/nowhere/QtCreator/bin/qtcreator.exe"}'))
Check "external: sdktool.exe beside qtcreator.exe when nothing is found, and no holder" (($qe.Sdktool -ceq 'Z:\nowhere\QtCreator\bin\sdktool.exe') -and ($null -eq $qe.Holder))
# FOUND BY REVIEW: the Qt online installer keeps sdktool in a component of its own, <Qt>\Tools\sdktool\bin.
$tqi = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-qti-" + [guid]::NewGuid().ToString('N'))
try
{
    foreach ($d in 'Tools\QtCreator\bin', 'Tools\sdktool\bin') { New-Item -ItemType Directory -Path (Join-Path $tqi $d) -Force | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $tqi 'Tools\sdktool\bin\sdktool.exe'), '')
    $qtiPath = (Join-Path $tqi 'Tools\QtCreator\bin\qtcreator.exe') -replace '\\', '/'
    $qi = Get-DrivEnvQtCreatorSetup -Cfg (WithQt ([pscustomobject]@{ source = 'external'; path = $qtiPath }))
    Check "...the Qt installer's Tools\sdktool\bin when it is there" ($qi.Sdktool -ceq (Join-Path $tqi 'Tools\sdktool\bin\sdktool.exe'))
    [System.IO.File]::WriteAllText((Join-Path $tqi 'Tools\QtCreator\bin\sdktool.exe'), '')
    $qi = Get-DrivEnvQtCreatorSetup -Cfg (WithQt ([pscustomobject]@{ source = 'external'; path = $qtiPath }))
    Check "...and beside qtcreator.exe first"             ($qi.Sdktool -ceq (Join-Path $tqi 'Tools\QtCreator\bin\sdktool.exe'))
}
finally { Remove-Item -LiteralPath $tqi -Recurse -Force -ErrorAction SilentlyContinue }
Check "source none, or no section: nothing to set up"    (($null -eq (Get-DrivEnvQtCreatorSetup -Cfg (WithQt (Obj '{"source":"none"}')))) -and ($null -eq (Get-DrivEnvQtCreatorSetup -Cfg (Load $base))))
$qr = Get-DrivEnvQtCreatorSetup -Cfg (WithQt (Obj '{"source":"msys2","subsystem":"ucrt64","register_in_user_settings":true}'))
Check "registration: on when asked, ids carrying the drive letter, the user's %APPDATA% Qt Creator settings" `
    ($qr.RegisterInUserSettings -and ($qr.UserIdPrefix -ceq 'drivenv.r.') -and ($qr.UserQtSettingsDir -ceq (Join-Path $env:APPDATA 'QtProject\qtcreator')) -and (-not $qs.RegisterInUserSettings))
# Owner, 2026-10-19: the user's settings directory named in the configuration rather than assumed.
$qp = Get-DrivEnvQtCreatorSetup -Cfg (WithQt (Obj '{"source":"msys2","subsystem":"ucrt64","register_in_user_settings":true,"user_settings_path":"%USERPROFILE%/QtElsewhere/"}'))
Check "...user_settings_path: %VARS% expanded, its qtcreator\ holding the kits" `
    (($qp.UserSettingsRoot -ceq (Join-Path $env:USERPROFILE 'QtElsewhere')) -and ($qp.UserQtSettingsDir -ceq (Join-Path $env:USERPROFILE 'QtElsewhere\qtcreator')))
Check "...refused without register_in_user_settings, and when not absolute" `
    ((HasProblem (WithQt (Obj '{"source":"msys2","subsystem":"ucrt64","user_settings_path":"%APPDATA%/QtProject"}')) 'user_settings_path: only with register_in_user_settings') -and
     (HasProblem (WithQt (Obj '{"source":"msys2","subsystem":"ucrt64","register_in_user_settings":true,"user_settings_path":"QtProject"}')) 'must be absolute once %VARIABLES% are expanded'))
# FOUND BY REVIEW: a profiles.xml holding only the drive's kits stops a first start from creating its Desktop kit.
Check "...and step 7 writes nothing without a QtCreator.ini and a profiles.xml there" `
    ((Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\7-Setup_IDE.ps1')) -match "if \(-not \(Test-Path -LiteralPath \(Join-Path \`$qt\.UserSettingsRoot 'QtCreator\.ini'\)\) -or -not \(Test-Path -LiteralPath \(Join-Path \`$qt\.UserQtSettingsDir 'profiles\.xml'\)\)\)")

# THE MERGE INTO THE USER'S OWN SETTINGS, on a synthetic user directory: one kit, toolchain, debugger, CMake and Qt of
# the user's, a default kit and CMake, an aspect filter -- and sdktool-shaped entries for one drive kit.
function QtcFile { param([string]$Doctype, [string[]]$Data) return "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`r`n<!DOCTYPE $Doctype>`r`n<!-- Written by QtCreator 20.0.1 -->`r`n<qtcreator>`r`n" + (($Data | ForEach-Object { " <data>`r`n$_`r`n </data>`r`n" }) -join '') + "</qtcreator>`r`n" }
function QtcVar { param([string]$Var, [string]$Inner) return "  <variable>$Var</variable>`r`n  $Inner" }
function QtcRead { param([string]$Path, [string]$Var) $x = [xml]([System.IO.File]::ReadAllText($Path)); return @($x.qtcreator.data | Where-Object { $_.variable -ceq $Var })[0] }
function QtcMapVal { param($Data, [string]$Key) $n = $Data.SelectSingleNode(".//*[@key='$Key']"); if ($n) { return $n.InnerText } return $null }
$ut = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-qtusr-" + [guid]::NewGuid().ToString('N'))
$ug = Join-Path $ut 'gen'; $uu = Join-Path $ut 'user'; $ue = Join-Path $ut 'empty'
New-Item -ItemType Directory -Path $ug, $uu, $ue -Force | Out-Null
try
{
    $userFiles = @{
        'profiles.xml'   = QtcFile 'QtCreatorProfiles' @(
            (QtcVar 'Kit.IrrelevantAspects' '<valuelist type="QVariantList"><value type="QString">QtSupport.QtInformation</value></valuelist>'),
            (QtcVar 'Profile.0' '<valuemap type="QVariantMap"><value type="QString" key="PE.Profile.Id">user.kit</value><value type="QString" key="PE.Profile.Name">Mine</value><value type="bool" key="PE.Profile.SDK">false</value><valuemap type="QVariantMap" key="PE.Profile.Data"><value type="int" key="QtSupport.QtInformation">5</value></valuemap></valuemap>'),
            (QtcVar 'Profile.Count' '<value type="int">1</value>'), (QtcVar 'Profile.Default' '<value type="QString">user.kit</value>'), (QtcVar 'Version' '<value type="int">1</value>'))
        'toolchains.xml' = QtcFile 'QtCreatorToolChains' @((QtcVar 'ToolChain.0' '<valuemap type="QVariantMap"><value type="QString" key="ProjectExplorer.ToolChain.Id">ProjectExplorer.ToolChain.Mingw:{u1}</value></valuemap>'),
                                                           (QtcVar 'ToolChain.Count' '<value type="int">1</value>'), (QtcVar 'Version' '<value type="int">1</value>'))
        'debuggers.xml'  = QtcFile 'QtCreatorDebuggers' @((QtcVar 'DebuggerItem.0' '<valuemap type="QVariantMap"><value type="QString" key="Id">{d1}</value></valuemap>'),
                                                          (QtcVar 'DebuggerItem.Count' '<value type="int">1</value>'), (QtcVar 'Version' '<value type="int">1</value>'))
        'cmaketools.xml' = QtcFile 'QtCreatorCmaketools' @((QtcVar 'CMakeTools.0' '<valuemap type="QVariantMap"><value type="QString" key="Id">user.cmake</value></valuemap>'),
                                                           (QtcVar 'CMakeTools.Count' '<value type="int">1</value>'), (QtcVar 'CMakeTools.Default' '<value type="QString">user.cmake</value>'), (QtcVar 'Version' '<value type="int">1</value>'))
        'qtversion.xml'  = QtcFile 'QtCreatorQtVersions' @((QtcVar 'QtVersion.0' '<valuemap type="QVariantMap"><value type="int" key="Id">5</value><value type="QString" key="Name">UserQt</value><value type="bool" key="isAutodetected">false</value></valuemap>'),
                                                           (QtcVar 'Version' '<value type="int">1</value>'))
    }
    $genFiles = @{
        'profiles.xml'   = QtcFile 'QtCreatorProfiles' @((QtcVar 'Profile.0' '<valuemap type="QVariantMap"><value type="bool" key="PE.Profile.AutoDetected">true</value><valuemap type="QVariantMap" key="PE.Profile.Data"><value type="QString" key="QtSupport.QtInformation">SDK.drivenv.r.x.qt</value></valuemap><value type="QString" key="PE.Profile.Id">drivenv.r.x</value><value type="QString" key="PE.Profile.Name">X (R:)</value><value type="bool" key="PE.Profile.SDK">true</value></valuemap>'),
                                                         (QtcVar 'Profile.Count' '<value type="int">1</value>'), (QtcVar 'Profile.Default' '<value type="QString">drivenv.r.x</value>'), (QtcVar 'Version' '<value type="int">1</value>'))
        'toolchains.xml' = QtcFile 'QtCreatorToolChains' @((QtcVar 'ToolChain.0' '<valuemap type="QVariantMap"><value type="bool" key="ProjectExplorer.ToolChain.Autodetect">true</value><value type="QString" key="ProjectExplorer.ToolChain.Id">ProjectExplorer.ToolChain.Mingw:drivenv.r.x.c</value></valuemap>'),
                                                           (QtcVar 'ToolChain.1' '<valuemap type="QVariantMap"><value type="bool" key="ProjectExplorer.ToolChain.Autodetect">true</value><value type="QString" key="ProjectExplorer.ToolChain.Id">ProjectExplorer.ToolChain.Mingw:drivenv.r.x.cxx</value></valuemap>'),
                                                           (QtcVar 'ToolChain.Count' '<value type="int">2</value>'), (QtcVar 'Version' '<value type="int">1</value>'))
        'debuggers.xml'  = QtcFile 'QtCreatorDebuggers' @((QtcVar 'DebuggerItem.0' '<valuemap type="QVariantMap"><value type="bool" key="AutoDetected">true</value><value type="QString" key="Id">drivenv.r.x.gdb</value></valuemap>'),
                                                          (QtcVar 'DebuggerItem.Count' '<value type="int">1</value>'), (QtcVar 'Version' '<value type="int">1</value>'))
        'cmaketools.xml' = QtcFile 'QtCreatorCmaketools' @((QtcVar 'CMakeTools.0' '<valuemap type="QVariantMap"><value type="bool" key="Autodetect">true</value><value type="QString" key="Id">drivenv.r.x.cmake</value></valuemap>'),
                                                           (QtcVar 'CMakeTools.Count' '<value type="int">1</value>'), (QtcVar 'Version' '<value type="int">1</value>'))
        'qtversion.xml'  = QtcFile 'QtCreatorQtVersions' @((QtcVar 'QtVersion.0' '<valuemap type="QVariantMap"><value type="int" key="Id">-1</value><value type="QString" key="autodetectionSource">SDK.drivenv.r.x.qt</value><value type="bool" key="isAutodetected">true</value></valuemap>'),
                                                           (QtcVar 'Version' '<value type="int">1</value>'))
    }
    foreach ($k in $userFiles.Keys) { [System.IO.File]::WriteAllText((Join-Path $uu $k), $userFiles[$k]); [System.IO.File]::WriteAllText((Join-Path $ug $k), $genFiles[$k]) }

    $m1 = Merge-DrivEnvQtUserSettings -GeneratedDir $ug -UserDir $uu -OwnPrefix 'drivenv.r.' -Stamp 't1'
    $p = Join-Path $uu 'profiles.xml'
    Check "user settings: merged, the drive's kit added" ($m1.Ok -and (($m1.Kits -join '|') -ceq 'X (R:)')) ("-> " + $m1.Message)
    Check "...the user's default kit, default CMake and aspect filter untouched" `
        (((QtcRead $p 'Profile.Default').value.'#text' -ceq 'user.kit') -and ((QtcRead (Join-Path $uu 'cmaketools.xml') 'CMakeTools.Default').value.'#text' -ceq 'user.cmake') -and
         ((QtcRead $p 'Kit.IrrelevantAspects').OuterXml -ceq ([xml]$userFiles['profiles.xml']).qtcreator.data[0].OuterXml))
    Check "...the user's own kit first and unchanged, counts one up" `
        (((QtcMapVal (QtcRead $p 'Profile.0') 'PE.Profile.Id') -ceq 'user.kit') -and ((QtcRead $p 'Profile.Count').value.'#text' -ceq '2') -and
         ((QtcRead (Join-Path $uu 'toolchains.xml') 'ToolChain.Count').value.'#text' -ceq '3') -and ((QtcRead (Join-Path $uu 'cmaketools.xml') 'CMakeTools.Count').value.'#text' -ceq '2'))
    $ok1 = QtcRead $p 'Profile.1'; $oq = QtcRead (Join-Path $uu 'qtversion.xml') 'QtVersion.1'
    Check "...ours MANUAL: SDK and auto-detection off everywhere" `
        (((QtcMapVal $ok1 'PE.Profile.SDK') -ceq 'false') -and ((QtcMapVal $ok1 'PE.Profile.AutoDetected') -ceq 'false') -and
         ((QtcMapVal (QtcRead (Join-Path $uu 'toolchains.xml') 'ToolChain.2') 'ProjectExplorer.ToolChain.Autodetect') -ceq 'false') -and
         ((QtcMapVal (QtcRead (Join-Path $uu 'debuggers.xml') 'DebuggerItem.1') 'AutoDetected') -ceq 'false') -and
         ((QtcMapVal (QtcRead (Join-Path $uu 'cmaketools.xml') 'CMakeTools.1') 'Autodetect') -ceq 'false') -and ((QtcMapVal $oq 'isAutodetected') -ceq 'false'))
    Check "...its Qt: a new id above the user's, no 'SDK.' source, and the kit pointing at it by that id" `
        (((QtcMapVal $oq 'Id') -ceq '6') -and ((QtcMapVal $oq 'autodetectionSource') -ceq 'drivenv.r.x.qt') -and ((QtcMapVal $ok1 'QtSupport.QtInformation') -ceq '6') -and
         ((QtcMapVal (QtcRead $p 'Profile.0') 'QtSupport.QtInformation') -ceq '5'))
    Check "...and a backup of every file, as it was" (@($userFiles.Keys | Where-Object { [System.IO.File]::ReadAllText((Join-Path $uu "$_.drivenv-t1.bak")) -cne $userFiles[$_] }).Count -eq 0)

    $snap = @{}; foreach ($k in $userFiles.Keys) { $snap[$k] = [System.IO.File]::ReadAllText((Join-Path $uu $k)) }
    $m2 = Merge-DrivEnvQtUserSettings -GeneratedDir $ug -UserDir $uu -OwnPrefix 'drivenv.r.' -Stamp 't2'
    Check "...a re-run changes nothing: this drive's entries replaced, not duplicated" ($m2.Ok -and (@($userFiles.Keys | Where-Object { [System.IO.File]::ReadAllText((Join-Path $uu $_)) -cne $snap[$_] }).Count -eq 0))
    $m3 = Merge-DrivEnvQtUserSettings -GeneratedDir $ue -UserDir $uu -OwnPrefix 'drivenv.r.' -Stamp 't3'
    Check "...no kit any more: this drive's entries removed, the user's back exactly as they were" `
        ($m3.Ok -and ((QtcRead $p 'Profile.Count').value.'#text' -ceq '1') -and ((QtcRead (Join-Path $uu 'toolchains.xml') 'ToolChain.Count').value.'#text' -ceq '1') -and
         ((QtcRead $p 'Profile.0').OuterXml -ceq @(([xml]$userFiles['profiles.xml']).qtcreator.data | Where-Object { $_.variable -eq 'Profile.0' })[0].OuterXml) -and
         ($null -eq (QtcRead (Join-Path $uu 'qtversion.xml') 'QtVersion.1')))
    [System.IO.File]::WriteAllText((Join-Path $uu 'debuggers.xml'), '<qtcreator><data>broken')
    $before = @{}; foreach ($k in $userFiles.Keys) { $before[$k] = [System.IO.File]::ReadAllText((Join-Path $uu $k)) }
    $m4 = Merge-DrivEnvQtUserSettings -GeneratedDir $ug -UserDir $uu -OwnPrefix 'drivenv.r.' -Stamp 't4'
    Check "...a user file it cannot read: refused, and NOTHING written" `
        ((-not $m4.Ok) -and ($m4.Message -match 'debuggers\.xml') -and (@($userFiles.Keys | Where-Object { [System.IO.File]::ReadAllText((Join-Path $uu $_)) -cne $before[$_] }).Count -eq 0))
    # FOUND BY REVIEW: a second run under the same stamp backed its own output up over the only pristine copy.
    [System.IO.File]::WriteAllText((Join-Path $uu 'debuggers.xml'), $userFiles['debuggers.xml'])
    $m6 = Merge-DrivEnvQtUserSettings -GeneratedDir $ug -UserDir $uu -OwnPrefix 'drivenv.r.' -Stamp 't1'
    Check "...a stamp whose backups exist: refused, the backups and the files untouched" `
        ((-not $m6.Ok) -and ($m6.Message -match 'exists already') -and ([System.IO.File]::ReadAllText((Join-Path $uu 'profiles.xml.drivenv-t1.bak')) -ceq $userFiles['profiles.xml']) -and
         ([System.IO.File]::ReadAllText((Join-Path $uu 'profiles.xml')) -ceq $before['profiles.xml']))

    # FOUND BY REVIEW: Qt Creator writes ToolChain.0, .1, .10, .11, .2... and reads them by number; renumbering in
    # file order reordered the user's toolchains. Twelve of theirs in Qt Creator's order, one of this drive's at 5.
    $uo = Join-Path $ut 'order'; New-Item -ItemType Directory -Path $uo -Force | Out-Null
    $tcOf = { param($i) if ($i -eq 5) { 'ProjectExplorer.ToolChain.Mingw:drivenv.r.old.c' } else { "ProjectExplorer.ToolChain.Msvc:{u$i}" } }
    $lex = @(0..12 | ForEach-Object { "$_" } | Sort-Object)
    [System.IO.File]::WriteAllText((Join-Path $uo 'toolchains.xml'), (QtcFile 'QtCreatorToolChains' (@($lex | ForEach-Object { QtcVar "ToolChain.$_" ('<valuemap type="QVariantMap"><value type="QString" key="ProjectExplorer.ToolChain.Id">' + (& $tcOf ([int]$_)) + '</value></valuemap>') }) +
                                                                                                    @((QtcVar 'ToolChain.Count' '<value type="int">13</value>'), (QtcVar 'Version' '<value type="int">1</value>')))))
    $m7 = Merge-DrivEnvQtUserSettings -GeneratedDir $ue -UserDir $uo -OwnPrefix 'drivenv.r.' -Stamp 'o1'
    $tco = Join-Path $uo 'toolchains.xml'
    Check "...the user's toolchains keep their numeric order, the gap this drive's left closed" `
        ($m7.Ok -and ((Joined @(0..11 | ForEach-Object { QtcMapVal (QtcRead $tco "ToolChain.$_") 'ProjectExplorer.ToolChain.Id' })) -ceq (Joined @(0..12 | Where-Object { $_ -ne 5 } | ForEach-Object { & $tcOf $_ }))) -and
         ((QtcRead $tco 'ToolChain.Count').value.'#text' -ceq '12')) ("-> " + $m7.Message)
    $snapO = [System.IO.File]::ReadAllText($tco)
    $m8 = Merge-DrivEnvQtUserSettings -GeneratedDir $ue -UserDir $uo -OwnPrefix 'drivenv.r.' -Stamp 'o2'
    Check "...nothing of this drive's to remove or add: no file written, created or backed up" `
        ($m8.Ok -and ($m8.Message -ceq 'Nothing to change.') -and ([System.IO.File]::ReadAllText($tco) -ceq $snapO) -and (@(Get-ChildItem -LiteralPath $uo -Name).Count -eq 2))

    # FOUND BY REVIEW: Qt Creator keeps the first of EQUAL toolchains in the user file and deletes the rest, so a drive
    # toolchain twin of a manual one of the user's vanished at the next start, and the kit's compilers with it.
    # And a kit with no Qt imported gets QtInformation -1: without the key Qt Creator picks a Qt by ABI.
    $tw = Join-Path $ut 'twin'; $twg = Join-Path $ut 'twingen'; New-Item -ItemType Directory -Path $tw, $twg -Force | Out-Null
    $tcEntry = { param($Var, $Id, $Path, $Lang, $Auto) QtcVar $Var ('<valuemap type="QVariantMap"><value type="QString" key="ProjectExplorer.GccToolChain.Path">' + $Path + '</value>' +
        '<value type="QString" key="ProjectExplorer.GccToolChain.TargetAbi">x86-windows-msys-pe-64bit</value><value type="bool" key="ProjectExplorer.ToolChain.Autodetect">' + $Auto + '</value>' +
        '<value type="QString" key="ProjectExplorer.ToolChain.Id">' + $Id + '</value>' + $Lang + '</valuemap>') }
    [System.IO.File]::WriteAllText((Join-Path $tw 'toolchains.xml'), (QtcFile 'QtCreatorToolChains' @(
        (& $tcEntry 'ToolChain.0' 'ProjectExplorer.ToolChain.Mingw:M2_C' 'X:\msys64\UCRT64\bin\gcc.exe' '<value type="int" key="ProjectExplorer.ToolChain.Language">1</value>' 'false'),
        (& $tcEntry 'ToolChain.1' 'ProjectExplorer.ToolChain.Mingw:auto_cxx' 'X:/msys64/ucrt64/bin/g++.exe' '<value type="QString" key="ProjectExplorer.ToolChain.LanguageV2">Cxx</value>' 'true'),
        (QtcVar 'ToolChain.Count' '<value type="int">2</value>'), (QtcVar 'Version' '<value type="int">1</value>'))))
    [System.IO.File]::WriteAllText((Join-Path $tw 'profiles.xml'), (QtcFile 'QtCreatorProfiles' @((QtcVar 'Profile.Count' '<value type="int">0</value>'), (QtcVar 'Version' '<value type="int">1</value>'))))
    [System.IO.File]::WriteAllText((Join-Path $twg 'toolchains.xml'), (QtcFile 'QtCreatorToolChains' @(
        (& $tcEntry 'ToolChain.0' 'ProjectExplorer.ToolChain.Mingw:drivenv.x.u.c' 'X:/msys64/ucrt64/bin/gcc.exe' '<value type="QString" key="ProjectExplorer.ToolChain.LanguageV2">C</value>' 'true'),
        (& $tcEntry 'ToolChain.1' 'ProjectExplorer.ToolChain.Mingw:drivenv.x.u.cxx' 'X:/msys64/ucrt64/bin/g++.exe' '<value type="QString" key="ProjectExplorer.ToolChain.LanguageV2">Cxx</value>' 'true'),
        (QtcVar 'ToolChain.Count' '<value type="int">2</value>'), (QtcVar 'Version' '<value type="int">1</value>'))))
    [System.IO.File]::WriteAllText((Join-Path $twg 'profiles.xml'), (QtcFile 'QtCreatorProfiles' @(
        (QtcVar 'Profile.0' ('<valuemap type="QVariantMap"><valuemap type="QVariantMap" key="PE.Profile.Data"><valuemap type="QVariantMap" key="PE.Profile.ToolChainsV3">' +
            '<value type="QString" key="C">ProjectExplorer.ToolChain.Mingw:drivenv.x.u.c</value><value type="QString" key="Cxx">ProjectExplorer.ToolChain.Mingw:drivenv.x.u.cxx</value></valuemap></valuemap>' +
            '<value type="QString" key="PE.Profile.Id">drivenv.x.u</value><value type="QString" key="PE.Profile.Name">U (X:)</value></valuemap>')),
        (QtcVar 'Profile.Count' '<value type="int">1</value>'), (QtcVar 'Version' '<value type="int">1</value>'))))
    $m9 = Merge-DrivEnvQtUserSettings -GeneratedDir $twg -UserDir $tw -OwnPrefix 'drivenv.x.' -Stamp 'w1'
    $twt = Join-Path $tw 'toolchains.xml'; $twk = QtcRead (Join-Path $tw 'profiles.xml') 'Profile.0'
    Check "...a drive toolchain equal to a MANUAL one of the user's is not imported: the kit uses the user's" `
        ($m9.Ok -and ((QtcRead $twt 'ToolChain.Count').value.'#text' -ceq '3') -and
         ((Joined @(0..2 | ForEach-Object { QtcMapVal (QtcRead $twt "ToolChain.$_") 'ProjectExplorer.ToolChain.Id' })) -ceq 'ProjectExplorer.ToolChain.Mingw:M2_C|ProjectExplorer.ToolChain.Mingw:auto_cxx|ProjectExplorer.ToolChain.Mingw:drivenv.x.u.cxx') -and
         ((QtcMapVal $twk 'C') -ceq 'ProjectExplorer.ToolChain.Mingw:M2_C') -and ((QtcMapVal $twk 'Cxx') -ceq 'ProjectExplorer.ToolChain.Mingw:drivenv.x.u.cxx')) ("-> " + $m9.Message)
    Check "...a kit without a Qt of its own: QtInformation -1, an int; and no qtversion.xml created for nothing" `
        (($twk.SelectSingleNode(".//*[@key='QtSupport.QtInformation']").OuterXml -ceq '<value type="int" key="QtSupport.QtInformation">-1</value>') -and
         (-not (Test-Path -LiteralPath (Join-Path $tw 'qtversion.xml'))) -and (-not (Test-Path -LiteralPath (Join-Path $tw 'debuggers.xml'))))

    # With the real sdktool's own output, when there is one: what Qt Creator would actually be handed.
    if ($env:DRIVENV_TEST_SDKTOOL -and (Test-Path -LiteralPath $env:DRIVENV_TEST_SDKTOOL))
    {
        $rg = Join-Path $ut 'realgen'; $ru = Join-Path $ut 'realuser'; New-Item -ItemType Directory -Path $rg, $ru -Force | Out-Null
        foreach ($k in $userFiles.Keys) { [System.IO.File]::WriteAllText((Join-Path $ru $k), $userFiles[$k]) }
        $rs = Get-DrivEnvQtKitSpec -Names $nc -EnvValues $kv -Family 'clang' -KitName 'DegorasSLR clang64 (N:)' -IdPrefix 'drivenv.n.' -QMake 'N:/vcpkg/installed/x64-mingw-clang-dynamic-release/tools/Qt6/bin/qmake6.exe'
        foreach ($c in (ConvertTo-DrivEnvSdktoolCalls -Spec $rs -SdkPath $rg)) { $null = Invoke-DrivEnvNative -FilePath $env:DRIVENV_TEST_SDKTOOL -Arguments $c }
        $m5 = Merge-DrivEnvQtUserSettings -GeneratedDir $rg -UserDir $ru -OwnPrefix 'drivenv.n.' -Stamp 't5'
        $rk = QtcRead (Join-Path $ru 'profiles.xml') 'Profile.1'
        Check "...with real sdktool output: merged, manual, its Qt by id, the user's default kit kept" `
            ($m5.Ok -and ((QtcMapVal $rk 'PE.Profile.Id') -ceq 'drivenv.n.degorasslr_clang64') -and ((QtcMapVal $rk 'PE.Profile.SDK') -ceq 'false') -and
             ((QtcMapVal $rk 'QtSupport.QtInformation') -ceq '6') -and ((QtcRead (Join-Path $ru 'profiles.xml') 'Profile.Default').value.'#text' -ceq 'user.kit')) ("-> " + $m5.Message)
    }
}
finally { Remove-Item -LiteralPath $ut -Recurse -Force -ErrorAction SilentlyContinue }

# The env file as Qt Creator gets it: expanded the bootstrap's way, Windows paths kept.
$ev = Resolve-DrivEnvEnvValues -Lines @('A=N:', 'B=${A}/x', 'C="q r"', '# c', 'D=$A/$B', 'E=${LATER}', 'LATER=late', "F=1`r")
Check "expanded top to bottom, quotes stripped, a forward reference empty" `
    (($ev['B'] -ceq 'N:/x') -and ($ev['C'] -ceq 'q r') -and ($ev['D'] -ceq 'N:/N:/x') -and ($ev['E'] -ceq '') -and ($ev['F'] -ceq '1') -and (-not $ev.Contains('# c')))
# FOUND BY REVIEW: the bootstrap's ${!name-} falls back to the inherited environment, so this must too.
$env:DRIVENV_TEST_INHERITED = 'C:/inh'
$evi = Resolve-DrivEnvEnvValues -Lines @('A=$DRIVENV_TEST_INHERITED/x', 'B=${DRIVENV_TEST_INHERITED}', 'DRIVENV_TEST_INHERITED=file', 'C=${DRIVENV_TEST_INHERITED}')
Remove-Item Env:DRIVENV_TEST_INHERITED
Check "...a name the file does not define taken from the environment, the file's own winning once defined" `
    (($evi['A'] -ceq 'C:/inh/x') -and ($evi['B'] -ceq 'C:/inh') -and ($evi['C'] -ceq 'file'))

# The kit.
$kv = Resolve-DrivEnvEnvValues -Lines @('DEVDRIVE_LETTER=N:', 'DEVSYSTEM_TOOLCHAIN_ROOT=N:/msys64/clang64', 'DEVSYSTEM_TOOLCHAIN_ID=clang64', 'VCPKG_ROOT=N:/vcpkg',
                                        'VCPKG_DEFAULT_TRIPLET=x64-mingw-clang-dynamic-release', 'VCPKG_BIN=${VCPKG_ROOT}/installed/${VCPKG_DEFAULT_TRIPLET}/bin',
                                        'DEVSYSTEM_BUILDTREES=${DEVDRIVE_LETTER}/bt/${VCPKG_DEFAULT_TRIPLET}', 'MY_SDK=C:/sdk', 'BASE_PATH=/clang64/bin:/usr/bin', 'PATH=${VCPKG_BIN}:${BASE_PATH}',
                                        'MSYS2_ENV=clang64', 'MSYS2_ROOT=N:/msys64')
$ks = Get-DrivEnvQtKitSpec -Names $nc -EnvValues $kv -Family 'clang' -Arch 'x86_64' -KitName 'DegorasSLR clang64' -CustomNames @('MY_SDK') -CustomPathEntries @('${MY_SDK}/bin') `
                           -ToolDirs @('N:/vcpkg/installed/x64-mingw-clang-dynamic-release/tools/gstreamer')
Check "kit ids carry the stem"                          (($ks.KitId -ceq 'drivenv.degorasslr_clang64') -and ($ks.CId -ceq 'ProjectExplorer.ToolChain.Mingw:drivenv.degorasslr_clang64.c') -and ($ks.DebuggerId -ceq 'drivenv.degorasslr_clang64.gdb'))
Check "clang's compilers, gdb and cmake, MSYS2's ABI"   (($ks.CCompiler -ceq 'N:/msys64/clang64/bin/clang.exe') -and ($ks.CxxCompiler -ceq 'N:/msys64/clang64/bin/clang++.exe') -and ($ks.Gdb -ceq 'N:/msys64/clang64/bin/gdb.exe') -and ($ks.Abi -ceq 'x86-windows-msys-pe-64bit'))
$kg = Get-DrivEnvQtKitSpec -Names $nc -EnvValues $kv -Family 'gcc' -Arch 'i686' -KitName 'k'
Check "...gcc's for the gcc family, and a 32-bit ABI for i686" (($kg.CCompiler -like '*/gcc.exe') -and ($kg.CxxCompiler -like '*/g++.exe') -and ($kg.Abi -ceq 'x86-windows-msys-pe-32bit'))
Check "CMake: the vcpkg toolchain file and the triplet, compilers by Qt Creator's own macros" `
    (($ks.CMakeConfig -ccontains 'CMAKE_TOOLCHAIN_FILE:FILEPATH=N:/vcpkg/scripts/buildsystems/vcpkg.cmake') -and ($ks.CMakeConfig -ccontains 'VCPKG_TARGET_TRIPLET:STRING=x64-mingw-clang-dynamic-release') -and
     ($ks.CMakeConfig -ccontains 'CMAKE_CXX_COMPILER:FILEPATH=%{Compiler:Executable:Cxx}'))
Check "environment: the contract expanded, the custom variables, no MSYS2 internals" `
    (($ks.Env -ccontains 'DEVSYSTEM_BUILDTREES=N:/bt/x64-mingw-clang-dynamic-release') -and ($ks.Env -ccontains 'MY_SDK=C:/sdk') -and
     (@($ks.Env | Where-Object { $_ -like 'BASE_PATH=*' -or $_ -like 'MSYS2_*' }).Count -eq 0))
# FOUND BY REVIEW: the triplets hash MSYSTEM into every ABI; a kit without it would not reuse the shell's builds.
Check "...but MSYSTEM, as the shell has it"              ((@($ks.Env | Where-Object { $_ -like 'MSYSTEM=*' }) -join '|') -ceq 'MSYSTEM=CLANG64')
# FOUND BY REVIEW: the toolchain bin first let MSYS2's own Qt6 and OpenSSL DLLs shadow vcpkg's when running.
Check "PATH prefixed in the launcher's order: vcpkg bin and root, custom entries, tool dirs, toolchain bin last" `
    ($ks.Env -ccontains 'PATH=+N:/vcpkg/installed/x64-mingw-clang-dynamic-release/bin;N:/vcpkg;C:/sdk/bin;N:/vcpkg/installed/x64-mingw-clang-dynamic-release/tools/gstreamer;N:/msys64/clang64/bin')

# A toolchain not ready for a kit: an env file from step 2 alone has no vcpkg.
$tvk = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-vk-" + [guid]::NewGuid().ToString('N'))
try
{
    New-Item -ItemType Directory -Path (Join-Path $tvk 'scripts\buildsystems') -Force | Out-Null
    $vk = $tvk -replace '\\', '/'
    # FOUND BY REVIEW: such a toolchain got a kit configuring against /scripts/buildsystems/vcpkg.cmake.
    Check "no kit from an env file without VCPKG_ROOT"     ((Get-DrivEnvQtKitProblem -EnvValues (Resolve-DrivEnvEnvValues -Lines @('DEVSYSTEM_TOOLCHAIN_ID=clang64'))) -like '*no VCPKG_ROOT*')
    Check "...nor without a triplet"                       ((Get-DrivEnvQtKitProblem -EnvValues (Resolve-DrivEnvEnvValues -Lines @("VCPKG_ROOT=$vk"))) -like '*no VCPKG_DEFAULT_TRIPLET*')
    Check "...nor without vcpkg.cmake"                     ((Get-DrivEnvQtKitProblem -EnvValues (Resolve-DrivEnvEnvValues -Lines @("VCPKG_ROOT=$vk", 'VCPKG_DEFAULT_TRIPLET=t'))) -like '*vcpkg toolchain file is missing*')
    [System.IO.File]::WriteAllText((Join-Path $tvk 'scripts\buildsystems\vcpkg.cmake'), '')
    Check "...and ready once all three are there"          ((Get-DrivEnvQtKitProblem -EnvValues (Resolve-DrivEnvEnvValues -Lines @("VCPKG_ROOT=$vk", 'VCPKG_DEFAULT_TRIPLET=t'))) -ceq '')

    # The tool directories, as the bootstrap finds them: an .exe at the first or second level, nothing empty.
    $tt = Join-Path $tvk 'installed\t\tools'
    foreach ($d in 'gstreamer', 'Qt6\bin', 'empty', 'icu\bin', 'docs') { New-Item -ItemType Directory -Path (Join-Path $tt $d) -Force | Out-Null }
    foreach ($f in 'gstreamer\gst-launch-1.0.exe', 'Qt6\bin\moc.exe', 'icu\bin\genrb.exe', 'docs\readme.txt') { [System.IO.File]::WriteAllText((Join-Path $tt $f), '') }
    Check "vcpkg tool dirs: an .exe at either level, first level first, forward-slashed" `
        ((Joined (Get-DrivEnvVcpkgToolDirs -VcpkgRoot $vk -Triplet 't')) -ceq "$vk/installed/t/tools/gstreamer|$vk/installed/t/tools/icu/bin|$vk/installed/t/tools/Qt6/bin")
    Check "...and none for a triplet with no tools"        (@(Get-DrivEnvVcpkgToolDirs -VcpkgRoot $vk -Triplet 'other').Count -eq 0)
}
finally { Remove-Item -LiteralPath $tvk -Recurse -Force -ErrorAction SilentlyContinue }

# FOUND BY REVIEW: PowerShell 5.1 passes 'X=C:\My Tool\' as 'X=C:\My Tool"', swallowing the next arguments.
Check "native quoting: a space and a trailing backslash"  ((ConvertTo-DrivEnvNativeArgument -Argument 'X=C:\My Tool\') -ceq '"X=C:\My Tool\\"')
Check "...an embedded quote, backslashes before it"       ((ConvertTo-DrivEnvNativeArgument -Argument 'a\"b c') -ceq '"a\\\"b c"')
Check "...an empty argument, and a plain one left alone" (((ConvertTo-DrivEnvNativeArgument -Argument '') -ceq '""') -and ((ConvertTo-DrivEnvNativeArgument -Argument 'N:\a\b\') -ceq 'N:\a\b\'))

# The sdktool calls.
$calls = ConvertTo-DrivEnvSdktoolCalls -Spec $ks -SdkPath 'S:\x'
Check "compilers, debugger and cmake before the kit that refers to them" ((Joined @($calls | ForEach-Object { $_[1] })) -ceq 'addTC|addTC|addDebugger|addCMake|addKit')
# FOUND IN USE: without a Qt of its own, Qt Creator gave BOTH kits the ucrt vcpkg Qt from the launcher's PATH, and
# warned that no CMAKE_PREFIX_PATH pointed to it.
Check "no vcpkg Qt: no Qt registered, no --qt, no CMAKE_PREFIX_PATH" `
    (($ks.QtId -ceq '') -and (@($calls[4] | Where-Object { $_ -ceq '--qt' }).Count -eq 0) -and (@($ks.CMakeConfig | Where-Object { $_ -like 'CMAKE_PREFIX_PATH*' }).Count -eq 0))
$kqt = Get-DrivEnvQtKitSpec -Names $nc -EnvValues $kv -Family 'clang' -KitName 'DegorasSLR clang64' -QMake 'N:/vcpkg/installed/x64-mingw-clang-dynamic-release/tools/Qt6/bin/qmake6.exe'
$cqt = ConvertTo-DrivEnvSdktoolCalls -Spec $kqt -SdkPath 'S:\x'
Check "with its vcpkg Qt: the Qt registered before the kit, the kit pointing at it, CMAKE_PREFIX_PATH at its prefix" `
    (((Joined @($cqt | ForEach-Object { $_[1] })) -ceq 'addTC|addTC|addDebugger|addCMake|addQt|addKit') -and
     (($cqt[4] -join ' ') -match '--id drivenv\.degorasslr_clang64\.qt .*--qmake N:/vcpkg/installed/x64-mingw-clang-dynamic-release/tools/Qt6/bin/qmake6\.exe --type Qt4ProjectManager\.QtVersion\.Desktop') -and
     (($cqt[5] -join ' ') -match '--qt drivenv\.degorasslr_clang64\.qt') -and ($kqt.CMakeConfig -ccontains 'CMAKE_PREFIX_PATH:PATH=%{Qt:QT_INSTALL_PREFIX}'))
Check "every call carries the sdkpath"                  (@($calls | Where-Object { $_[0] -cne '--sdkpath=S:\x' }).Count -eq 0)
Check "the kit names its parts, Ninja, every config and env entry" `
    ((($calls[4] -join ' ') -match '--Ctoolchain ProjectExplorer\.ToolChain\.Mingw:drivenv\.degorasslr_clang64\.c --Cxxtoolchain') -and (($calls[4] -join ' ') -match '--cmake-generator Ninja') -and
     (@($calls[4] | Where-Object { $_ -ceq '--env' }).Count -eq $ks.Env.Count) -and (@($calls[4] | Where-Object { $_ -ceq '--cmake-config' }).Count -eq $ks.CMakeConfig.Count))

# Step 7 wired: what -ValidateOnly prints, and what the source shows it does.
$r7 = & { $ErrorActionPreference = 'Continue'; & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\7-Setup_IDE.ps1') -ConfigFile (Join-Path $cfgDir 'drivenv-cfg_example.json') -ValidateOnly 2>&1 | ForEach-Object { "$_" } }
Check "step 7 -ValidateOnly names Qt Creator and a kit per toolchain" `
    ((@($r7 | Where-Object { $_ -like '*Qt Creator (msys2): R:\msys64\ucrt64\bin\qtcreator.exe*' }).Count -eq 1) -and (@($r7 | Where-Object { $_ -like "*Kit for toolchain*" }).Count -eq 2))
$src7 = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\7-Setup_IDE.ps1')
Check "step 7 rebuilds the drive's kit files; sdktool writes only there and into a scratch directory, never the user's" `
    (($src7 -match "Remove-Item -LiteralPath \(Join-Path \`$qt\.SdkPath \`$xml\)") -and
     (@([regex]::Matches($src7, 'ConvertTo-DrivEnvSdktoolCalls -Spec \$\w+ -SdkPath (\$[\w.]+)') | Where-Object { $_.Groups[1].Value -notin @('$qt.SdkPath', '$genDir') }).Count -eq 0) -and
     (@([regex]::Matches($src7, 'ConvertTo-DrivEnvSdktoolCalls -Spec')).Count -eq 2) -and
     ($src7 -notmatch '(?m)^[^#]*(\$env:APPDATA|%APPDATA%|UserSettingsPath)'))
Check "...and the user's own Qt Creator only through the merge, only when asked, never while it runs" `
    (($src7 -match 'if \(-not \$qt\.RegisterInUserSettings\)') -and ($src7 -match "Win32_Process -Filter `"Name='qtcreator\.exe'`"") -and
     ($src7 -match 'Merge-DrivEnvQtUserSettings -GeneratedDir \$genDir -UserDir \$qt\.UserQtSettingsDir -OwnPrefix \$qt\.UserIdPrefix'))
# FOUND BY REVIEW: the user's Qt Creator runs on the machine's PATH, where a vcpkg qmake6.exe cannot start (its runtime
# DLLs are in the drive's msys64), so a kit Qt registered there is invalid.
Check "...whose kits get no Qt: the user's specs are built without -QMake" `
    (($src7 -match '-ToolDirs \$r\.ToolDirs -IdPrefix \$qt\.UserIdPrefix') -and ($src7 -notmatch '(?m)^[^#]*-QMake[^\r\n]*-IdPrefix'))
Check "...creates QtCreator.ini, skips a toolchain without vcpkg, and runs sdktool through the safe quoting" `
    (($src7 -match 'WriteAllText\(\$qt\.InstallIni') -and ($src7 -match 'Get-DrivEnvQtKitProblem -EnvValues \$values') -and ($src7 -match 'Invoke-DrivEnvNative -FilePath \$Sdktool') -and
     ($src7 -notmatch '(?m)^[^#]*& \$Sdktool'))
Check "...and with source msys2, a Qt Creator whose toolchain is not on the drive yet is said, not failed" `
    ($src7 -match '\(\$null -eq \$qt\.Holder\) -or \(-not \(Test-Path -LiteralPath \$qt\.Holder\.EnvFile\)\)')
Check "...and doubles '%' in what it writes into the .bat"  ($src7 -match "Replace\('%', '%%'\)")
# FOUND BY REVIEW: a minimised shortcut hid the launcher's error and its pause.
Check "...and its shortcuts open the launcher in a normal window" (($src7 -match 'WindowStyle\s+= 1') -and ($src7 -notmatch 'WindowStyle\s+= 7'))
# Owner decision 2026-10-15: one launcher per toolchain, opening the one Qt Creator in that toolchain's environment.
Check "...and deploys, per toolchain with a kit, the launcher, its launch script and its shortcuts" `
    (($src7 -match 'foreach \(\$t in \$withKit\)') -and ($src7 -match 'WriteAllText\(\$n\.QtLauncher, \$bat') -and ($src7 -match 'WriteAllText\(\$n\.QtLauncherTail, \$sh') -and
     ($src7 -match '\$targets = @\(\$n\.QtShortcut\)') -and ($src7 -match 'QtDesktopShortcutName'))
Check "...after removing an earlier run's, only this drive's Qt Creator ones by name" `
    ($src7 -match '\^\$\{prefixRx\}\(_\[A-Za-z0-9\]\+\)\?_qtcreator\(\\\.bat\|_launcher\\\.sh\)\$')
$tplQt = Get-Content -Raw -LiteralPath (Join-Path $root 'drive\launchers\qtcreator_launcher.bat')
$tplQtSh = [System.IO.File]::ReadAllText((Join-Path $root 'drive\launchers\qtcreator_launcher.sh'))
Check "the launcher template no longer promises kits to the Start menu's Qt Creator" ($tplQt -notmatch 'adds the kits there')
Check "the launcher template finds everything from <stem>_qtcreator, and fills three paths" `
    (($tplQt -match 'SELF:~-10%"=="_qtcreator"') -and ($tplQt -match '%STEM%_env_launcher_bootstrap\.sh') -and ($tplQt -match '%STEM%_qtcreator_launcher\.sh') -and
     ($tplQt -match '@QTCREATOR_EXE@') -and ($tplQt -match '@SETTINGS_PATH@') -and ($tplQt -match '@INSTALL_SETTINGS_PATH@'))
Check "...loads the environment through MSYS2 in its own window, waits, and sources the bootstrap then the launch script" `
    (($tplQt -match 'call "%MSYS2_SHELL%" -%MSYS2_ENV% -defterm -no-start -here -c "bash -lc ''') -and ($tplQt -match '\. \$DP_BOOTSTRAP; \. \$DP_QTC_LAUNCH') -and
     ($tplQt -match 'if not "%DP_RC%"=="0"'))
Check "the launch script starts Qt Creator with the drive's two settings paths, detached" `
    (($tplQtSh -match '"\$qtc_exe" -settingspath "\$qtc_settings" -installsettingspath "\$qtc_install"') -and ($tplQtSh -match '(?m)^disown$') -and (-not $tplQtSh.Contains("`r")))
# FOUND BY REVIEW: a plain '&' left MSYS2's stub bash on the launcher's console, so its window stayed for the whole
# session; setsid, as the earlier launcher had it, gives the stub a console of its own.
Check "...through setsid when MSYS2 has it"              ($tplQtSh -match '(?m)^  setsid "\$qtc_exe" -settingspath')
Check "...and the .bat quotes what it echoes"            (($tplQt -match 'echo \[INFO\] Qt Creator: "%QTC_EXE%"') -and ($tplQt -notmatch 'echo \[INFO\] Qt Creator: %QTC_EXE%'))
# FOUND BY REVIEW: a toolchain that lost its launcher kept a desktop shortcut pointing at nothing.
Check "step 7 removes desktop shortcuts to this drive's Qt launchers that are gone, by target" `
    (($src7 -match 'CreateShortcut\(\$lnk\.FullName\)\.TargetPath') -and ($src7 -match '\$isOurs -and -not \(Test-Path -LiteralPath \$target\)'))

# THE LAUNCHER ITSELF, through cmd, as section 32 runs the shell launcher: each refusal, in a path with a space and a '!'.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-qtl-" + [guid]::NewGuid().ToString('N') + " with space!")
$env:DEV_ENV_NO_PAUSE = '1'
try
{
    function RunQtBat { param([string]$Bat) $ErrorActionPreference = 'Continue'; $o = & cmd.exe /d /c ('"' + $Bat + '"') 2>&1 | ForEach-Object { "$_" }; return @{ Out = ($o -join "`n"); Code = $LASTEXITCODE } }
    $ld = Join-Path $tmp 'env\launcher'
    New-Item -ItemType Directory -Path $ld -Force | Out-Null
    $fakeExe = Join-Path $tmp 'qtc\fake_qtcreator.sh'
    New-Item -ItemType Directory -Path (Split-Path -Parent $fakeExe) -Force | Out-Null
    $filled = $tplQt.Replace('@QTCREATOR_EXE@', $fakeExe).Replace('@SETTINGS_PATH@', (Join-Path $tmp 'env\qtcreator\settings')).Replace('@INSTALL_SETTINGS_PATH@', (Join-Path $tmp 'env\qtcreator\install'))

    [System.IO.File]::WriteAllText((Join-Path $ld 'qtcreator.bat'), $filled)
    $r = RunQtBat (Join-Path $ld 'qtcreator.bat')
    Check "Qt launcher: not named <stem>_qtcreator.bat, refused" (($r.Code -eq 1) -and ($r.Out -match 'must be named')) ("-> " + $r.Out)
    $qbat = Join-Path $ld 'abc_clang64_qtcreator.bat'
    [System.IO.File]::WriteAllText($qbat, $filled)
    $r = RunQtBat $qbat
    Check "...no env file: refused, naming <stem>_env_variables.env one directory up" (($r.Code -eq 1) -and $r.Out.Contains((Join-Path $tmp 'env\abc_clang64_env_variables.env'))) ("-> " + $r.Out)
    $fakeMsys = Join-Path $tmp 'msys'
    New-Item -ItemType Directory -Path $fakeMsys -Force | Out-Null
    $vroot = (Join-Path $tmp 'vcpkg') -replace '\\', '/'
    # MSYS2's 'shell' helper, which the bootstrap requires, stands in a directory of its own, on the env file's
    # BASE_PATH -- the PATH the bootstrap sets -- where MSYS2's /usr/bin would have it.
    $shim = Join-Path $tmp 'shim'
    New-Item -ItemType Directory -Path $shim -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $shim 'shell'), "#!/bin/sh`n:`n")
    $shimPosix = '/' + $shim.Substring(0, 1).ToLowerInvariant() + ($shim.Substring(2) -replace '\\', '/')
    [System.IO.File]::WriteAllText((Join-Path $tmp 'env\abc_clang64_env_variables.env'),
        ("DEVDRIVE_LETTER={0}`nDEVSYSTEM_NAME=T`nDEVSYSTEM_TOOLCHAIN_ID=clang64`nMSYS2_ROOT={1}`nMSYS2_ENV=clang64`nVCPKG_ROOT={2}`nLIST_VALUE=/a:/b`nBASE_PATH=/usr/bin:{3}`nPATH=`${{VCPKG_ROOT}}:`${{BASE_PATH}}`n" -f ($tmp -replace '\\', '/'), ($fakeMsys -replace '\\', '/'), $vroot, $shimPosix))
    $r = RunQtBat $qbat
    Check "...no env bootstrap: refused, naming step 2's <stem>_env_launcher_bootstrap.sh" (($r.Code -eq 1) -and $r.Out.Contains((Join-Path $ld 'abc_clang64_env_launcher_bootstrap.sh'))) ("-> " + $r.Out)
    Copy-Item -LiteralPath (Join-Path $root 'drive\launchers\env_launcher_bootstrap.sh') -Destination (Join-Path $ld 'abc_clang64_env_launcher_bootstrap.sh')
    $r = RunQtBat $qbat
    Check "...no launch script: refused, naming step 7's <stem>_qtcreator_launcher.sh" (($r.Code -eq 1) -and $r.Out.Contains((Join-Path $ld 'abc_clang64_qtcreator_launcher.sh'))) ("-> " + $r.Out)
    [System.IO.File]::WriteAllText((Join-Path $ld 'abc_clang64_qtcreator_launcher.sh'), $tplQtSh)
    $r = RunQtBat $qbat
    Check "...no Qt Creator: refused, naming it"            (($r.Code -eq 1) -and ($r.Out -match 'Qt Creator not found') -and $r.Out.Contains($fakeExe)) ("-> " + $r.Out)
    [System.IO.File]::WriteAllText($fakeExe, "#!/bin/sh`nprintf '%s\n' ""ARGS=`$*"" ""VCPKG_ROOT=`$VCPKG_ROOT"" ""LIST_VALUE=`$LIST_VALUE"" ""DP_QTC_EXE=`${DP_QTC_EXE-unset}"" > ""`$(dirname ""`$0"")/ran.txt""`n")
    $r = RunQtBat $qbat
    Check "...its own env file's MSYS2 root, and no msys2_shell.cmd there: refused, naming it" (($r.Code -eq 1) -and $r.Out.Contains((Join-Path $fakeMsys 'msys2_shell.cmd'))) ("-> " + $r.Out)

    # THE WHOLE CHAIN, when there is a bash to stand in for MSYS2's: the real .bat, a stand-in msys2_shell.cmd that runs
    # that bash with the subsystem the .bat asked for, the REAL env bootstrap and the REAL launch script, and a stand-in
    # Qt Creator that writes down what it was given. Only msys2_shell.cmd, MSYS2's 'shell' helper and Qt Creator are
    # fakes. Section 33 found the bash.
    if ($testBash)
    {
        $bashDir = Split-Path -Parent $testBash
        [System.IO.File]::WriteAllText((Join-Path $fakeMsys 'msys2_shell.cmd'),
            ("@echo off`r`nif /i not ""%~1""==""-clang64"" exit /b 9`r`nset ""MSYSTEM=CLANG64""`r`nset ""MSYS2_PATH_TYPE=inherit""`r`nset ""PATH={0};{1};%PATH%""`r`n""{2}"" -c %6`r`nexit /b %ERRORLEVEL%`r`n" -f $shim, $bashDir, $testBash))
        $r = RunQtBat $qbat
        $ran = Join-Path (Split-Path -Parent $fakeExe) 'ran.txt'
        for ($i = 0; ($i -lt 50) -and -not (Test-Path -LiteralPath $ran); $i++) { Start-Sleep -Milliseconds 200 }
        $got = if (Test-Path -LiteralPath $ran) { [System.IO.File]::ReadAllText($ran) } else { '(Qt Creator never started)' }
        Check "the whole chain: the .bat succeeds, and Qt Creator is started from the loaded environment" ($r.Code -eq 0) ("-> " + $r.Out)
        Check "...with the drive's two settings paths"           ($got -match ('ARGS=-settingspath ' + [regex]::Escape(((Join-Path $tmp 'env\qtcreator\settings') -replace '\\', '/')) + ' -installsettingspath ' + [regex]::Escape(((Join-Path $tmp 'env\qtcreator\install') -replace '\\', '/')))) ("-> " + $got)
        Check "...a drive path back in Windows form, a list left alone" (($got -match ('VCPKG_ROOT=' + [regex]::Escape($vroot.Substring(0, 1).ToUpperInvariant() + $vroot.Substring(1)) + '(\r?\n)')) -and ($got -match 'LIST_VALUE=/a:/b')) ("-> " + $got)
        Check "...and none of the hand-offs"                     ($got -match 'DP_QTC_EXE=unset') ("-> " + $got)
    }
    else
    {
        $script:skip++; Write-Host "  SKIP  no MSYS2 or Git bash found (set DRIVENV_TEST_BASH); the Qt launcher chain did not run"
    }
}
finally
{
    Remove-Item Env:DEV_ENV_NO_PAUSE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# Against a real sdktool, when one is given: the calls register and re-register without duplicating.
$sdkExe = $env:DRIVENV_TEST_SDKTOOL
if ($sdkExe -and (Test-Path -LiteralPath $sdkExe))
{
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-sdk-" + [guid]::NewGuid().ToString('N'))
    try
    {
        # A custom value with a space and a trailing backslash, and an embedded quote: the arguments PowerShell 5.1
        # itself would have mangled.
        $kq = Get-DrivEnvQtKitSpec -Names $nc -EnvValues (Resolve-DrivEnvEnvValues -Lines (@($kv.Keys | ForEach-Object { "$_=$($kv[$_])" }) + 'MY_TOOL="C:\My Tool\"' + 'MY_Q=say "hi"')) `
                                   -Family 'clang' -KitName 'DegorasSLR clang64' -CustomNames @('MY_TOOL', 'MY_Q') -CustomPathEntries @('${MY_TOOL}') `
                                   -QMake 'N:/vcpkg/installed/x64-mingw-clang-dynamic-release/tools/Qt6/bin/qmake6.exe'
        $codes = @()
        foreach ($c in (ConvertTo-DrivEnvSdktoolCalls -Spec $kq -SdkPath $tmp)) { $codes += (Invoke-DrivEnvNative -FilePath $sdkExe -Arguments $c).ExitCode }
        Check "a real sdktool takes every call"          (@($codes | Where-Object { $_ -ne 0 }).Count -eq 0) ("-> " + ($codes -join ','))
        $prof = [System.IO.File]::ReadAllText((Join-Path $tmp 'profiles.xml'))
        Check "...one kit, its values whole: the trailing backslash, the quote, PATH its own item" `
            ((@([regex]::Matches($prof, 'key="PE.Profile.Id"')).Count -eq 1) -and $prof.Contains('<value type="QString">MY_TOOL=C:\My Tool\</value>') -and
             $prof.Contains('MY_Q=say &quot;hi&quot;') -and $prof.Contains('<value type="QString">PATH=+N:/vcpkg/installed/x64-mingw-clang-dynamic-release/bin;N:/vcpkg;C:\My Tool\;N:/msys64/clang64/bin</value>'))
        $qtv = [System.IO.File]::ReadAllText((Join-Path $tmp 'qtversion.xml'))
        Check "...and its own Qt: registered with the vcpkg qmake, and the kit's Qt" `
            ($qtv.Contains('<value type="QString" key="QMakePath">N:/vcpkg/installed/x64-mingw-clang-dynamic-release/tools/Qt6/bin/qmake6.exe</value>') -and
             $prof.Contains('<value type="QString" key="QtSupport.QtInformation">SDK.drivenv.degorasslr_clang64.qt</value>'))
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
else
{
    $script:skip++; Write-Host "  SKIP  no sdktool (set DRIVENV_TEST_SDKTOOL to one, e.g. <msys64>\ucrt64\bin\sdktool.exe); the real registration did not run"
}

Write-Host "=== 41. HELPER SCRIPTS: Restore-QtCreatorSettings.ps1 and Remove-DevDrive.ps1 ==="
# Restore, against a settings directory of its own: list, take a drive's kits out, put a backup set back.
$hs = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-restore-" + [guid]::NewGuid().ToString('N'))
try
{
    $hq = Join-Path $hs 'QtProject\qtcreator'; New-Item -ItemType Directory -Path $hq, (Join-Path $hs 'gen') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $hs 'QtProject\QtCreator.ini'), '')
    foreach ($k in $userFiles.Keys) { [System.IO.File]::WriteAllText((Join-Path $hq $k), $userFiles[$k]); [System.IO.File]::WriteAllText((Join-Path $hs "gen\$k"), $genFiles[$k]) }
    $null = Merge-DrivEnvQtUserSettings -GeneratedDir (Join-Path $hs 'gen') -UserDir $hq -OwnPrefix 'drivenv.r.' -Stamp '20261019_100000'
    $restore = Join-Path $root 'tools\Restore-QtCreatorSettings.ps1'
    function RunRestore { param([string[]]$A) $ErrorActionPreference = 'Continue'; $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $restore -SettingsPath (Join-Path $hs 'QtProject') @A 2>&1 | ForEach-Object { "$_" }; return @{ Out = ($o -join "`n"); Code = $LASTEXITCODE } }
    $r = RunRestore @()
    Check "restore script: lists the backup set and the drive's kits, changes nothing" (($r.Code -eq 0) -and ($r.Out -match '20261019_100000') -and ($r.Out -match 'R:\s+X \(R:\)')) ("-> " + $r.Out)
    $r = RunRestore @('-RemoveDrive', 'R', '-Force')
    Check "...-RemoveDrive: the drive's kit out, the user's kit kept" (($r.Code -eq 0) -and ((QtcRead (Join-Path $hq 'profiles.xml') 'Profile.Count').value.'#text' -ceq '1') -and
        ((QtcMapVal (QtcRead (Join-Path $hq 'profiles.xml') 'Profile.0') 'PE.Profile.Id') -ceq 'user.kit')) ("-> " + $r.Out)
    $r = RunRestore @('-Restore', '20261019_100000', '-Force', '-WhatIf')
    Check "...-WhatIf, even with -Force: says it, changes nothing" (($r.Code -eq 0) -and ($r.Out -match 'Put back the set 20261019_100000') -and ((QtcRead (Join-Path $hq 'profiles.xml') 'Profile.Count').value.'#text' -ceq '1')) ("-> " + $r.Out)
    $r = RunRestore @('-Restore', '20261019_100000', '-Force')
    Check "...-Restore <stamp>: the set's files put back exactly" (($r.Code -eq 0) -and (@($userFiles.Keys | Where-Object { [System.IO.File]::ReadAllText((Join-Path $hq $_)) -cne $userFiles[$_] }).Count -eq 0)) ("-> " + $r.Out)
    Check "...and the files it replaced kept under a stamp of their own" (@(Get-ChildItem $hq -Filter '*.drivenv-*.bak' | ForEach-Object { ($_.Name -split '\.drivenv-')[1] } | Sort-Object -Unique).Count -ge 3)
}
finally { Remove-Item -LiteralPath $hs -Recurse -Force -ErrorAction SilentlyContinue }

# Remove-DevDrive: only ever -WhatIf here. It reports, needs no elevation, and changes nothing.
$rm = & { $ErrorActionPreference = 'Continue'; & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\Remove-DevDrive.ps1') -ConfigFile $dualCfg -WhatIf 2>&1 | ForEach-Object { "$_" } }
Check "remove script -WhatIf: reports the drive's VHDX and changes nothing" (($LASTEXITCODE -eq 0) -and (($rm -join "`n") -match 'What if: ') -and (($rm -join "`n") -match '\.vhdx')) ("-> " + ($rm -join ' | '))
$srcRm = Get-Content -Raw -LiteralPath (Join-Path $root 'tools\Remove-DevDrive.ps1')
Check "...asks twice -- YES, then the label -- elevates itself, and refuses while programs run from the drive" `
    (($srcRm -match "Read-Host `"Type YES to continue`"\) -cne 'YES'") -and ($srcRm -match '-cne \$label\)') -and ($srcRm -match '-Verb RunAs') -and ($srcRm -match 'Programs are running from the drive'))
Check "...dismounts before deleting, never deletes what it could not dismount, and runs Manage-MountTasks.ps1 -Remove" `
    (($srcRm.IndexOf('Dismount-DiskImage') -lt $srcRm.IndexOf('Remove-Item -LiteralPath $vhd')) -and ($srcRm -match 'it could not be dismounted') -and ($srcRm -match "Manage-MountTasks\.ps1'\) -Remove"))

Write-Host "=== 42. METADATA AND GIT IDENTITY ==="
$aName = "$([char]0xC1)ngel Vera Herrera"
$mg = Clone $example
$mg | Add-Member -NotePropertyName git -NotePropertyValue ([pscustomobject]@{ user_name = $aName; user_email = 'angelvh.engr@gmail.com' }) -Force
Check "metadata and git validate" ((Test-DrivEnvConfig -Config $mg).Count -eq 0) ("-> " + ((Test-DrivEnvConfig -Config $mg) -join '; '))
$bad = Clone $mg; $bad.metadata | Add-Member -NotePropertyName date -NotePropertyValue '20/10/2026' -Force
Check "...a date not YYYY-MM-DD refused" (HasProblem $bad 'metadata.date')
$bad = Clone $mg; $bad.metadata | Add-Member -NotePropertyName versoin -NotePropertyValue '1' -Force
Check "...an unknown metadata key refused" (HasProblem $bad 'versoin')
$bad = Clone $mg; $bad.git = Obj '{"user_name":"X"}'
Check "...git without user_email refused" (HasProblem $bad 'git.user_email')
$bad = Clone $mg; $bad.git = Obj '{"user_name":"X","user_email":"not-an-email"}'
Check "...an e-mail without @ and domain refused" (HasProblem $bad 'git.user_email')
$gl = @(Get-DrivEnvGitSystemConfigLines -Proxy 'http://p:8080' -Git $mg.git)
Check "gitconfig: proxy, identity and useConfigOnly" (($gl -contains '[http]') -and ($gl -contains "`tproxy = http://p:8080") -and ($gl -contains '[user]') -and
    ($gl -contains "`tname = $aName") -and ($gl -contains "`temail = angelvh.engr@gmail.com") -and ($gl -contains "`tuseConfigOnly = true"))
Check "...identity only: no [http]; neither: nothing to write" ((@(Get-DrivEnvGitSystemConfigLines -Git $mg.git) -notcontains '[http]') -and (@(Get-DrivEnvGitSystemConfigLines).Count -eq 0))
Check "metadata summary line, empty without metadata" (((Get-DrivEnvMetadataSummary -Cfg $mg) -ceq 'Configuration: Example dual drive 1.0.0 (2026-10-20), target Windows 10 / 11') -and ((Get-DrivEnvMetadataSummary -Cfg (Load $base)) -ceq ''))
Check "metadata record lines, blank notes skipped" ((Joined @(Get-DrivEnvMetadataLines -Cfg (Obj '{"metadata":{"name":"N","target_os":"W11","notes":["a"," ","b"]}}'))) -ceq 'name: N|target_os: W11|notes:|  - a|  - b')
# FOUND WHILE ADDING THIS: Windows PowerShell 5.1 reads a BOM-less file as ANSI unless told otherwise, so a name
# with an accent reached the steps mangled. Every step and the runner read the configuration as UTF-8.
$uj = Join-Path ([System.IO.Path]::GetTempPath()) ("drivenv-utf8-" + [guid]::NewGuid().ToString('N') + '.json')
[System.IO.File]::WriteAllText($uj, ('{"git":{"user_name":"' + $aName + '"}}'), (New-Object System.Text.UTF8Encoding($false)))
$ur = (Get-Content -Path $uj -Raw -Encoding UTF8 | ConvertFrom-Json).git.user_name
Remove-Item -LiteralPath $uj -Force
$readers = @(Select-String -Path (@(Join-Path $root 'Generate-DrivEnv.ps1') + @(Get-ChildItem (Join-Path $root 'scripts\*.ps1') | Where-Object { $_.Name -match '^[1-7]-' } | ForEach-Object FullName)) -Pattern 'Get-Content.*\| ConvertFrom-Json')
Check "the configuration is read as UTF-8 by the runner and every step" (($ur -ceq $aName) -and ($readers.Count -eq 8) -and (@($readers | Where-Object { $_.Line -notmatch '-Encoding UTF8' }).Count -eq 0))
$src2g = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\2-Setup_MSYS2.ps1')
Check "...and step 2 writes the drive's gitconfig from it, as UTF-8" (($src2g -match 'Get-DrivEnvGitSystemConfigLines -Proxy \$proxyUrl -Git \$Cfg\.git') -and ($src2g -match 'WriteAllLines\(\$gitConfigPath'))

Write-Host "=== 43. vcpkg.cleanup: packages, downloads and binary cache ==="
$cs = Get-DrivEnvCleanupSettings -Cfg (Load $base)
Check "cleanup defaults: nothing removed" (($cs.Buildtrees -ceq 'none') -and -not $cs.Packages -and -not $cs.Downloads -and -not $cs.BinaryCache)
$cc = Clone $example; $cc.vcpkg | Add-Member -NotePropertyName cleanup -NotePropertyValue (Obj '{"buildtrees":" LOGS ","packages":true,"downloads":true,"binary_cache":false}') -Force
$cs = Get-DrivEnvCleanupSettings -Cfg $cc
Check "...the keys read, buildtrees trimmed and lowered" (($cs.Buildtrees -ceq 'logs') -and $cs.Packages -and $cs.Downloads -and -not $cs.BinaryCache)
Check "...and they validate" ((Test-DrivEnvConfig -Config $cc).Count -eq 0) ("-> " + ((Test-DrivEnvConfig -Config $cc) -join '; '))
$cc.vcpkg.cleanup.packages = 'yes'
Check "...a non-boolean refused" (HasProblem $cc 'vcpkg.cleanup.packages')
$src4c = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\4-Deps_VCPKG.ps1')
Check "step 4: vcpkg\packages removed whole; downloads and binary cache only by the last toolchain; a summary" `
    (($src4c -match 'Remove-Tree \$pkgRoot "vcpkg packages"') -and ($src4c -match 'if \(-not \$isLastToolchain\)') -and
     ($src4c -match 'Reclaimed \{0:N1\} MB'))

Write-Host "=== 44. PORTABILITY: categories, build tree kinds, estimates ==="
. (Join-Path $root 'scripts\DrivEnvPortability.ps1')
$tr = @('x64-mingw-clang-dynamic-release', 'x64-mingw-ucrt-dynamic-release')
Check "build tree kinds: port by its stamp, user by its triplet name, detect_compiler internal, the rest unknown" (
    ((Get-DrivEnvBuildtreeEntryKind -Name 'zlib' -FileNames @('x64-mingw-ucrt-dynamic-release.vcpkg_abi_info.txt', 'a.log') -Triplets $tr) -ceq 'port') -and
    ((Get-DrivEnvBuildtreeEntryKind -Name 'X64-MINGW-UCRT-DYNAMIC-RELEASE' -Triplets $tr) -ceq 'user') -and
    ((Get-DrivEnvBuildtreeEntryKind -Name 'detect_compiler' -Triplets $tr) -ceq 'internal') -and
    ((Get-DrivEnvBuildtreeEntryKind -Name 'zlib' -FileNames @('a.log') -Triplets $tr) -ceq 'unknown'))
$pc = Get-DrivEnvPortabilityCategories -Drive 'D:' -BuildtreesWin 'D:\bt' -BinaryCache 'D:\packages\vcpkg'
$pcEnv = @($pc | Where-Object Key -eq 'environment')[0]
Check "categories: safe, optional and keep, binary cache optional, every path its own entry" (
    ((Joined @($pc | Where-Object Class -eq 'safe' | ForEach-Object Key)) -ceq 'vcpkg_packages|buildtree_ports|buildtree_internal|temp') -and
    (@($pc | Where-Object Key -eq 'binary_cache')[0].Class -ceq 'optional') -and
    ((Joined $pcEnv.Paths) -ceq 'D:\msys64|D:\vcpkg\installed|D:\env'))
$ex = Get-DrivEnvExportExclusions -Categories $pc
Check "export exclusions: every safe category always, vcpkg_packages first; no optional one by default" ((Joined $ex) -ceq 'vcpkg_packages|buildtree_ports|buildtree_internal|temp')
Check "...-Full adds every optional one, -Exclude only those named" (
    ((Joined (Get-DrivEnvExportExclusions -Categories $pc -Full)) -ceq 'vcpkg_packages|buildtree_ports|buildtree_internal|temp|downloads|user_builds|failure_logs|binary_cache') -and
    ((Joined (Get-DrivEnvExportExclusions -Categories $pc -Exclude @('downloads'))) -ceq 'vcpkg_packages|buildtree_ports|buildtree_internal|temp|downloads'))
Check "...a key that is not optional is refused, never silently kept or dropped" ((Throws { Get-DrivEnvExportExclusions -Categories $pc -Exclude @('environment') }) -and (Throws { Get-DrivEnvExportExclusions -Categories $pc -Exclude @('downlods') }))
$srcEx = Get-Content -Raw -LiteralPath (Join-Path $root 'tools\Export-DevDrive.ps1')
Check "export: reads the drive with robocopy into a new VHDX, never deletes on it, verifies read-only" (($srcEx -match 'create vdisk file=') -and ($srcEx -match "'/COPY:DAT'") -and
    ($srcEx -notmatch '(?m)^[^#]*Remove-Item[^\r\n]*\$drive') -and ($srcEx -match 'Mount-DiskImage -ImagePath \$newVhd -Access ReadOnly'))

# vcpkg.overlay_root: overlay layers come from a named set; layers without one are refused; no overlays at all is valid.
$ov = Load (Join-Path $cfgDir 'drivenv-cfg_example.json')
Check "overlays: the example names its set, which exists with its layers, and validates" (($ov.vcpkg.overlay_root -eq 'vcpkg_overlays/degoras') -and
    ((Test-DrivEnvConfig -Config $ov).Count -eq 0) -and (Test-Path (Join-Path $root 'vcpkg_overlays\degoras\ports')) -and
    (Test-Path (Join-Path $root 'vcpkg_overlays\degoras\ports.clang')) -and (Test-Path (Join-Path $root 'vcpkg_overlays\degoras\ports.ucrt')))
$bad = Clone $ov; $bad.vcpkg.PSObject.Properties.Remove('overlay_root')
Check "...layers without vcpkg.overlay_root refused" (HasProblem $bad 'vcpkg.overlay_root')
$none = Clone $bad; $none.vcpkg.PSObject.Properties.Remove('overlay_ports')
Check "...no overlays at all is a valid configuration" ((Test-DrivEnvConfig -Config $none).Count -eq 0)

# Step 2's Invoke-Pacman, taken from the script: a failure (an HTTP 429 from a mirror, say) is retried, the last code
# comes back when every attempt fails, and pass 1 of the core upgrade gets a single attempt.
$s2Ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts\2-Setup_MSYS2.ps1'), [ref]$null, [ref]$null)
$pacmanFn = $s2Ast.Find({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Invoke-Pacman') }, $true)
& {
    function Write-Info { }
    function Start-Sleep { }
    function Invoke-Msys2Bash { param($BashPath, $Command) $script:pacCalls++; $script:pacCmd = $Command; return $script:pacCodes[$script:pacCalls - 1] }
    . ([scriptblock]::Create($pacmanFn.Extent.Text))
    $script:pacCodes = @(1, 1, 0); $script:pacCalls = 0
    $ok = Invoke-Pacman -BashPath 'bash' -Arguments '-S --noconfirm x'
    Check "pacman retries: two failures then success -> 0 after 3 runs; English messages, download timeout disabled" (($ok -eq 0) -and ($script:pacCalls -eq 3) -and
        ($script:pacCmd -ceq 'LC_ALL=C pacman --disable-download-timeout -S --noconfirm x'))
    $script:pacCodes = @(1, 1, 1); $script:pacCalls = 0
    $ko = Invoke-Pacman -BashPath 'bash' -Arguments '-Syu --noconfirm'
    $script:pacCodes = @(1); $script:pacCalls = 0
    $one = Invoke-Pacman -BashPath 'bash' -Arguments '-Syu --noconfirm' -Attempts 1
    Check "...every attempt failing returns the last code after 3; -Attempts 1 runs once" (($ko -eq 1) -and ($one -eq 1) -and ($script:pacCalls -eq 1))
}

# environment.owner -> the owner icacls is given (step 1, the elevated runner), always as a SID.
$meName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$meSid  = '*' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Check "owner: absent or 'current' is this account as a SID; 'administrators' the built-in group" (
    ((Resolve-DrivEnvOwner -Cfg (Obj '{"environment":{}}')) -ceq $meSid) -and ((Resolve-DrivEnvOwner -Cfg (Obj '{"environment":{"owner":"current"}}')) -ceq $meSid) -and
    ((Resolve-DrivEnvOwner -Cfg (Obj '{"environment":{"owner":"Administrators"}}')) -ceq '*S-1-5-32-544'))
Check "...-Current (who started the elevated child) is what 'current' means; a named account resolves; an unknown one throws" (
    ((Resolve-DrivEnvOwner -Cfg (Obj '{"environment":{"owner":"current"}}') -Current $meName) -ceq $meSid) -and
    ((Resolve-DrivEnvOwner -Cfg (Obj ('{"environment":{"owner":"' + $meName.Replace('\', '\\') + '"}}'))) -ceq $meSid) -and
    (Throws { Resolve-DrivEnvOwner -Cfg (Obj '{"environment":{"owner":"no-such-account-drivenv"}}') }))
$ow = Load (Join-Path $cfgDir 'drivenv-cfg_example.json'); $ow.environment | Add-Member -NotePropertyName owner -NotePropertyValue '' -Force
Check "...an empty owner is refused by the schema, a set one accepted" ((HasProblem $ow 'environment.owner') -and
    ((Test-DrivEnvConfig -Config ($ow | ForEach-Object { $_.environment.owner = 'administrators'; $_ })).Count -eq 0))

# Enable-DrivEnvGitTrust (steps 3, 4, 6): process environment only, appended after an entry already there, once.
$gitEnv = @{}; foreach ($k in 'GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0', 'GIT_CONFIG_KEY_1', 'GIT_CONFIG_VALUE_1') { $gitEnv[$k] = [Environment]::GetEnvironmentVariable($k) }
$env:GIT_CONFIG_COUNT = '1'; $env:GIT_CONFIG_KEY_0 = 'core.autocrlf'; $env:GIT_CONFIG_VALUE_0 = 'false'
Enable-DrivEnvGitTrust; Enable-DrivEnvGitTrust
Check "git trust: safe.directory=* appended after an existing entry, and only once" (($env:GIT_CONFIG_COUNT -eq '2') -and ($env:GIT_CONFIG_KEY_0 -eq 'core.autocrlf') -and
    ($env:GIT_CONFIG_KEY_1 -eq 'safe.directory') -and ($env:GIT_CONFIG_VALUE_1 -eq '*'))
foreach ($k in $gitEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $gitEnv[$k]) }

# SKIPPED IS SAID, and counted: a clean-looking summary over cases that did not run is how a gap hides. With
# DRIVENV_REQUIRE_BASH=1 a skip is a failure, for a machine that is expected to have the bash.
Write-Host "================ $script:pass passed, $script:fail failed, $script:skip skipped ================"
if ($script:fail -gt 0) { exit 1 }
if (($script:skip -gt 0) -and ($env:DRIVENV_REQUIRE_BASH -eq '1')) { Write-Host "Skips are failures with DRIVENV_REQUIRE_BASH=1."; exit 1 }
exit 0
