# ====================================================================
# DRIVENV FULL GENERATION RUNNER
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
# Updated: 09/09/2026
# Version: 1.0.0
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
    param ([TimeSpan]$Span)

    if ($Span.TotalHours -ge 1) { return ("{0}:{1:00}:{2:00}" -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds) }
    return ("{0}:{1:00}" -f [int]$Span.TotalMinutes, $Span.Seconds)
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
$stepDefs = @(
    @{ Number = 1; File = "1-Setup_DevDrive.ps1"; Title = "Create and format the dev drive" },
    @{ Number = 2; File = "2-Setup_MSYS2.ps1";    Title = "Install MSYS2 and the toolchain" },
    @{ Number = 3; File = "3-Clone_VCPKG.ps1";    Title = "Clone and bootstrap vcpkg" },
    @{ Number = 4; File = "4-Deps_VCPKG.ps1";     Title = "Build the dependency set" },
    @{ Number = 5; File = "5-Verify_Env.ps1";     Title = "Verify the finished environment" },
    @{ Number = 6; File = "6-Clone_Repos.ps1";    Title = "Clone the workspace repositories" }
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

# ELEVATION IS CHECKED HERE, once, rather than left to step 1. Step 1 can elevate itself by relaunching, but the
# elevated copy lands in its OWN console window: this runner would see the launcher exit, call the step done,
# and race ahead into step 2 while step 1 was still formatting the drive in a window nobody is watching.
if (-not (Test-IsAdministrator))
{
    Write-Host "[ERROR] This runner must be started from an elevated PowerShell." -ForegroundColor Red
    Write-Host "        Step 1 uses diskpart, and a step that elevates itself would open a second window this" -ForegroundColor Red
    Write-Host "        runner cannot wait on -- so it is required up front instead of discovered halfway in." -ForegroundColor Red
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
if ($ValidateOnly) { Write-Host "  Mode          : validate the configuration only, change nothing" }
Write-Host ""

$results   = @()
$runStart  = Get-Date
$failed    = $null
$cancelled = $false

foreach ($step in $selected)
{
    $path = Join-Path $scriptDir $step.File
    $stepArgs = @("-ConfigFile", ('"{0}"' -f $ConfigFile))
    if ($ValidateOnly) { $stepArgs += "-ValidateOnly" }

    Write-Banner ("STEP {0}/{1}  --  {2}" -f $step.Number, $stepDefs.Count, $step.Title)
    $host.UI.RawUI.WindowTitle = ("DrivEnv -- step {0}: {1}" -f $step.Number, $step.Title)

    $start = Get-Date
    $code  = Invoke-Step -Path $path -Arguments $stepArgs
    $span  = (Get-Date) - $start

    $results += [pscustomobject]@{
        Number   = $step.Number
        Title    = $step.Title
        ExitCode = $code
        Duration = $span
    }

    if ($code -eq 0)
    {
        Write-Host ("[OK] Step {0} finished in {1}." -f $step.Number, (Format-Duration $span)) -ForegroundColor Green
        continue
    }

    # 1223 is ERROR_CANCELLED, which step 4 returns when Ctrl-C tore the build down on purpose. It is not a
    # failure and must not be reported as one: nothing is wrong with the environment, somebody stopped it.
    if ($code -eq 1223)
    {
        $cancelled = $true
        Write-Host ("[CANCELLED] Step {0} was stopped after {1}." -f $step.Number, (Format-Duration $span)) -ForegroundColor Yellow
    }
    else
    {
        $failed = $step
        Write-Host ("[FAILED] Step {0} exited with code {1} after {2}." -f $step.Number, $code, (Format-Duration $span)) -ForegroundColor Red
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
    Write-Host ("  {0}  {1,-38} {2,8}   {3}" -f $r.Number, $r.Title, (Format-Duration $r.Duration), $status) -ForegroundColor $colour
}

$notRun = @($selected | Where-Object { $_.Number -notin ($results | ForEach-Object { $_.Number }) })
foreach ($n in $notRun)
{
    Write-Host ("  {0}  {1,-38} {2,8}   not run" -f $n.Number, $n.Title, "-") -ForegroundColor DarkGray
}

Write-Host ""
Write-Host ("  Total: {0}" -f (Format-Duration $total))
Write-Host ""

$host.UI.RawUI.WindowTitle = $originalTitle

if ($cancelled)
{
    Write-Host "Cancelled. Nothing is broken -- resume with:" -ForegroundColor Yellow
    Write-Host ("    .\Generate-DrivEnv.ps1 -ConfigFile `"{0}`" -From {1}" -f $ConfigFile, $results[-1].Number) -ForegroundColor Yellow
    exit 1223
}

if ($failed)
{
    Write-Host ("Stopped at step {0}. Its log says why; fix that, then resume with:" -f $failed.Number) -ForegroundColor Red
    Write-Host ("    .\Generate-DrivEnv.ps1 -ConfigFile `"{0}`" -From {1}" -f $ConfigFile, $failed.Number) -ForegroundColor Red
    exit 1
}

Write-Host "Generation complete." -ForegroundColor Green
exit 0
