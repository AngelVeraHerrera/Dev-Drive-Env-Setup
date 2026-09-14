# ====================================================================
# DRIVENV MOUNT TASK INVENTORY AND CLEANUP
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
# Updated: 14/09/2026
# Version: 1.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Lists every scheduled task on this machine that mounts a VHDX at
# startup, says which of them point at a file that no longer exists, and
# removes those on request.
#
# WHY THIS EXISTS. Step 1 registers a task per environment, named after
# the volume label, and nothing has ever removed one. Delete a dev drive
# -- or regenerate it under a different label -- and its task stays
# behind, firing at every boot, failing silently because the action ends
# in -ErrorAction SilentlyContinue, and invisible because nobody looks a
# scheduled task up by what it does. Measured on the development machine:
# five such tasks, two of them pointing at VHDX files that had been
# deleted months earlier.
#
# It is DELIBERATELY NOT part of step 1. A generation run for one
# environment has no business deleting state that belongs to another, and
# the moment it does, a VHDX temporarily moved or renamed costs somebody
# their mount task without being asked. Cleaning up across environments
# is a decision a person makes, so it is a command a person runs.
#
# STANDALONE ON PURPOSE: no configuration, no dev drive, no modules. It
# can be copied to a machine whose drives are long gone and still work,
# which is exactly the machine that needs it.
#
#   .\Manage-MountTasks.ps1              list everything, change nothing
#   .\Manage-MountTasks.ps1 -Remove      remove the orphans, asking first
#   .\Manage-MountTasks.ps1 -Remove -WhatIf
#   .\Manage-MountTasks.ps1 -Remove -Confirm:$false
#
# ====================================================================

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param
(
    # @brief Remove the tasks reported as orphaned. Without it nothing is ever changed.
    [switch]$Remove,

    # @brief Also list tasks whose VHDX is still present. They are never removed; this only shows them.
    #
    # On by default, because an inventory that hides the healthy entries cannot be checked against what you
    # expect to be there, and "which of my drives still mount themselves" is the other half of the question.
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
    # @brief Every scheduled task with a Mount-VHD action, with the path it mounts and what state that path is in.
    #
    # IDENTIFIED BY WHAT THE TASK DOES, not by its name. These tasks are named after a volume label, so a name
    # tells you nothing about who wrote them, and looking one up by name across task folders is how a cleanup
    # ends up unregistering a vendor task that happened to share a label. An action containing Mount-VHD with a
    # quoted -Path is a thing nothing else on a Windows machine does.
    #
    # This parses the argument string step 1 builds. The two have to stay in sight of each other: change the
    # shape of that -Argument and this stops finding anything, silently and with no error to notice.

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

            # THREE STATES, and the third one is the reason this is not just "does the file exist".
            #
            # A VHDX on a volume that is not currently present -- an external disk unplugged, a network share
            # disconnected -- looks exactly like a deleted one to Test-Path. Removing its task on that evidence
            # would destroy a perfectly good environment because somebody pulled a USB cable. So the volume is
            # checked first, and when it is absent the task is reported and left strictly alone.
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

# ELEVATION IS REQUIRED TO READ, not only to delete, and that is the trap this check exists to close.
#
# The generator registers these tasks with a SYSTEM principal. Get-ScheduledTask run without elevation does not
# fail on them and does not warn -- it silently omits them from its output. Measured on the development machine:
# 172 tasks returned unelevated, none of them matching Mount-VHD, while five such tasks existed. An unelevated
# run of this script would therefore print a clean, confident, completely false "no tasks found".
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

# ONLY FROM THE ROOT TASK FOLDER. Step 1 has always registered at '\', so an orphan of ours can only be there.
# A Mount-VHD task living under \Microsoft\Windows\ or a vendor folder was put there by something else, and a
# cleanup tool that reaches into other people's folders on a pattern match is the bug it was written to fix.
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
