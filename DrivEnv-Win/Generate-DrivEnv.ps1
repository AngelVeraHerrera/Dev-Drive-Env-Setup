# ====================================================================
# DRIVENV FULL GENERATION RUNNER
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
# Updated: 09/09/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Runs the numbered steps in order, stops at the first one that fails,
# and prints how long each took. That is the whole job.
#
# WHY THIS EXISTS. Six scripts run by hand, in order, over about two
# hours, each of them ending in "Press any key to exit". Every one of
# those keypresses is a place to walk away and come back to a machine
# that has been idle for forty minutes, and every gap between two steps
# is a place to start the wrong one. Neither is a real risk on its own;
# together they are the reason a full generation takes an afternoon
# instead of the time it actually spends compiling.
#
# It deliberately does NOT reimplement any of the steps. It launches
# them exactly as a person would, reads their exit codes, and gets out
# of the way. A step's own logging, its own log copy onto the drive and
# its own configuration validation all still happen, once, where they
# already were.
#
# ====================================================================

param
(
    # @brief Path to the JSON configuration, forwarded to every step verbatim.
    #
    # Not resolved here. A relative path is resolved by each step against ITS directory, and second-guessing
    # that would create a second answer to the same question -- the failure mode this generator has already
    # been bitten by with buildtrees_root.
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief First step to run. Use it to resume after a failure without redoing the hours before it.
    [ValidateRange(1, 6)]
    [int]$From = 1,

    # @brief Last step to run.
    [ValidateRange(1, 6)]
    [int]$To = 6,

    # @brief Step numbers to skip inside the range, e.g. -Skip 5,6 or -Skip "5 6".
    #
    # A STRING, parsed below, and not [int[]] -- which is what it was until it was tested. Launched with
    # -File, as anything driving this from outside PowerShell must, every argument arrives as ONE string:
    # "4,6" then coerces to the single integer 46, which is in range, skips nothing, and says nothing.
    # Measured: -Skip 4,6 through -File gave Count=1, value 46; through -Command it gave 4 and 6.
    [string]$Skip = "",

    # @brief Restrict a dual-toolchain run to these toolchain ids, e.g. -Toolchain ucrt.
    #
    # Empty means "every id the configuration's 'generate' names", which is the normal case. Naming one is for
    # the situation the dual environment creates and the single one never did: the clang half of a drive is
    # finished and good, the ucrt half failed in step 4, and redoing both would throw away two hours of work
    # that is already correct.
    #
    # A STRING for the same reason -Skip is one: under -File every argument arrives as a single string, so an
    # [string[]] parameter given "ucrt,clang" would silently become one id named "ucrt,clang" and match nothing.
    # Ignored by a configuration that declares no toolchains, since there is nothing to choose between.
    [string]$Toolchain = "",

    # @brief Print the run plan and stop, launching nothing.
    #
    # Worth a switch because the plan is no longer obvious. With two toolchains a run is eleven launches in an
    # order the caller did not write down, and the cheapest moment to notice that -Skip removed the wrong one,
    # or that a resume is about to redo an hour that was already good, is before the first one starts.
    [switch]$DryRun,

    # @brief Validate the configuration through step 1 and stop, changing nothing.
    #
    # Only step 1 runs, with -ValidateOnly. The schema is shared, so one step rejecting the file is the same
    # verdict all six would reach, and checking it here costs a second instead of an hour.
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
    # @brief A TimeSpan as h:mm:ss, or m:ss when it is under an hour. Read at a glance, not parsed.
    #
    # Floor, NOT [int]. PowerShell's [int] cast ROUNDS, so a 50-second step printed "1:50" -- the minutes came
    # from rounding 0.833 up while the seconds stayed 50 -- and 59:59 printed as "60:59". Caught by the summary
    # disagreeing with itself: five steps adding to 1:12 under a column that read 1:50 for one of them.
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
    # @brief Run one step as a child process and return its exit code.
    #
    # A CHILD PROCESS, not a dot-source, because every step ends in `exit`. Dot-sourced, the first step to
    # finish would take this runner down with it, and a step that failed would take it down looking like a
    # success. The child also gets its own $host, so a step is free to set the window title as it always has.
    #
    # STDIN IS REDIRECTED AND IMMEDIATELY CLOSED. That is what turns off the "Press any key to exit" at the end
    # of each step: they test [System.Console]::IsInputRedirected precisely so that something can drive them.
    # stdout and stderr are deliberately NOT redirected -- inherited, they go straight to this console, so a
    # two-hour vcpkg build is watchable in real time instead of arriving in one lump at the end.
    #
    # THE SAME HOST EXECUTABLE that is running this file, whatever it is. The steps are 5.1-compatible and run
    # under either, and hardcoding powershell.exe would silently move a pwsh-launched run onto a different
    # engine from the one it was tested on.
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

# Numbers, not an ordered guess at the file names: the number in the file name IS the order, and the runner
# should fail loudly if a step is missing rather than quietly running five.
#
# SCOPE is what makes a dual-toolchain drive one run rather than two.
#
#   drive      the step is about the VOLUME, so it happens ONCE however many toolchains the drive carries.
#              Step 1 creates one VHDX, formats one volume, registers one mount task and lays out one folder
#              tree. Step 6 clones the workspace, and the workspace being SHARED is the entire reason both
#              toolchains live on one drive: the point is to compile the same source tree with either.
#
#   toolchain  the step produces one toolchain's worth of environment, so it runs once per generated id.
#              Step 2 installs that subsystem's prefix into the shared msys64 and writes that toolchain's
#              .env; step 3 installs its triplet and overlay layers into the shared vcpkg clone; step 4
#              builds its installed/<triplet> tree; step 5 asserts that one environment works.
#
# Running a 'drive' step once per toolchain would be worse than wasteful: step 1's own guards abort when the
# VHDX already exists, so the second pass would fail a run that was going fine.
$stepDefs = @(
    @{ Number = 1; File = "1-Setup_DevDrive.ps1"; Title = "Create and format the dev drive";      Scope = "drive"     },
    @{ Number = 2; File = "2-Setup_MSYS2.ps1";    Title = "Install MSYS2 and the toolchain";      Scope = "toolchain" },
    @{ Number = 3; File = "3-Clone_VCPKG.ps1";    Title = "Clone and bootstrap vcpkg";            Scope = "toolchain" },
    @{ Number = 4; File = "4-Deps_VCPKG.ps1";     Title = "Build the dependency set";             Scope = "toolchain" },
    @{ Number = 5; File = "5-Verify_Env.ps1";     Title = "Verify the finished environment";      Scope = "toolchain" },
    @{ Number = 6; File = "6-Clone_Repos.ps1";    Title = "Clone the workspace repositories";     Scope = "drive"     }
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
    if (-not [int]::TryParse($token, [ref]$n) -or $n -lt 1 -or $n -gt 6)
    {
        Write-Host ("[ERROR] -Skip: '{0}' is not a step number between 1 and 6." -f $token) -ForegroundColor Red
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
# The runner has to read the configuration for exactly one fact: which toolchains to produce. It still does not
# validate it and still does not interpret anything else -- each step does that for itself, once, where it
# already did. But the loop cannot be written without knowing what to loop over.
#
# The path is resolved through the SHARED helper rather than a seventh copy of the rule, so the thing choosing
# a configuration and the things reading it cannot disagree about which file that is.

. (Join-Path $scriptDir "DrivEnvConfig.ps1")

$configPath = Resolve-DrivEnvConfigPath -ConfigFile $ConfigFile -GeneratorRoot $drivEnvRoot

if (-not (Test-Path -LiteralPath $configPath))
{
    Write-Host ("[ERROR] Configuration file missing: {0}" -f $configPath) -ForegroundColor Red
    exit 1
}

try
{
    $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
}
catch
{
    # Not deferred to step 1. A file this cannot parse is a file no step can parse, and saying so now costs a
    # second where saying it later costs a UAC prompt and a banner first.
    Write-Host ("[ERROR] Invalid JSON in {0}: {1}" -f $configPath, $_.Exception.Message) -ForegroundColor Red
    exit 1
}

# NOT @(Get-DrivEnvGenerateList ...). That function already guarantees an array, and wrapping it produces a
# one-element array holding the array -- which reached here as a Toolchain column reading "System.Object[]" and
# a single launch passing -Toolchain "clang ucrt". See the note on the function itself.
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
# One entry per (step, toolchain) pair actually to be run. Building it up front rather than deciding inside the
# loop is what lets the banner below say how long the run is, and what makes the ordering a thing that can be
# read rather than inferred.
#
# TOOLCHAIN-MAJOR, not step-major: a contiguous run of toolchain-scoped steps is repeated for the first
# toolchain, then for the second. So a full dual generation is
#
#     1  ->  2,3,4,5 (clang)  ->  2,3,4,5 (ucrt)  ->  6
#
# and not 2,2,3,3,4,4,5,5. Two reasons, and the first is the one that matters. It finishes one COMPLETE and
# VERIFIED environment before starting the next, so a failure in the second half still leaves a usable drive --
# whereas step-major would leave both halves built and neither verified. The second is space: the buildtrees
# cleanup at the end of a toolchain's step 4 runs before the next toolchain's step 4 begins, which is what keeps
# the transient peak at one toolchain's worth rather than two.
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

    foreach ($id in $toolchains)
    {
        foreach ($s in $run) { $plan += [pscustomobject]@{ Step = $s; Toolchain = $id } }
    }
}

# ELEVATION IS CHECKED UP FRONT rather than left to step 1. Step 1 can elevate itself by relaunching, but the
# elevated copy lands in its OWN console window: this runner would see the launcher exit, call the step done, and
# race ahead into step 2 while step 1 was still formatting the drive in a window nobody is watching.
#
# ONLY WHEN STEP 1 IS ACTUALLY GOING TO RUN, though, and that distinction is the whole point of -From. Step 1 is
# the only one that needs administrator rights -- diskpart -- and demanding them for a `-From 3` resume turns the
# ordinary recovery case, where somebody restarts after a failed port at two in the morning, into a UAC prompt
# for work that touches nothing privileged. -ValidateOnly selects step 1 but only reads the configuration, so it
# is exempt too.
# A dry run launches nothing, so it needs no rights either. Demanding elevation to be TOLD what would happen is
# the kind of friction that stops people checking.
$needsElevation = ($selected | Where-Object { $_.Number -eq 1 }) -and (-not $ValidateOnly) -and (-not $DryRun)

if ($needsElevation -and -not (Test-IsAdministrator))
{
    Write-Host "[ERROR] Step 1 creates and mounts the virtual disk with diskpart, so this runner must be" -ForegroundColor Red
    Write-Host "        started from an elevated PowerShell. A step that elevates itself would open a second" -ForegroundColor Red
    Write-Host "        window this runner cannot wait on, so it is required now rather than discovered later." -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Write-Host "        Resuming past step 1 needs no elevation: try -From 2 or later." -ForegroundColor Red
    exit 1
}

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
Write-Host ("  Scripts       : {0}" -f $scriptDir)
Write-Host ("  Steps         : {0}" -f (($selected | ForEach-Object { $_.Number }) -join ", "))
if ($toolchains.Count -gt 0)
{
    Write-Host ("  Toolchains    : {0}" -f ($toolchains -join ", "))
    Write-Host ("  Order         : {0}" -f (($plan | ForEach-Object { if ($_.Toolchain) { "{0}:{1}" -f $_.Step.Number, $_.Toolchain } else { "$($_.Step.Number)" } }) -join " "))
}
if ($ValidateOnly) { Write-Host "  Mode          : validate the configuration only, change nothing" }
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

    # -Toolchain is passed ONLY to a toolchain-scoped step that actually has an id. A drive-scoped step does
    # not take the switch at all, and a configuration with no toolchains must keep launching the steps exactly
    # as version 2 did -- a 2.x drive regenerated with this runner has to come out identical.
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

# Everything after the entry that stopped the run. Taken from the PLAN by position rather than by step number,
# because with two toolchains a number appears more than once and "step 4 already ran" is no longer an answer --
# step 4 ran for clang and did not run for ucrt.
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
    # @brief Prints the command line, or the two command lines, that pick the run up where it stopped.
    #
    # ONE LINE IS NOT ENOUGH ONCE THERE ARE TWO TOOLCHAINS, and getting this wrong would silently produce half a
    # drive. The run is toolchain-major, so a failure inside the FIRST toolchain means the second one has not
    # started at all: a bare `-From 4` would then resume the first toolchain at 4 and also start the second at
    # 4, skipping the steps 2 and 3 it never ran. So the toolchain that stopped is resumed from the step that
    # stopped it, and any toolchain behind it is named separately and resumed from the beginning of the range.
    param ([int]$Number, [string]$Id, [string]$Colour)

    $cfgArg = '-ConfigFile "{0}"' -f $ConfigFile

    if (-not $Id)
    {
        Write-Host ("    .\Generate-DrivEnv.ps1 {0} -From {1}" -f $cfgArg, $Number) -ForegroundColor $Colour
        return
    }

    Write-Host ("    .\Generate-DrivEnv.ps1 {0} -From {1} -Toolchain {2}" -f $cfgArg, $Number, $Id) -ForegroundColor $Colour

    $after = @($toolchains[([array]::IndexOf($toolchains, $Id) + 1)..($toolchains.Count - 1)] | Where-Object { $_ })
    if ($after.Count -gt 0)
    {
        $firstToolchainStep = @($selected | Where-Object { $_.Scope -eq "toolchain" } | Select-Object -First 1).Number
        Write-Host "" -ForegroundColor $Colour
        Write-Host ("    ...and then, for the toolchain(s) that never started:" ) -ForegroundColor $Colour
        Write-Host ("    .\Generate-DrivEnv.ps1 {0} -From {1} -Toolchain {2}" -f $cfgArg, $firstToolchainStep, ($after -join ",")) -ForegroundColor $Colour
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
