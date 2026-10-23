# ====================================================================
# DRIVENV FULL GENERATION RUNNER
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Runs the numbered steps in order, stops at the first failure and prints
# how long each took. It launches the steps as a person would and reads
# their exit codes; each step still validates and logs for itself.
# ====================================================================

param
(
    # @brief JSON configuration, forwarded verbatim. A bare name resolves against config/ (Resolve-DrivEnvConfigPath).
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief First step to run. Use it to resume after a failure without redoing the hours before it.
    [ValidateRange(1, 7)]
    [int]$From = 1,

    # @brief Last step to run.
    [ValidateRange(1, 7)]
    [int]$To = 7,

    # @brief Steps to skip, e.g. -Skip 5,6. A string: under -File "4,6" would coerce to the integer 46.
    [string]$Skip = "",

    # @brief Restrict steps 2-5 to these toolchain ids, e.g. -Toolchain ucrt. Empty: every id in 'generate'.
    # A string for the same reason as -Skip. Ignored without 'toolchains'.
    [string]$Toolchain = "",

    # @brief Print the run plan and launch nothing.
    [switch]$DryRun,

    # @brief Validate the configuration through step 1 only, changing nothing.
    [switch]$ValidateOnly
)

# --------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------

function Write-Banner
{
    param ([string]$Text)
    $line = "=" * 78
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
}

