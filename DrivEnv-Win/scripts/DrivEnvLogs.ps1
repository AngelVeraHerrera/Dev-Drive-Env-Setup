# ====================================================================
# DRIVENV LOG PRESERVATION
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
#          David Abuín Sánchez
# License: MIT
# ====================================================================
#
# Two jobs, both about keeping evidence that the normal course of events destroys.
#
# 1. A FAILED PORT'S LOGS, SAVED BEFORE THE RETRY.
#
#    vcpkg writes its per-port logs into the buildtree under fixed names -- build-<triplet>-rel-err.log and
#    friends -- and the next attempt at the same port OVERWRITES them. So with retries enabled the only logs
#    that survive a run are the last attempt's, and the first failure, which is usually the informative one,
#    is gone by the time anybody looks. Copying them out between attempts is the whole point.
#
# 2. THE SETUP SCRIPTS' OWN LOGS, COPIED ONTO THE DRIVE.
#
#    Steps 1 to 6 log into install_logs/ beside the scripts, which lives in the repository working copy --
#    a different disk from the environment it just built, and one that gets cloned, moved and cleaned. A
#    drive that carries the record of how it was made can be handed to somebody else, or looked at a year
#    later, without needing that working copy to still exist.
#
# This lives in its own file rather than in DrivEnvConfig.ps1, which is the schema and validator, and rather
# than being copied into all six scripts, which is how the Write-Info family ended up duplicated six times --
# and how two of those copies ended up missing Write-Warn entirely.
#
# NOTHING HERE IS ALLOWED TO BE FATAL. Losing a log copy is worth a warning; it is not worth failing a build
# that otherwise worked, and it is certainly not worth failing an abort path that is already reporting a real
# error. Every function swallows its own exceptions and says so.

function Get-DrivEnvLogRoot
{
    # @brief "<letter>:\logs", or an empty string when the drive is not usable yet.
    #
    # Returns empty rather than throwing, because step 1 calls this before the drive exists and its abort
    # path calls it when the drive may have failed to mount.
    param ([string]$DriveLetter)

    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return "" }

    # "T", "T:", "T:\" and "T:/" all name the same drive, and different callers here spell it differently, so
    # strip the decoration instead of accepting one form. Trimming the whole SET of characters, not one kind at
    # a time: chaining TrimEnd(':').TrimEnd('\') leaves "T:" for the input "T:\", which then fails the check
    # below and returns nothing -- a caller holding a rooted path would get no logs and no complaint.
    $letter = ([string]$DriveLetter).Trim().TrimEnd(@(':', '\', '/'))
    if ($letter -notmatch '^[A-Za-z]$') { return "" }

    $root = "{0}:\logs" -f $letter.ToUpperInvariant()
    if (-not (Test-Path -LiteralPath ("{0}:\" -f $letter))) { return "" }

    return $root
}

function Copy-SetupLogToDrive
{
    # @brief Copy one step's log onto the drive, under <letter>:\logs\setup\.
    #
    # Called both on the success path and from Abort-WithError, and the failure case is the one that matters:
    # the log of a run that died is exactly the one somebody will want, and it is the one nobody thinks to
    # save. Overwrites its own previous copy, because the file name already carries the run's timestamp.
    param
    (
        [string]$LogFile,
        [string]$DriveLetter
    )

    if ([string]::IsNullOrWhiteSpace($LogFile)) { return }
    if (-not (Test-Path -LiteralPath $LogFile)) { return }

    $root = Get-DrivEnvLogRoot -DriveLetter $DriveLetter
    if ([string]::IsNullOrWhiteSpace($root)) { return }

    try
    {
        $dest = Join-Path $root "setup"
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

        Copy-Item -LiteralPath $LogFile -Destination (Join-Path $dest (Split-Path $LogFile -Leaf)) `
                  -Force -ErrorAction Stop
    }
    catch
    {
        # Deliberately Write-Host and not Write-Warn: this is called from Abort-WithError, and depending on a
        # logging function there is how an abort turns into a CommandNotFoundException on top of the original
        # failure. Write-Host exists everywhere.
        Write-Host ("[WARN] Could not copy the setup log onto the drive: {0}" -f $_.Exception.Message)
    }
}

function Save-VcpkgFailureLogs
{
    # @brief Copy a failed port's buildtree logs to <letter>:\logs\vcpkg\<port>\attempt<N>_<stamp>\.
    #
    # Called after each failed attempt and BEFORE the next one starts, because that next attempt overwrites
    # the files being copied here. One directory per attempt, so a port that failed four times leaves four
    # sets rather than one, and the timestamp keeps re-runs of the whole step apart.
    #
    # Returns the destination directory, or an empty string if nothing was saved, so the caller can name it.
    param
    (
        [string]$PortName,
        [int]   $Attempt,
        [string]$BuildtreesRoot,
        [string]$DriveLetter
    )

    if ([string]::IsNullOrWhiteSpace($PortName)) { return "" }

    $root = Get-DrivEnvLogRoot -DriveLetter $DriveLetter
    if ([string]::IsNullOrWhiteSpace($root)) { return "" }

    try
    {
        # The buildtrees root arrives in the POSIX form step 4 hands to bash, "/t/bt". Accept the drive form
        # too, so a caller that has the Windows path does not have to convert it first.
        $win = ([string]$BuildtreesRoot).Trim()
        if ($win -match '^/([A-Za-z])/(.*)$') { $win = "{0}:/{1}" -f $Matches[1], $Matches[2] }
        $win = $win -replace '/', '\'

        $portDir = Join-Path $win $PortName
        if (-not (Test-Path -LiteralPath $portDir)) { return "" }

        $logs = @(Get-ChildItem -LiteralPath $portDir -Filter "*.log" -File -ErrorAction SilentlyContinue)
        if ($logs.Count -eq 0) { return "" }

        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $dest  = Join-Path (Join-Path (Join-Path $root "vcpkg") $PortName) ("attempt{0}_{1}" -f $Attempt, $stamp)
        New-Item -ItemType Directory -Path $dest -Force | Out-Null

        foreach ($log in $logs)
        {
            Copy-Item -LiteralPath $log.FullName -Destination (Join-Path $dest $log.Name) -Force -ErrorAction Stop
        }

        return $dest
    }
    catch
    {
        Write-Host ("[WARN] Could not preserve the failure logs for '{0}': {1}" -f $PortName, $_.Exception.Message)
        return ""
    }
}
