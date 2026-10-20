# ====================================================================
# DRIVENV MOUNT TASK INVENTORY AND CLEANUP
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Lists the scheduled tasks that mount a VHDX at startup, flags those whose
# VHDX no longer exists, and removes them on request. Standalone (no
# configuration, no modules), so it works after the drives are gone. Not
# part of step 1: cleaning up other environments is a person's decision.
#
#   .\tools\Manage-MountTasks.ps1                  list, change nothing
#   .\tools\Manage-MountTasks.ps1 -Remove          remove orphans, asking first
#   .\tools\Manage-MountTasks.ps1 -Remove -WhatIf
# ====================================================================

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param
(
    # @brief Remove the tasks reported as orphaned. Without it nothing is ever changed.
    [switch]$Remove,

    # @brief Also list tasks whose VHDX still exists (never removed).
    [bool]$ShowLive = $true
)

# --------------------------------------------------------------------
# FUNCTIONS
# --------------------------------------------------------------------

function Test-IsAdministrator
{
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MountTaskInventory
{
    # @brief Every scheduled task with a Mount-VHD action, its path and that path's state.
    # Found by action, not by name. Parses the -Argument step 1 builds: keep both in step.

    $inventory = @()

    foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue))
    {
        foreach ($action in @($task.Actions))
        {
            $arguments = [string]$action.Arguments
            if ($arguments -notmatch 'Mount-VHD') { continue }

            $m = [regex]::Match($arguments, "-Path\s+'([^']+)'")
            if (-not $m.Success)
            {
                $m = [regex]::Match($arguments, '-Path\s+"([^"]+)"')
            }
            if (-not $m.Success) { continue }

            $raw  = $m.Groups[1].Value
            $full = $raw
            try { $full = [System.IO.Path]::GetFullPath($raw) } catch { }

            # A VHDX on an absent volume (unplugged disk, disconnected share) is reported, never treated as orphan.
            $state = "orphan"
            $note  = ""

            $root = $null
            try { $root = [System.IO.Path]::GetPathRoot($full) } catch { }

            if ([string]::IsNullOrWhiteSpace($root))
            {
                $state = "unknown"
                $note  = "could not determine the volume for this path"
            }
            elseif (-not (Test-Path -LiteralPath $root))
            {
                $state = "offline"
                $note  = "the volume $root is not present; nothing can be concluded about the file"
            }
            elseif (Test-Path -LiteralPath $full)
            {
                $state = "live"
            }

            $inventory += [pscustomobject]@{
                TaskName = $task.TaskName
                TaskPath = $task.TaskPath
                FullName = ($task.TaskPath + $task.TaskName)
                Vhd      = $full
                State    = $state
                Note     = $note
            }

            break   # one action is enough to classify the task
        }
    }

    return $inventory
}

# --------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------

$ErrorActionPreference = "Stop"

# Elevation is needed even to READ: unelevated, Get-ScheduledTask silently omits the SYSTEM tasks step 1 registers.
if (-not (Test-IsAdministrator))
{
    Write-Host "[ERROR] Run this from an elevated PowerShell." -ForegroundColor Red
    Write-Host "        These tasks run as SYSTEM, and Get-ScheduledTask does not return them to a" -ForegroundColor Red
    Write-Host "        non-elevated caller -- it omits them silently, with no error. Unelevated, this" -ForegroundColor Red
    Write-Host "        script would report 'none found' whether or not that was true, which is worse" -ForegroundColor Red
    Write-Host "        than refusing to run." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Scheduled tasks that mount a VHDX at startup" -ForegroundColor Cyan
Write-Host ("=" * 78) -ForegroundColor Cyan

$inventory = @(Get-MountTaskInventory)

if ($inventory.Count -eq 0)
{
    Write-Host "  None found."
    Write-Host ""
    exit 0
}

$orphans = @($inventory | Where-Object { $_.State -eq "orphan" })
$live    = @($inventory | Where-Object { $_.State -eq "live" })
$other   = @($inventory | Where-Object { $_.State -ne "orphan" -and $_.State -ne "live" })

$shown = @()
$shown += $orphans
if ($ShowLive) { $shown += $live }
$shown += $other

foreach ($item in $shown)
{
    $colour = switch ($item.State)
    {
        "live"    { "Green" }
        "orphan"  { "Yellow" }
        default   { "DarkGray" }
    }
    Write-Host ("  {0,-9} {1}" -f $item.State, $item.FullName) -ForegroundColor $colour
    Write-Host ("            mounts {0}" -f $item.Vhd) -ForegroundColor DarkGray
    if ($item.Note) { Write-Host ("            {0}" -f $item.Note) -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host ("  {0} task(s): {1} live, {2} orphaned, {3} undecidable." -f
            $inventory.Count, $live.Count, $orphans.Count, $other.Count)

if ($orphans.Count -eq 0)
{
    Write-Host "  Nothing to clean up." -ForegroundColor Green
    Write-Host ""
    exit 0
}

if (-not $Remove)
{
    Write-Host ""
    Write-Host "  Re-run with -Remove to unregister the orphaned task(s)." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# Only the root folder, where step 1 registers: tasks elsewhere belong to someone else.
$removable = @($orphans | Where-Object { $_.TaskPath -eq '\' })
$foreign   = @($orphans | Where-Object { $_.TaskPath -ne '\' })

foreach ($item in $foreign)
{
    Write-Host ("  [SKIP] {0} is orphaned but lives outside the root task folder; remove it by hand if it is yours." -f $item.FullName) -ForegroundColor Yellow
}

Write-Host ""
$removed = 0
$failed  = 0

foreach ($item in $removable)
{
    if (-not $PSCmdlet.ShouldProcess($item.FullName, ("Unregister the task that mounts {0}" -f $item.Vhd)))
    {
        continue
    }

    try
    {
        Unregister-ScheduledTask -TaskName $item.TaskName -TaskPath $item.TaskPath -Confirm:$false -ErrorAction Stop
        Write-Host ("  [OK] removed {0}" -f $item.FullName) -ForegroundColor Green
        $removed++
    }
    catch
    {
        Write-Host ("  [FAILED] {0}: {1}" -f $item.FullName, $_.Exception.Message) -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host ("  Removed {0}, failed {1}." -f $removed, $failed)
Write-Host ""

if ($failed -gt 0) { exit 1 }
exit 0