function Format-Duration
{
    # @brief A TimeSpan as h:mm:ss, or m:ss under an hour. Floor, not [int]: the cast rounds (50 s printed "1:50").
    param ([TimeSpan]$Span)

    if ($Span.TotalHours -ge 1)
    {
        return ("{0}:{1:00}:{2:00}" -f [math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds)
    }
    return ("{0}:{1:00}" -f [math]::Floor($Span.TotalMinutes), $Span.Seconds)
}

function Test-IsAdministrator
{
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Step
{
    # @brief Run one step as a child process (every step ends in `exit`) and return its exit code.
    # Stdin is closed so the steps skip "Press any key"; stdout/stderr are inherited so long builds stay visible.
    # Same host executable as this runner, so a pwsh run stays on pwsh.
    param
    (
        [string]  $Path,
        [string[]]$Arguments
    )

    $hostExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($hostExe)) { $hostExe = "powershell.exe" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $hostExe
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.WorkingDirectory       = (Split-Path -Parent $Path)

    $psi.Arguments = (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"{0}"' -f $Path)) + $Arguments) -join " "

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $proc.WaitForExit()

    return $proc.ExitCode
}

# --------------------------------------------------------------------
# STEPS
# --------------------------------------------------------------------

# Scope: 'drive' steps run once per drive (1 creates the VHDX, 6 the shared workspace, 7 the one Qt Creator after
# every toolchain); 'toolchain' steps run once per generated id. Step 1 twice would fail on the existing VHDX.
$stepDefs = @(
    @{ Number = 1; File = "1-Setup_DevDrive.ps1"; Title = "Create and format the dev drive";      Scope = "drive"     },
    @{ Number = 2; File = "2-Setup_MSYS2.ps1";    Title = "Install MSYS2 and the toolchain";      Scope = "toolchain" },
    @{ Number = 3; File = "3-Clone_VCPKG.ps1";    Title = "Clone and bootstrap vcpkg";            Scope = "toolchain" },
    @{ Number = 4; File = "4-Deps_VCPKG.ps1";     Title = "Build the dependency set";             Scope = "toolchain" },
    @{ Number = 5; File = "5-Verify_Env.ps1";     Title = "Verify the finished environment";      Scope = "toolchain" },
    @{ Number = 6; File = "6-Clone_Repos.ps1";    Title = "Clone the workspace repositories";     Scope = "drive"     },
    @{ Number = 7; File = "7-Setup_IDE.ps1";      Title = "Set up Qt Creator, one kit per toolchain"; Scope = "drive"   }
)

# --------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------

$ErrorActionPreference = "Stop"

$originalTitle = $host.UI.RawUI.WindowTitle
$drivEnvRoot   = $PSScriptRoot
if (-not $drivEnvRoot) { $drivEnvRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

# This file is the entry point and sits at the generator root; the steps it drives live in scripts/.
$scriptDir = Join-Path $drivEnvRoot "scripts"

if ($To -lt $From)
{
    Write-Host "[ERROR] -To ($To) is before -From ($From); nothing would run." -ForegroundColor Red
    exit 1
}

$skipNumbers = @()
foreach ($token in ($Skip -split '[,;\s]+' | Where-Object { $_ -ne "" }))
{
    $n = 0
    if (-not [int]::TryParse($token, [ref]$n) -or $n -lt 1 -or $n -gt 7)
    {
        Write-Host ("[ERROR] -Skip: '{0}' is not a step number between 1 and 7." -f $token) -ForegroundColor Red
        exit 1
    }
    $skipNumbers += $n
}

$selected = @($stepDefs | Where-Object { $_.Number -ge $From -and $_.Number -le $To -and $skipNumbers -notcontains $_.Number })

if ($ValidateOnly)
{
    $selected = @($stepDefs | Where-Object { $_.Number -eq 1 })
}

if ($selected.Count -eq 0)
{
    Write-Host "[ERROR] Every step in $From..$To was skipped; nothing to do." -ForegroundColor Red
    exit 1
}

# --------------------------------------------------------------------
# WHICH TOOLCHAINS
# --------------------------------------------------------------------
# The runner reads the configuration for one fact only: which toolchains to generate. The path goes through the
# shared resolver so this runner and the steps agree on the file.

. (Join-Path $scriptDir "DrivEnvConfig.ps1")

$configPath = Resolve-DrivEnvConfigPath -ConfigFile $ConfigFile -GeneratorRoot $drivEnvRoot

if (-not (Test-Path -LiteralPath $configPath))
{
    Write-Host ("[ERROR] Configuration file missing: {0}" -f $configPath) -ForegroundColor Red
    exit 1
}

try
{
    $cfg = Get-Content -Raw -LiteralPath $configPath -Encoding UTF8 | ConvertFrom-Json
}
catch
{
    # Not deferred to step 1. A file this cannot parse is a file no step can parse, and saying so now costs a
    # second where saying it later costs a UAC prompt and a banner first.
    Write-Host ("[ERROR] Invalid JSON in {0}: {1}" -f $configPath, $_.Exception.Message) -ForegroundColor Red
    exit 1
}

# Not wrapped in @(): the function already returns an array, and wrapping it nests it ("clang ucrt" as one id).
$toolchains = Get-DrivEnvGenerateList -Cfg $cfg

$wantedToolchains = @($Toolchain -split '[,;\s]+' | Where-Object { $_ -ne "" })
if ($wantedToolchains.Count -gt 0)
{
    if ($toolchains.Count -eq 0)
    {
        Write-Host ("[ERROR] -Toolchain was given, but {0} declares no 'toolchains'." -f (Split-Path -Leaf $configPath)) -ForegroundColor Red
        exit 1
    }

    $unknown = @($wantedToolchains | Where-Object { $toolchains -notcontains $_ })
    if ($unknown.Count -gt 0)
    {
        Write-Host ("[ERROR] -Toolchain: {0} is not generated by this configuration." -f ($unknown -join ", ")) -ForegroundColor Red
        Write-Host ("        It generates: {0}" -f ($toolchains -join ", ")) -ForegroundColor Red
        exit 1
    }

    # Filtered in the CONFIGURATION's order, not in the order they were typed, so the sequence a run produces
    # depends on the file rather than on how somebody happened to spell the argument.
    $toolchains = @($toolchains | Where-Object { $wantedToolchains -contains $_ })
}

# --------------------------------------------------------------------
# THE RUN PLAN
# --------------------------------------------------------------------
# One entry per (step, toolchain) to run, built up front so the plan can be printed and counted.
# Order (owner decision, 2026-10-16): every step 2 first, then 3-5 toolchain by toolchain:
#     1  ->  2 (clang), 2 (ucrt)  ->  3,4,5 (clang)  ->  3,4,5 (ucrt)  ->  6  ->  7
# Every MSYS2 environment exists before the long vcpkg builds; each toolchain is verified, and its build trees
# cleaned, before the next one builds.
$plan = @()
$idx  = 0
while ($idx -lt $selected.Count)
{
    if (($selected[$idx].Scope -ne "toolchain") -or ($toolchains.Count -eq 0))
    {
        $plan += [pscustomobject]@{ Step = $selected[$idx]; Toolchain = $null }
        $idx++
        continue
    }

    # The contiguous run of toolchain-scoped steps, which -Skip may well have punched a hole in.
    $run = @()
    while (($idx -lt $selected.Count) -and ($selected[$idx].Scope -eq "toolchain"))
    {
        $run += $selected[$idx]
        $idx++
    }

    foreach ($s in @($run | Where-Object { $_.Number -eq 2 }))
    {
        foreach ($id in $toolchains) { $plan += [pscustomobject]@{ Step = $s; Toolchain = $id } }
    }
    foreach ($id in $toolchains)
    {
        foreach ($s in @($run | Where-Object { $_.Number -ne 2 })) { $plan += [pscustomobject]@{ Step = $s; Toolchain = $id } }
    }
}

# Only step 1 needs elevation, and it asks for it itself: from an unelevated runner it relaunches elevated in a window
# of its own and waits, so the runner waits too, and every other step runs as you -- the drive's files are yours. An
# elevated runner runs everything elevated and hands the drive to environment.owner at the end (below).
$runElevated   = (Test-IsAdministrator) -and (-not $ValidateOnly) -and (-not $DryRun)
$step1Elevates = ($selected | Where-Object { $_.Number -eq 1 }) -and (-not $ValidateOnly) -and (-not $DryRun) -and (-not (Test-IsAdministrator))

# Missing files are checked BEFORE anything runs. Discovering that step 6 is absent after step 4 has spent two
# hours compiling is a strictly worse way to find out.
$missing = @()
foreach ($step in $selected)
{
    if (-not (Test-Path -LiteralPath (Join-Path $scriptDir $step.File))) { $missing += $step.File }
}
if ($missing.Count -gt 0)
{
    Write-Host ("[ERROR] Missing step script(s) in {0}:" -f $scriptDir) -ForegroundColor Red
    foreach ($m in $missing) { Write-Host ("        {0}" -f $m) -ForegroundColor Red }
    exit 1
}

Write-Banner "DRIVENV GENERATION"
Write-Host ("  Configuration : {0}" -f $ConfigFile)
$metaLine = Get-DrivEnvMetadataSummary -Cfg $cfg; if ($metaLine) { Write-Host ("  {0}" -f $metaLine) }
Write-Host ("  Scripts       : {0}" -f $scriptDir)
Write-Host ("  Steps         : {0}" -f (($selected | ForEach-Object { $_.Number }) -join ", "))
if ($toolchains.Count -gt 0)
{
    Write-Host ("  Toolchains    : {0}" -f ($toolchains -join ", "))
    Write-Host ("  Order         : {0}" -f (($plan | ForEach-Object { if ($_.Toolchain) { "{0}:{1}" -f $_.Step.Number, $_.Toolchain } else { "$($_.Step.Number)" } }) -join " "))
}

# Show the file names (they carry the subsystem, not the id). Best effort: a profile that cannot be projected is skipped.
$keysShown = @()
$targetsShown = @()
try { $targetsShown = Get-DrivEnvToolchainTargets -Cfg $cfg } catch { $targetsShown = @() }
foreach ($t in $targetsShown)
{
    if (($toolchains.Count -gt 0) -and ($toolchains -notcontains $t.Id)) { continue }
    if ([string]::IsNullOrWhiteSpace($t.Key)) { continue }
    $keysShown += $(if ($t.Id) { "{0} -> {1}" -f $t.Id, $t.Key } else { $t.Key })
}
if ($keysShown.Count -gt 0) { Write-Host ("  Files named   : {0}" -f ($keysShown -join ", ")) }
if ($ValidateOnly) { Write-Host "  Mode          : validate the configuration only, change nothing" }
if ($step1Elevates) { Write-Host "  Elevation     : step 1 asks for administrator rights (UAC); the other steps run as you" }
if ($runElevated)   { Write-Host "  Elevation     : running elevated; the drive is handed to environment.owner at the end" }
Write-Host ""

if ($DryRun)
{
    Write-Host "  Dry run: nothing will be launched." -ForegroundColor Yellow
    Write-Host ""
    $n = 0
    foreach ($entry in $plan)
    {
        $n++
        # NOT $args, which is an automatic variable: assigning to it works and then quietly changes what an
        # argument-less call inside this scope would see.
        $shownArgs = "-ConfigFile `"$ConfigFile`""
        if ($entry.Toolchain) { $shownArgs += " -Toolchain `"$($entry.Toolchain)`"" }
        if ($ValidateOnly)    { $shownArgs += " -ValidateOnly" }
        Write-Host ("  {0,2}. {1,-24} {2,-10} {3}" -f $n, $entry.Step.File, $entry.Toolchain, $shownArgs)
    }
    Write-Host ""
    Write-Host ("  {0} launches." -f $plan.Count)
    $host.UI.RawUI.WindowTitle = $originalTitle
    exit 0
}

$results   = @()
$runStart  = Get-Date
$failed    = $null
$cancelled = $false

foreach ($entry in $plan)
{
    $step = $entry.Step
    $id   = $entry.Toolchain

    $path = Join-Path $scriptDir $step.File
    $stepArgs = @("-ConfigFile", ('"{0}"' -f $ConfigFile))

    # -Toolchain only for toolchain-scoped steps with an id; drive steps never take it.
    if ($id) { $stepArgs += @("-Toolchain", ('"{0}"' -f $id)) }
    if ($ValidateOnly) { $stepArgs += "-ValidateOnly" }

    $label = if ($id) { "STEP {0}  [{1}]  --  {2}" -f $step.Number, $id, $step.Title }
             else     { "STEP {0}  --  {1}"        -f $step.Number, $step.Title }

    Write-Banner $label
    $host.UI.RawUI.WindowTitle = if ($id) { "DrivEnv -- step {0} [{1}]: {2}" -f $step.Number, $id, $step.Title }
                                 else     { "DrivEnv -- step {0}: {1}"       -f $step.Number, $step.Title }

    $start = Get-Date
    $code  = Invoke-Step -Path $path -Arguments $stepArgs
    $span  = (Get-Date) - $start

    $results += [pscustomobject]@{
        Number    = $step.Number
        Toolchain = $id
        Title     = $step.Title
        ExitCode  = $code
        Duration  = $span
    }

    $shown = if ($id) { "{0} [{1}]" -f $step.Number, $id } else { "$($step.Number)" }

    if ($code -eq 0)
    {
        Write-Host ("[OK] Step {0} finished in {1}." -f $shown, (Format-Duration $span)) -ForegroundColor Green
        continue
    }

    # 1223 is ERROR_CANCELLED, which step 4 returns when Ctrl-C tore the build down on purpose. It is not a
    # failure and must not be reported as one: nothing is wrong with the environment, somebody stopped it.
    if ($code -eq 1223)
    {
        $cancelled = $true
        Write-Host ("[CANCELLED] Step {0} was stopped after {1}." -f $shown, (Format-Duration $span)) -ForegroundColor Yellow
    }
    else
    {
        $failed = $entry
        Write-Host ("[FAILED] Step {0} exited with code {1} after {2}." -f $shown, $code, (Format-Duration $span)) -ForegroundColor Red
    }
    break
}

# An elevated run created the drive's files as Administrators: hand them to environment.owner whatever happened above,
# so a resumed run -- elevated or not -- finds them its own.
if ($runElevated -and ($results.Count -gt 0))
{
    $ownerLetter = ([string]$cfg.environment.dev_drive_letter).Trim().TrimEnd(':')
    if (Test-Path -LiteralPath "${ownerLetter}:\")
    {
        Write-Banner "OWNER"
        try
        {
            $ownerArg = Resolve-DrivEnvOwner -Cfg $cfg
            Write-Host ("  Handing {0}:\ to {1} (environment.owner); a whole drive takes a minute or two..." -f $ownerLetter, $ownerArg)
            $ownerCode = Set-DrivEnvDriveOwner -Path "${ownerLetter}:\" -Owner $ownerArg -Report { param($m) Write-Host $m }
            if ($ownerCode -eq 0) { Write-Host "[OK] Drive owned by $ownerArg." -ForegroundColor Green }
            else { Write-Host "[WARN] icacls could not hand every file to $ownerArg (exit $ownerCode)." -ForegroundColor Yellow }
        }
        catch { Write-Host ("[WARN] {0}" -f $_.Exception.Message) -ForegroundColor Yellow }
    }
}

$total = (Get-Date) - $runStart

Write-Banner "SUMMARY"
foreach ($r in $results)
{
    $status = switch ($r.ExitCode)
    {
        0       { "OK" }
        1223    { "CANCELLED" }
        default { "FAILED ({0})" -f $r.ExitCode }
    }
    $colour = switch ($r.ExitCode) { 0 { "Green" } 1223 { "Yellow" } default { "Red" } }
    Write-Host ("  {0}  {1,-10} {2,-38} {3,8}   {4}" -f $r.Number, $r.Toolchain, $r.Title, (Format-Duration $r.Duration), $status) -ForegroundColor $colour
}

# What did not run, taken from the plan by position: with two toolchains a step number repeats.
$notRun = @()
if ($results.Count -lt $plan.Count) { $notRun = @($plan[$results.Count..($plan.Count - 1)]) }
foreach ($n in $notRun)
{
    Write-Host ("  {0}  {1,-10} {2,-38} {3,8}   not run" -f $n.Step.Number, $n.Toolchain, $n.Step.Title, "-") -ForegroundColor DarkGray
}

Write-Host ""
Write-Host ("  Total: {0}" -f (Format-Duration $total))
Write-Host ""

$host.UI.RawUI.WindowTitle = $originalTitle

function Write-ResumeHint
{
    # @brief Prints the command line, or the two command lines, that pick the run up where it stopped. What they
    # are is Get-DrivEnvResumeArguments' business, where it is tested; this only prints them.
    param ([int]$Number, [string]$Id, [string]$Colour)

    $vcpkgStep = @($selected | Where-Object { ($_.Scope -eq "toolchain") -and ($_.Number -ne 2) } | Select-Object -First 1)
    $lastStep  = @($stepDefs | Where-Object { $_.Scope -eq "toolchain" } | Select-Object -Last 1)
    $lines = Get-DrivEnvResumeArguments -Number $Number -Id $Id -Toolchains $toolchains `
                                        -FirstVcpkgStep $(if ($vcpkgStep) { $vcpkgStep[0].Number } else { 3 }) -LastToolchainStep $lastStep[0].Number
    for ($i = 0; $i -lt $lines.Count; $i++)
    {
        if ($i -eq 1)
        {
            Write-Host "" -ForegroundColor $Colour
            Write-Host "    ...and then, for the toolchain(s) whose vcpkg part never started:" -ForegroundColor $Colour
        }
        Write-Host ('    .\Generate-DrivEnv.ps1 -ConfigFile "{0}" {1}' -f $ConfigFile, $lines[$i]) -ForegroundColor $Colour
    }
}

if ($cancelled)
{
    Write-Host "Cancelled. Nothing is broken -- resume with:" -ForegroundColor Yellow
    Write-ResumeHint -Number $results[-1].Number -Id $results[-1].Toolchain -Colour Yellow
    exit 1223
}

if ($failed)
{
    $where = if ($failed.Toolchain) { "{0} [{1}]" -f $failed.Step.Number, $failed.Toolchain } else { "$($failed.Step.Number)" }
    Write-Host ("Stopped at step {0}. Its log says why; fix that, then resume with:" -f $where) -ForegroundColor Red
    Write-ResumeHint -Number $failed.Step.Number -Id $failed.Toolchain -Colour Red
    exit 1
}

Write-Host "Generation complete." -ForegroundColor Green
exit 0
