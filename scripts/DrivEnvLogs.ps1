# ====================================================================
# DRIVENV LOG PRESERVATION
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
#          David Abuín Sánchez
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Keeps the evidence a run would otherwise destroy: a failed port's logs,
# saved before the retry overwrites them, and each step's own log, copied
# onto the drive (<letter>:\logs) so the drive carries how it was made.
# Nothing here is fatal: every function swallows its errors and warns.

function Get-DrivEnvLogRoot
{
    # @brief "<letter>:\logs", or "" when the drive is not usable yet (step 1, or an abort before mounting).
    param ([string]$DriveLetter)

    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { return "" }

    # Accept "T", "T:", "T:\" and "T:/": trim the whole character set at once.
    $letter = ([string]$DriveLetter).Trim().TrimEnd(@(':', '\', '/'))
    if ($letter -notmatch '^[A-Za-z]$') { return "" }

    $root = "{0}:\logs" -f $letter.ToUpperInvariant()
    if (-not (Test-Path -LiteralPath ("{0}:\" -f $letter))) { return "" }

    return $root
}

function Copy-SetupLogToDrive
{
    # @brief Copy one step's log to <letter>:\logs\setup\, on success and from Abort-WithError (the log that matters).
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
        # Write-Host, not Write-Warn: this runs inside Abort-WithError and must not depend on another function.
        Write-Host ("[WARN] Could not copy the setup log onto the drive: {0}" -f $_.Exception.Message)
    }
}

function Save-VcpkgFailureLogs
{
    # @brief Copy a failed port's logs to <letter>:\logs\vcpkg\<port>\attempt<N>_<key>_<stamp>\ before the next attempt
    # overwrites them. With -Since, only files this attempt wrote (the folder also holds older runs and the other
    # triplet's logs). Returns the destination, or "" if nothing was saved.
    param
    (
        [string]  $PortName,
        [int]     $Attempt,
        [string]  $BuildtreesRoot,
        [string]  $DriveLetter,
        # When the attempt began; a log last written before it is left out. The default takes every log.
        [datetime]$Since = [datetime]::MinValue,
        # The toolchain the attempt was for, put in the folder name: attempt<N>_<key>_<stamp>. One port's folder holds
        # every toolchain's failures, and "attempt1" alone does not say whose.
        [string]  $ToolchainKey = ""
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

        $logs = @(Get-ChildItem -LiteralPath $portDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -ge $Since })
        if ($logs.Count -eq 0) { return "" }

        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $leaf  = if ([string]::IsNullOrWhiteSpace($ToolchainKey)) { "attempt{0}_{1}" -f $Attempt, $stamp }
                 else { "attempt{0}_{1}_{2}" -f $Attempt, $ToolchainKey.Trim(), $stamp }
        $dest  = Join-Path (Join-Path (Join-Path $root "vcpkg") $PortName) $leaf
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
