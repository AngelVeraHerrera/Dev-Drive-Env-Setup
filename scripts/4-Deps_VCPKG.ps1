# ====================================================================
# VCPKG DEPENDENCIES SETUP SCRIPT
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
#          David Abuin Sanchez
# Updated: 27/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Needs steps 1 to 3. vcpkg CLASSIC mode: ports install once into
# <VCPKG_ROOT>\installed, shared by every project on the drive. A reference
# manifest is also written under <drive>:\env for a later move to manifest mode.
# ====================================================================

# FUNCTIONS
# --------------------------------------------------------------------

param
(
    # @brief JSON configuration. A bare name resolves against config/. Every step must get the same file.
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief Toolchain id of a configuration with 'toolchains', e.g. -Toolchain ucrt. Empty for a single-toolchain
    # configuration. Resolved once below, so the rest of the script sees one subsystem and one triplet.
    [string]$Toolchain = "",

    # @brief Validate the configuration and stop, changing nothing.
    [switch]$ValidateOnly
)

function Write-NoFormat
{
    param ($msg)
    Write-Host $msg
    if ($globalLogFile) {Add-Content -Path $globalLogFile -Value $msg}
}

function Write-Info
{
    param ($msg)
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][INFO][$msg]"
    Write-Host $line
    if ($globalLogFile) {Add-Content -Path $globalLogFile -Value $line}
}

function Write-Warn
{
    param ($msg)
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][WARN][$msg]"
    Write-Host $line
    if ($globalLogFile) {Add-Content -Path $globalLogFile -Value $line}
}

function Write-Error
{
    param ($msg)
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][ERROR][$msg]"
    Write-Host $line
    if ($globalLogFile){Add-Content -Path $globalLogFile -Value $line}
}

function Abort-WithError
{
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][ERROR][Setup failed!]"
    Write-Host $line
    if ($globalLogFile){Add-Content -Path $globalLogFile -Value $line}

    # UserInteractive is also True with stdin redirected, where ReadKey throws: check both.
    if ([Environment]::UserInteractive -and -not [System.Console]::IsInputRedirected) {
        Write-Host ""
        Write-Host "Press any key to exit..."
        [void][System.Console]::ReadKey($true)
    }

    if ($originalTitle) { $host.UI.RawUI.WindowTitle = $originalTitle }
    # The log of a run that died is the one somebody will want, and the one nobody saves.
    if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }
    exit 1
}

function Test-IsAdministrator
{
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScriptDirectory
{
    if ($PSScriptRoot) { return $PSScriptRoot }
    else { return Split-Path -Parent (Convert-Path -LiteralPath ([System.Environment]::GetCommandLineArgs()[0])) }
}

function Convert-ToMSYSPath($winPath)
{
    return $winPath -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
}

function Convert-ToDriveStylePath($winPath)
{
    # @brief Normalize a Windows path to the forward-slash drive style used by the .env files
    #        (e.g. "X:\vcpkg" -> "X:/vcpkg"). This form is what vcpkg.exe itself expects.
    return ([string]$winPath) -replace '\\', '/'
}

function Convert-ToWinPath($anyPath)
{
    return ([string]$anyPath) -replace '/', '\'
}

function Read-EnvFile
{
    # @brief Parse a KEY=VALUE environment file into a hashtable. Values are kept verbatim.
    param ([string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }

    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8))
    {
        $line = ([string]$raw).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith("#")) { continue }

        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }

        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        $map[$key] = $val
    }

    return $map
}

function New-Msys2ScriptHeader
{
    # @brief Bash preamble entering the MSYS2 environment and exporting the vcpkg variables in Windows form
    #        (vcpkg.exe is native; the launcher's .env loading converts paths to POSIX form).
    param
    (
        [string]$Msys2Env,
        [string]$VcpkgRootDrive,
        [string]$VcpkgRootUnix,
        [string]$Triplet,
        [string]$OverlayPorts,
        [string]$OverlayTriplets,
        [string]$BinaryCache
    )

    $msysEnvUpper = $Msys2Env.ToUpperInvariant()

    # No 'set -e' while entering the environment: /etc/profile returns non-zero internally and would abort silently.
    return @"
if command -v shell >/dev/null 2>&1; then
    source shell $Msys2Env || true
else
    export MSYSTEM=$msysEnvUpper
    source /etc/profile || true
fi

if [ "`$MSYSTEM" != "$msysEnvUpper" ]; then
    echo "[env] ERROR: failed to enter the $msysEnvUpper environment (MSYSTEM='`$MSYSTEM')" >&2
    exit 1
fi

export VCPKG_ROOT='$VcpkgRootDrive'
export VCPKG_DEFAULT_TRIPLET='$Triplet'
export VCPKG_DEFAULT_HOST_TRIPLET='$Triplet'
export VCPKG_OVERLAY_PORTS='$OverlayPorts'
export VCPKG_OVERLAY_TRIPLETS='$OverlayTriplets'
export VCPKG_DEFAULT_BINARY_CACHE='$BinaryCache'
export VCPKG_DISABLE_METRICS=1

cd '$VcpkgRootUnix' || { echo "[env] ERROR: cannot enter '$VcpkgRootUnix'" >&2; exit 1; }

if [ ! -x ./vcpkg ] && [ ! -f ./vcpkg.exe ]; then
    echo "[env] ERROR: no vcpkg executable in '$VcpkgRootUnix'" >&2
    exit 1
fi

echo "[env] MSYSTEM=`$MSYSTEM"
echo "[env] PWD=`$(pwd)"
echo "[env] VCPKG_DEFAULT_TRIPLET=`$VCPKG_DEFAULT_TRIPLET"
"@
}

# --------------------------------------------------------------------
# CANCELLATION
# --------------------------------------------------------------------
# Ctrl-C used to stop PowerShell while bash, vcpkg and the compilers kept building, holding the vcpkg lock.
# A shared object, not a variable: the handler runs on another thread.
$script:cancelState = [pscustomobject]@{ Requested = $false }

function Enable-CancelHandling
{
    # @brief Take over Ctrl-C ($e.Cancel = $true) so Invoke-Msys2Script kills the build tree and the script exits
    # through its normal reporting. A second Ctrl-C is left to the runtime, so a wedged kill can still be escaped.
    if ($script:cancelHandlerRegistered) { return }

    try
    {
        $script:cancelHandler = [System.ConsoleCancelEventHandler] {
            param ($sender, $e)
            $e.Cancel = $true
            $script:cancelState.Requested = $true
            Write-Host ""
            Write-Host "[CANCEL] Ctrl-C received. Stopping the build and shutting down; this takes a moment."
        }

        [System.Console]::add_CancelKeyPress($script:cancelHandler)
        $script:cancelHandlerRegistered = $true
    }
    catch
    {
        # No console (a scheduled task, a redirected host) means no Ctrl-C to catch. Not a problem, but say so
        # rather than leaving the user to believe cancellation is armed when it is not.
        Write-Warn ("Could not install the Ctrl-C handler: {0}" -f $_.Exception.Message)
        Write-Warn "Cancellation will not be graceful in this host; a Ctrl-C may orphan the build processes."
    }
}

function Test-CancelRequested
{
    return [bool]$script:cancelState.Requested
}

function Initialize-JobObjectSupport
{
    # @brief Compile the kernel32 calls to kill a build by job object. taskkill /T walks parent pids and misses
    # grandchildren whose parent died (measured: two sleeps survived). A job kills by membership, and
    # KILL_ON_JOB_CLOSE tears the build down even if this script dies.
    if ($script:jobObjectReady) { return $true }

    try
    {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DrivEnvJob
{
    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    const int  JobObjectExtendedLimitInformation  = 9;
    const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObjectW(IntPtr attrs, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint cbInfo);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);

    public static IntPtr Create()
    {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) { return IntPtr.Zero; }

        var ext = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        ext.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

        int  size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr buf = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(ext, buf, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buf, (uint)size))
            {
                CloseHandle(job);
                return IntPtr.Zero;
            }
        }
        finally { Marshal.FreeHGlobal(buf); }

        return job;
    }

    public static bool Assign(IntPtr job, IntPtr process)
    {
        if (job == IntPtr.Zero || process == IntPtr.Zero) { return false; }
        return AssignProcessToJobObject(job, process);
    }

    public static bool Terminate(IntPtr job)
    {
        if (job == IntPtr.Zero) { return false; }
        return TerminateJobObject(job, 1223);
    }

    public static void Close(IntPtr job)
    {
        if (job != IntPtr.Zero) { CloseHandle(job); }
    }
}
'@
        $script:jobObjectReady = $true
        return $true
    }
    catch
    {
        # Falling back is worth doing rather than refusing to run: taskkill catches the common shapes even if it
        # loses the races. Say so plainly, because the difference shows up as orphaned compilers.
        Write-Warn ("Could not compile the job-object helper: {0}" -f $_.Exception.Message)
        Write-Warn "Cancellation will fall back to taskkill, which can leave grandchild processes running."
        $script:jobObjectReady = $false
        return $false
    }
}

function Stop-ProcessTree
{
    # @brief Kill a build: the job object, then taskkill for anything spawned before it joined the job.
    # By pid and job handle, never by image name (other compilers may be running on other drives).
    param
    (
        [int]   $ProcessId,
        [IntPtr]$JobHandle = [IntPtr]::Zero
    )

    if ($JobHandle -ne [IntPtr]::Zero)
    {
        try   { $null = [DrivEnvJob]::Terminate($JobHandle) }
        catch { Write-Warn ("Job-object terminate failed: {0}" -f $_.Exception.Message) }
    }

    if ($ProcessId -le 0) { return }

    try
    {
        $null = & (Join-Path (Join-Path $env:SystemRoot "System32") "taskkill.exe") /T /F /PID $ProcessId 2>&1
    }
    catch
    {
        Write-Warn ("Could not kill the process tree at pid {0}: {1}" -f $ProcessId, $_.Exception.Message)
    }
}

function Invoke-Msys2Script
{
    # @brief Run a bash script in the MSYS2 login shell, mirroring its output into the log. Returns its exit code,
    #        or 1223 (ERROR_CANCELLED) when cancelled. Bash merges stdout/stderr into a file that this tails: no pipe
    #        to deadlock, and the poll loop is where cancellation is noticed.
    param
    (
        [string]$BashPath,
        [string]$ScriptBody,
        [string]$TempName
    )

    $tempScript = Join-Path $env:TEMP $TempName
    $outFile    = Join-Path $env:TEMP ($TempName + ".out")
    $utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText($tempScript, ($ScriptBody -replace "`r`n", "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText($outFile, "", $utf8NoBom)

    $tempScriptUnix = Convert-ToMSYSPath $tempScript
    $outFileUnix    = Convert-ToMSYSPath $outFile

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $BashPath
    $psi.Arguments       = "-lc ""bash '$tempScriptUnix' > '$outFileUnix' 2>&1"""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    $proc   = $null
    $reader = $null
    $job    = [IntPtr]::Zero
    $code   = 1

    try
    {
        $proc = [System.Diagnostics.Process]::Start($psi)

        # Into a job object immediately, so a cancellation can kill the whole build by membership rather than by
        # chasing parent pids. Assigned right after Start and not before, because there is no supported way to
        # start a process suspended from PowerShell; the gap is microseconds, and taskkill covers what escapes.
        if (Initialize-JobObjectSupport)
        {
            $job = [DrivEnvJob]::Create()
            if ($job -eq [IntPtr]::Zero)
            {
                Write-Warn "Could not create a job object; cancellation falls back to taskkill alone."
            }
            elseif (-not [DrivEnvJob]::Assign($job, $proc.Handle))
            {
                Write-Warn "Could not assign the build to its job object; falling back to taskkill alone."
                [DrivEnvJob]::Close($job)
                $job = [IntPtr]::Zero
            }
        }

        # FileShare.ReadWrite, because bash is writing this file while we read it. Anything narrower fails with
        # a sharing violation on the first poll.
        $stream = New-Object System.IO.FileStream($outFile, [System.IO.FileMode]::Open,
                                                  [System.IO.FileAccess]::Read,
                                                  [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)

        $cancelled = $false

        while (-not $proc.HasExited)
        {
            while ($null -ne ($line = $reader.ReadLine())) { Write-NoFormat ("    | " + $line) }

            if ((Test-CancelRequested) -and -not $cancelled)
            {
                $cancelled = $true
                Write-Warn ("Cancelling '{0}': killing the build (pid {1})." -f $TempName, $proc.Id)
                Stop-ProcessTree -ProcessId $proc.Id -JobHandle $job
            }

            Start-Sleep -Milliseconds 200
        }

        # Whatever bash wrote between the last poll and its exit. Skipping this loses the actual error message
        # roughly one run in three, since a failing build tends to die shortly after printing why.
        while ($null -ne ($line = $reader.ReadLine())) { Write-NoFormat ("    | " + $line) }

        $code = if ($cancelled -or (Test-CancelRequested)) { 1223 } else { $proc.ExitCode }
        return $code
    }
    catch
    {
        Write-Error ("Failed to run the MSYS2 script '{0}': {1}" -f $TempName, $_.Exception.Message)
        return 1
    }
    finally
    {
        if ($reader) { $reader.Dispose() }

        # A cancelled run may still have a live tree if taskkill lost a race with a process that had not been
        # created yet when it walked the chain. One more sweep, by pid, costs nothing.
        if ($proc -and -not $proc.HasExited) { Stop-ProcessTree -ProcessId $proc.Id -JobHandle $job }

        # Closing the handle is itself a kill, because the job carries KILL_ON_JOB_CLOSE. Harmless on the
        # success path -- the build has already exited -- and a safety net on every other path.
        if ($job -ne [IntPtr]::Zero) { [DrivEnvJob]::Close($job) }
        if ($proc) { $proc.Dispose() }

        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outFile    -Force -ErrorAction SilentlyContinue
    }
}

function Get-Msys2ScriptOutput
{
    # @brief Same as Invoke-Msys2Script but captures the output instead of logging it.
    param
    (
        [string]$BashPath,
        [string]$ScriptBody,
        [string]$TempName
    )

    $tempScript = Join-Path $env:TEMP $TempName
    $utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tempScript, ($ScriptBody -replace "`r`n", "`n"), $utf8NoBom)

    $tempScriptUnix = Convert-ToMSYSPath $tempScript

    try
    {
        $out = & $BashPath -lc "bash '$tempScriptUnix'" 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = @($out) }
    }
    finally
    {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

# These helpers must be defined above their first use (the port-parsing loop): PowerShell runs top to bottom, and the
# "not recognized" error is non-terminating, so packages would silently fall back to the global schedule.
function Resolve-OverlayLayers
{
    # @brief The overlay layers a triplet searches, in order (exact triplet, then "*", then "ports"). Names, not paths.
    # Resolved per port, so one vcpkg tree can hold triplets with different overlays.
    param ($OverlayConfig, [string]$Triplet)

    $fallback = $null

    foreach ($entry in @($OverlayConfig))
    {
        if ($null -eq $entry) { continue }

        $entryTriplet = ([string]$entry.triplet).Trim()
        $layers = @()
        foreach ($layer in @($entry.layers))
        {
            $name = ([string]$layer).Trim() -replace '^[\/]+', '' -replace '[\/]+$', ''
            if (-not [string]::IsNullOrWhiteSpace($name)) { $layers += $name }
        }
        if ($layers.Count -eq 0) { continue }

        if ($entryTriplet -eq $Triplet) { return ,([string[]]$layers) }
        if ($entryTriplet -eq '*' -and $null -eq $fallback) { $fallback = [string[]]$layers }
    }

    if ($null -ne $fallback) { return ,([string[]]$fallback) }

    return ,([string[]]@("ports"))
}

function ConvertTo-InstallSchedule
{
    # @brief An install_schedule array as the concurrency of each attempt; 0 lets vcpkg size the build. Already
    #        validated by DrivEnvConfig.ps1; an entry without 'concurrency' is 0.
    param ($Entries)

    $out = @()
    foreach ($entry in @($Entries))
    {
        # Piped rather than $entry.PSObject.Properties.Name, for the reason DrivEnvConfig.ps1 documents at
        # length: on a bare {} the member access yields $null, and @($null) is an array holding one null.
        $keys = @()
        if ($null -ne $entry) { $keys = @($entry.PSObject.Properties | ForEach-Object { $_.Name }) }

        if ($keys -contains 'concurrency') { $out += [int]$entry.concurrency } else { $out += 0 }
    }

    # Comma-wrapped so a ONE-attempt schedule comes back as an array of one rather than as a bare int:
    # PowerShell unrolls an array returned from a function, and a single element then arrives as a scalar.
    return ,([int[]]$out)
}

function Resize-InstallSchedule
{
    # @brief Force a schedule to exactly $Count attempts. Longer is truncated; shorter is extended by REPEATING
    #        THE LAST entry, because the last entry is the careful one -- a schedule ends at whatever concurrency
    #        was chosen for the worst case, so extra attempts should inherit it rather than invent one.
    param ([int[]]$Schedule, [int]$Count)

    if ($Schedule.Count -eq 0) { $Schedule = [int[]]@(0) }
    if ($Count -lt 1)          { $Count = 1 }

    $out = @()
    for ($i = 0; $i -lt $Count; $i++)
    {
        if ($i -lt $Schedule.Count) { $out += $Schedule[$i] } else { $out += $Schedule[$Schedule.Count - 1] }
    }

    return ,([int[]]$out)
}

function Format-InstallSchedule
{
    # @brief The readable form of a schedule: "auto, 4, 1". Zero prints as 'auto' because that is what it means.
    param ([int[]]$Schedule)

    return ((@($Schedule) | ForEach-Object { if ($_ -le 0) { 'auto' } else { [string]$_ } }) -join ', ')
}

function ConvertTo-ManifestName
{
    # @brief Turn the dev environment name into a valid vcpkg manifest name
    #        (lowercase, alphanumeric and hyphens only).
    param ([string]$Name)

    $slug = ([string]$Name).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { $slug = "devsystem" }
    return "$slug-env"
}

# CONFIGURATION
# --------------------------------------------------------------------

# A relative -ConfigFile resolves against config/, never the caller's working directory.
$ConfigPath = if ([System.IO.Path]::IsPathRooted($ConfigFile))
{
    $ConfigFile
}
else
{
    Join-Path (Join-Path (Split-Path -Parent (Get-ScriptDirectory)) "config") $ConfigFile
}

if (-not (Test-Path $ConfigPath))
{
    Write-Error "Configuration file missing: $ConfigPath"
    Abort-WithError
}

try
{
    $Cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch
{
    Write-Error "Invalid JSON in $ConfigPath"
    Abort-WithError
}

# Validate the whole configuration before anything reads a value out of it. An unknown key is an ERROR here rather
# than a silent fall-back to a default; the head of DrivEnvConfig.ps1 explains why that distinction earns a file.
. (Join-Path $PSScriptRoot "DrivEnvConfig.ps1")
. (Join-Path $PSScriptRoot "DrivEnvLogs.ps1")
Enable-DrivEnvGitTrust   # the drive's repositories may belong to another account (an imported drive)

$cfgProblems = @(Test-DrivEnvConfig -Config $Cfg)
if ($cfgProblems.Count -gt 0)
{
    Write-Error ("Configuration has {0} problem(s): {1}" -f $cfgProblems.Count, $ConfigPath)
    foreach ($cfgProblem in $cfgProblems) { Write-Error "    $cfgProblem" }
    Abort-WithError
}

Write-Info "Configuration validated against the schema: no problems."
$metaLine = Get-DrivEnvMetadataSummary -Cfg $Cfg; if ($metaLine) { Write-Info $metaLine }

# --------------------------------------------------------------------
# TOOLCHAIN PROJECTION
# --------------------------------------------------------------------
# From here $Cfg holds ONE toolchain: msys2.target.subsystem and vcpkg.target.triplet are plain scalars.
# Runs after Test-DrivEnvConfig, which has already checked the ids and every projection.

$generated = Get-DrivEnvGenerateList -Cfg $Cfg

# The configuration as read, kept for what the build trees share with every other toolchain of the drive: their
# triplets, for STEP 7's cleanup. Read-only.
$CfgFull = $Cfg

if ([string]::IsNullOrWhiteSpace($Toolchain))
{
    # A dual configuration run without -Toolchain would silently build whichever toolchain the unprojected
    # file happens to resemble, and there is no good candidate: the shared section has no subsystem and no
    # triplet at all. Refusing is the only honest answer.
    if ($generated.Count -gt 0)
    {
        Write-Error ("This configuration generates {0} toolchain(s) -- {1} -- so -Toolchain must say which one." -f $generated.Count, ($generated -join ", "))
        Write-Error "    Run it through Generate-DrivEnv.ps1, which loops the steps over them, or name one here."
        Abort-WithError
    }
}
else
{
    if ($generated.Count -eq 0)
    {
        Write-Error ("-Toolchain '{0}' was given, but this configuration declares no 'toolchains'." -f $Toolchain)
        Abort-WithError
    }

    if ($generated -notcontains $Toolchain)
    {
        Write-Error ("-Toolchain '{0}' is not generated by this configuration. It generates: {1}" -f $Toolchain, ($generated -join ", "))
        Abort-WithError
    }

    $Cfg = Resolve-DrivEnvToolchain -Cfg $Cfg -Id $Toolchain
    Write-Info ("Toolchain '{0}': subsystem '{1}', triplet '{2}'." -f $Toolchain, $Cfg.msys2.target.subsystem, $Cfg.vcpkg.target.triplet)
}

# For the cleanup in STEP 7 (one buildtrees root for the drive): this run's triplets (comma-returned, not wrapped) and
# whether this is the last generated toolchain, which may also remove the shared sources.
$ownTriplets     = Get-DrivEnvToolchainTriplets -Cfg $Cfg
# -eq, not -ceq: the id was accepted above by -notcontains, which ignores case, so it is compared the same way here.
$isLastToolchain = ($generated.Count -eq 0) -or ($Toolchain -eq $generated[$generated.Count - 1])

# This toolchain's files, from the one table every step names them with. Step 2 wrote the env file under this name.
$names = Get-DrivEnvToolchainNames -Cfg $Cfg
if ($null -eq $names)
{
    Write-Error "Cannot name this toolchain's files: environment.dev_drive_letter, environment.dev_env_name or the toolchain key is blank."
    Abort-WithError
}

# Every OTHER declared toolchain's main triplet. A port that all of them have stamped already is one nobody needs the
# sources of any more, whichever order the toolchains were built in: see Get-DrivEnvBuildtreeCleanupPlan.
$otherTriplets = @()
foreach ($t in (Get-DrivEnvDeclaredTargets -Cfg $CfgFull))
{
    if (($t.Key -ine $names.Key) -and -not [string]::IsNullOrWhiteSpace($t.Triplet)) { $otherTriplets += $t.Triplet }
}

# The one variable every read of the env file below goes through, assigned once, here, and printed under -ValidateOnly
# AS IT IS -- so what the tests see is what the step opens.
$envFilePath = $names.EnvFile

if ($ValidateOnly)
{
    Write-Info ("Env file for this toolchain: {0}" -f $envFilePath)
    Write-Info ("Build-tree cleanup: own triplets {0}; other toolchains' {1}; last in 'generate': {2}" -f
                (@($ownTriplets) -join ', '), $(if ($otherTriplets.Count) { $otherTriplets -join ', ' } else { '(none)' }), $isLastToolchain)
    Write-Info "-ValidateOnly was given, so nothing further will run."
    exit 0
}
if (-not $Cfg.environment)  { Write-Error "Missing 'environment' object in config JSON: $ConfigPath"; Abort-WithError }
if (-not $Cfg.vcpkg)        { Write-Error "Missing 'vcpkg' object in config JSON: $ConfigPath";       Abort-WithError }
if (-not $Cfg.vcpkg.target) { Write-Error "Missing 'vcpkg.target' object in config JSON: $ConfigPath";Abort-WithError }

if (-not $Cfg.vcpkg.packages)
{
    Write-Error "Missing 'vcpkg.packages' array in config JSON: $ConfigPath"
    Write-Error "Add at least one entry, for example: { `"name`": `"fmt`" }"
    Abort-WithError
}

# Environment section
$driveLetter = [string]$Cfg.environment.dev_drive_letter
$devEnvName  = [string]$Cfg.environment.dev_env_name

if ([string]::IsNullOrWhiteSpace($driveLetter)) { Write-Error "Missing environment.dev_drive_letter"; Abort-WithError }
if ([string]::IsNullOrWhiteSpace($devEnvName))  { Write-Error "Missing environment.dev_env_name";     Abort-WithError }

$driveLetter = $driveLetter.Trim().TrimEnd(':').ToUpperInvariant()
if ($driveLetter -notmatch '^[A-Z]$')
{
    Write-Error "Invalid environment.dev_drive_letter (expected a single letter): $driveLetter"
    Abort-WithError
}

$devDrive = "{0}:\" -f $driveLetter

# VCPKG target section
$vcpkgTriplet = [string]$Cfg.vcpkg.target.triplet
if ([string]::IsNullOrWhiteSpace($vcpkgTriplet))
{
    Write-Error "Missing vcpkg.target.triplet in config JSON: $ConfigPath"
    Abort-WithError
}

$vcpkgTriplet = $vcpkgTriplet.Trim()
if ($vcpkgTriplet -notmatch '^[A-Za-z0-9._-]+$')
{
    Write-Error ("Invalid vcpkg.target.triplet: '{0}'" -f $vcpkgTriplet)
    Abort-WithError
}

# VCPKG packages section
$vcpkgPackages = @($Cfg.vcpkg.packages)

if ($vcpkgPackages.Count -eq 0)
{
    Write-Error "'vcpkg.packages' is empty in config JSON: $ConfigPath"
    Abort-WithError
}

$portSpecs = @()
$portNames = @()

foreach ($p in $vcpkgPackages)
{
    $pName = [string]$p.name

    if ([string]::IsNullOrWhiteSpace($pName))
    {
        Write-Error "Invalid vcpkg.packages entry: missing 'name'"
        Abort-WithError
    }

    $pName = $pName.Trim()
    if ($pName -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$')
    {
        Write-Error ("Invalid vcpkg port name '{0}' (expected lowercase letters, digits, '.' and '-')" -f $pName)
        Abort-WithError
    }

    if ($portNames -contains $pName)
    {
        Write-Error ("Duplicated vcpkg port in configuration: '{0}'" -f $pName)
        Abort-WithError
    }

    $pFeatures = @()
    if ($p.PSObject.Properties.Name -contains "features")
    {
        foreach ($f in @($p.features))
        {
            $fName = ([string]$f).Trim()
            if ([string]::IsNullOrWhiteSpace($fName))
            {
                Write-Error ("Invalid empty feature in vcpkg.packages entry '{0}'" -f $pName)
                Abort-WithError
            }
            if ($fName -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$')
            {
                Write-Error ("Invalid feature name '{0}' in vcpkg.packages entry '{1}'" -f $fName, $pName)
                Abort-WithError
            }
            $pFeatures += $fName
        }
    }

    if ($pFeatures.Count -gt 0) { $spec = "{0}[{1}]" -f $pName, ($pFeatures -join ",") }
    else                        { $spec = $pName }

    # Optional per-package triplet; absent means vcpkg.target.triplet (no separate default key to drift).
    $pTriplet = $vcpkgTriplet
    if ($p.PSObject.Properties.Name -contains "triplet")
    {
        $pTriplet = ([string]$p.triplet).Trim()
        if ([string]::IsNullOrWhiteSpace($pTriplet))
        {
            Write-Error ("Empty vcpkg.packages[].triplet for '{0}'." -f $pName)
            Write-Error "Omit the field entirely to use the configured triplet."
            Abort-WithError
        }
    }

    $portNames += $pName
    # Optional per-port overrides, resolved at install time. $null/0 mean "not given"; tests are explicit because a
    # one-attempt schedule @(0) is falsy in PowerShell.
    $pSchedule = $null
    if ($p.PSObject.Properties.Name -contains "install_schedule")
    {
        $pSchedule = ConvertTo-InstallSchedule -Entries $p.install_schedule
        if ($pSchedule.Count -eq 0) { $pSchedule = $null }
    }

    $pAttempts = 0
    if ($p.PSObject.Properties.Name -contains "max_install_attempts") { $pAttempts = [int]$p.max_install_attempts }

    $portSpecs += @{ Name = $pName; Features = $pFeatures; Spec = $spec; Triplet = $pTriplet
                     Schedule = $pSchedule; Attempts = $pAttempts }
}

# Dev drive layout (must match the layout written by 3-Clone_VCPKG.ps1)
$vcpkgRootWin       = Join-Path $devDrive "vcpkg"
$overlayPortsWin    = Join-Path $devDrive "overlays\ports"
$overlayTripletsWin = Join-Path $devDrive "overlays\triplets"
$binaryCacheWin     = Join-Path $devDrive "packages\vcpkg"
$vcpkgExeWin        = Join-Path $vcpkgRootWin "vcpkg.exe"

$manifestPath = $names.VcpkgReference

# INITIAL PREPARATION
# --------------------------------------------------------------------

$scriptStart = Get-Date
$scriptDir   = Get-ScriptDirectory
# The steps live in scripts/. Everything they read out of the generator or write back into it -- the
# configuration, the overlay ports and triplets, the MSYS2 package cache, the launcher templates and these
# logs -- sits one level up beside that directory, so it is all named from the root and not from here.
$drivEnvRoot = Split-Path -Parent $scriptDir

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir = Join-Path $drivEnvRoot "logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile = Join-Path $logsDir (Get-DrivEnvLogName -Timestamp $timestamp -Role "vcpkg-deps-setup" -Key $names.Key)
$globalLogFileUnix = Convert-ToMSYSPath $globalLogFile

$originalTitle = $host.UI.RawUI.WindowTitle
$host.UI.RawUI.WindowTitle = "GENERIC VCPKG DEPS SETUP SCRIPT"

# SCRIPT STARTUP HEADER
# --------------------------------------------------------------------

Write-NoFormat "================================================================="
Write-NoFormat "  VCPKG DEPENDENCIES SETUP SCRIPT"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "  Authors: Angel Vera Herrera"
Write-NoFormat "           David Abuin Sanchez"
Write-NoFormat "  Updated: 27/10/2026"
Write-NoFormat "  Version: 3.0.0"
Write-NoFormat "================================================================="
Write-NoFormat "Parameters (Loaded from JSON):"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "Drive Letter  = $devDrive"
Write-NoFormat "Dev Env Name  = $devEnvName"
Write-NoFormat "Env File      = $envFilePath"
Write-NoFormat "VCPKG Root    = $vcpkgRootWin"
Write-NoFormat "VCPKG Triplet = $vcpkgTriplet"
Write-NoFormat "Install Mode  = classic"
Write-NoFormat "Ports         = $($portSpecs.Count)"
Write-NoFormat "-----------------------------------------------------------------"
foreach ($port in $portSpecs)
{
    if ($port.Triplet -eq $vcpkgTriplet) { Write-NoFormat ("  - " + $port.Spec) }
    else                                 { Write-NoFormat ("  - {0}   [triplet {1}]" -f $port.Spec, $port.Triplet) }
}
Write-NoFormat "================================================================="

# STEP 1: Initial checks and preparations.
# --------------------------------------------------------------------

Write-Info "STEP 1: Initial checks and preparations."

# Armed before anything long-running starts, so a Ctrl-C during the very first port is handled the same way
# as one during the last. See Enable-CancelHandling for what it takes over and why.
Enable-CancelHandling

Write-Info "Checking permissions..."
# No elevation needed: this step only writes to the drive and TEMP. Running elevated is worse than unnecessary: every
# directory vcpkg creates would be owned by BUILTIN\Administrators instead of the user.
if (Test-IsAdministrator)
{
    Write-Warn "Running elevated. Nothing in this step needs it, and what it creates belongs to Administrators until"
    Write-Warn "Generate-DrivEnv.ps1, run elevated, hands the drive to environment.owner at its end. Run alone, start it"
    Write-Warn "from an ordinary terminal, as Generate-DrivEnv.ps1 itself can be (step 1 asks for elevation by itself)."
}

Write-Info "Checking if Dev Drive exists..."
try
{
    $volume = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    Write-Info "Dev Drive detected at $devDrive"
}
catch
{
    Write-Error "Dev Drive '$devDrive' is not available or not mounted. Run 1-Setup_DevDrive.ps1 first."
    Abort-WithError
}

Write-Info "Reading environment file produced by the previous steps..."
if (-not (Test-Path -LiteralPath $envFilePath))
{
    Write-Error "Environment file not found: $envFilePath"
    Write-Error "Run steps 1 to 3 for this toolchain before this script."
    $legacy = Get-DrivEnvLegacyEnvFile -Cfg $Cfg
    if ($legacy -and (Test-Path -LiteralPath $legacy))
    {
        Write-Error "This drive has $legacy, the single env file of a drive generated before 3.0.0 named one per toolchain."
    }
    Abort-WithError
}

$envMap = Read-EnvFile $envFilePath

# THE FILE IS THIS TOOLCHAIN'S, by its contents as well as by its name: see Get-DrivEnvEnvFileProblem. Building one
# toolchain's ports under the other's compiler would succeed, and be found out only at link time.
$identity = Get-DrivEnvEnvFileProblem -EnvMap $envMap -Key $names.Key -Path $envFilePath
if ($identity)
{
    Write-Error $identity
    Abort-WithError
}

$msys2Root = [string]$envMap["MSYS2_ROOT"]
$msys2Bash = [string]$envMap["MSYS2_BASH"]
$msys2Env  = [string]$envMap["MSYS2_ENV"]
$toolchainRoot = Get-DrivEnvToolchainRoot -EnvMap $envMap -Msys2Root $msys2Root -Msys2Env $msys2Env `
                                          -Warn { param($m) Write-Warn $m }

if ([string]::IsNullOrWhiteSpace($msys2Root) -or [string]::IsNullOrWhiteSpace($msys2Bash) -or [string]::IsNullOrWhiteSpace($msys2Env))
{
    Write-Error "The environment file does not describe a complete MSYS2 installation: $envFilePath"
    Write-Error "Expected MSYS2_ROOT, MSYS2_BASH and MSYS2_ENV. Re-run 2-Setup_MSYS2.ps1."
    Abort-WithError
}

$msys2RootWin = Convert-ToWinPath $msys2Root
$msys2BashWin = Convert-ToWinPath $msys2Bash

Write-Info "MSYS2_ROOT = $msys2RootWin"
Write-Info "MSYS2_ENV  = $msys2Env"

if (-not (Test-Path -LiteralPath $msys2BashWin))
{
    Write-Error "Bash not found at expected MSYS2 path: $msys2BashWin"
    Write-Error "Run 2-Setup_MSYS2.ps1 before this script."
    Abort-WithError
}

# The clone step must have run: it is what creates the repository, the overlays and the
# VCPKG_* entries in the environment file.
Write-Info "Checking the vcpkg clone step..."

if (-not (Test-Path -LiteralPath (Join-Path $vcpkgRootWin ".git")))
{
    Write-Error "No vcpkg repository found at: $vcpkgRootWin"
    Write-Error "Run 3-Clone_VCPKG.ps1 before this script."
    Abort-WithError
}

$envTriplet = [string]$envMap["VCPKG_DEFAULT_TRIPLET"]
if ([string]::IsNullOrWhiteSpace($envTriplet))
{
    Write-Error "VCPKG_DEFAULT_TRIPLET is missing from: $envFilePath"
    Write-Error "Run 3-Clone_VCPKG.ps1 before this script."
    Abort-WithError
}

if ($envTriplet -ne $vcpkgTriplet)
{
    Write-Error "Triplet mismatch between the configuration and the generated environment."
    Write-Error "  Configuration (vcpkg.target.triplet) : $vcpkgTriplet"
    Write-Error "  Environment   (VCPKG_DEFAULT_TRIPLET): $envTriplet"
    Write-Error "Re-run 3-Clone_VCPKG.ps1 to apply the configured triplet."
    Abort-WithError
}

$tripletFileWin = Join-Path $overlayTripletsWin ("{0}.cmake" -f $vcpkgTriplet)
if (-not (Test-Path -LiteralPath $tripletFileWin))
{
    Write-Error "Overlay triplet not installed: $tripletFileWin"
    Write-Error "Run 3-Clone_VCPKG.ps1 before this script."
    Abort-WithError
}

if (-not (Test-Path -LiteralPath $overlayPortsWin))
{
    Write-Error "Overlay ports directory not installed: $overlayPortsWin"
    Write-Error "Run 3-Clone_VCPKG.ps1 before this script."
    Abort-WithError
}

if (-not (Test-Path -LiteralPath $binaryCacheWin))
{
    New-Item -ItemType Directory -Path $binaryCacheWin -Force | Out-Null
    Write-Info "Created vcpkg binary cache directory: $binaryCacheWin"
}

Write-Info "STEP 1: OK"

# STEP 2: Ensure the vcpkg executable is available.
# --------------------------------------------------------------------

Write-Info "STEP 2: Ensure the vcpkg executable is available."

if (Test-Path -LiteralPath $vcpkgExeWin)
{
    Write-Info "vcpkg.exe found at: $vcpkgExeWin"
}
else
{
    Write-Warn "vcpkg.exe not found at '$vcpkgExeWin'. Bootstrapping the existing clone..."

    # bootstrap-vcpkg.bat calls powershell.exe by name, and a .bat finds it only through PATH. This shell's
    # PATH is not something the script can assume anything about. Same reasoning, and the same helper, as the
    # bootstrap in step 3; see Add-DrivEnvWindowsSystemPath.
    [void](Add-DrivEnvWindowsSystemPath -Report { param($m) Write-Info $m })

    $bootstrapBat = Join-Path $vcpkgRootWin "bootstrap-vcpkg.bat"
    if (-not (Test-Path -LiteralPath $bootstrapBat))
    {
        Write-Error "Bootstrap script not found: $bootstrapBat"
        Write-Error "The vcpkg clone looks incomplete. Re-run 3-Clone_VCPKG.ps1."
        Abort-WithError
    }

    Push-Location -LiteralPath $vcpkgRootWin
    try
    {
        & $bootstrapBat "-disableMetrics" 2>&1 | ForEach-Object { Write-NoFormat ("    | " + $_) }
        $code = $LASTEXITCODE
    }
    finally
    {
        Pop-Location
    }

    if ($code -ne 0)
    {
        Write-Error "vcpkg bootstrap process failed (ExitCode=$code)."
        Abort-WithError
    }

    if (-not (Test-Path -LiteralPath $vcpkgExeWin))
    {
        Write-Error "vcpkg.exe was not found after bootstrapping: $vcpkgExeWin"
        Abort-WithError
    }

    Write-Info "Bootstrap completed. vcpkg.exe located at: $vcpkgExeWin"
}

Write-Info "STEP 2: OK"

# STEP 3: Install the configured ports.
# --------------------------------------------------------------------

# Interrupting is safe: Ctrl-C reaches bash and vcpkg (same process group); vcpkg commits a port only once it is
# built, so only the port in progress is lost and a re-run resumes. The vcpkg-running.lock files are released by the
# OS when the process dies.
Write-Info "STEP 3: Install the configured ports with triplet '$vcpkgTriplet'."

$vcpkgRootDrive       = Convert-ToDriveStylePath $vcpkgRootWin
$vcpkgRootUnix        = Convert-ToMSYSPath       $vcpkgRootWin
$overlayPortsDrive    = Convert-ToDriveStylePath $overlayPortsWin
$overlayTripletsDrive = Convert-ToDriveStylePath $overlayTripletsWin
$binaryCacheDrive     = Convert-ToDriveStylePath $binaryCacheWin

$scriptHeader = New-Msys2ScriptHeader -Msys2Env        $msys2Env `
                                      -VcpkgRootDrive  $vcpkgRootDrive `
                                      -VcpkgRootUnix   $vcpkgRootUnix `
                                      -Triplet         $vcpkgTriplet `
                                      -OverlayPorts    $overlayPortsDrive `
                                      -OverlayTriplets $overlayTripletsDrive `
                                      -BinaryCache     $binaryCacheDrive


# Ports that failed once and then installed unchanged. Reported at the end rather than only in passing, because
# it is the one number that says something about the machine rather than about the configuration.
$retriedPorts = @()

# Default install schedule: first attempt at vcpkg's own concurrency, then serialised retries (4 attempts; one
# machine needed several for qtshadertools). Configurable, since it is a property of the machine.
$DEFAULT_ATTEMPTS = 4
$installSchedule  = @(0) + (1..($DEFAULT_ATTEMPTS - 1) | ForEach-Object { 1 })
$installSchedule  = [int[]]$installSchedule

if ($Cfg.vcpkg.PSObject.Properties.Name -contains "install_schedule")
{
    $configuredSchedule = ConvertTo-InstallSchedule -Entries $Cfg.vcpkg.install_schedule
    if ($configuredSchedule.Count -ge 1)
    {
        $installSchedule = $configuredSchedule
        Write-Info ("Install schedule from the configuration: {0}." -f (Format-InstallSchedule $installSchedule))
    }
}

# max_install_attempts still works, and now means the LENGTH of the schedule. Applied on top, so the two keys
# compose instead of competing: the schedule says the shape, this says how many attempts of it to run.
if ($Cfg.vcpkg.PSObject.Properties.Name -contains "max_install_attempts")
{
    $configured = [int]$Cfg.vcpkg.max_install_attempts
    if ($configured -ge 1 -and $configured -ne $installSchedule.Count)
    {
        $installSchedule = Resize-InstallSchedule -Schedule $installSchedule -Count $configured
        Write-Info ("Port install attempts set to {0} by the configuration: {1}." -f
                    $configured, (Format-InstallSchedule $installSchedule))
    }
}

# Off unless asked for, which is what this generator has always done.
$retryDelaySeconds = 0
if ($Cfg.vcpkg.PSObject.Properties.Name -contains "retry_delay_seconds")
{
    $retryDelaySeconds = [int]$Cfg.vcpkg.retry_delay_seconds
}
if ($retryDelaySeconds -gt 0)
{
    Write-Info ("Retry delay: {0} s times the attempt number, so {1}." -f $retryDelaySeconds,
                (((1..($installSchedule.Count)) | ForEach-Object { "{0} s" -f ($retryDelaySeconds * ($_ - 1)) }) -join ', '))
}

# A short buildtrees root (default <drive>:/bt, shared resolver with step 1): Qt's autogen paths under
# <root>/<port>/<triplet>-rel hit the 260-character limit of MSYS2's GCC, which has no long-path manifest.
$buildtreesRoot = (Resolve-DrivEnvBuildtreesRoot -Cfg $Cfg -DriveLetter $driveLetter `
                                                 -Warn { param($m) Write-Warn $m }).Posix
Write-Info "Buildtrees root: $buildtreesRoot"

$index = 0
$cancelledRun = $false
foreach ($port in $portSpecs)
{
    $index++

    # A cancelled run stops entering ports, but does NOT jump out of the script: the remaining steps write
    # the summary, preserve the logs and restore the console, and those are worth more after an interrupted
    # run than after a clean one.
    if (Test-CancelRequested)
    {
        $cancelledRun = $true
        Write-Warn ("Cancelled: skipping '{0}' and the {1} port(s) after it." -f
                    $port.Spec, ($portSpecs.Count - $index))
        break
    }
    if ($port.Triplet -eq $vcpkgTriplet)
    {
        Write-Info ("Installing port {0}/{1}: '{2}'..." -f $index, $portSpecs.Count, $port.Spec)
    }
    else
    {
        Write-Info ("Installing port {0}/{1}: '{2}' for triplet '{3}'..." -f
                    $index, $portSpecs.Count, $port.Spec, $port.Triplet)
    }

    # Retries with lower concurrency: the failures absorbed are resource- or concurrency-shaped (openssl's Makefile
    # rename race, a GCC segfault, a meson access violation). Safe because vcpkg works per package. Every retry is
    # logged and named in the summary: a machine that needs them should be noticed.
    $code = 1

    # This port's schedule: the global one unless the port sets install_schedule or max_install_attempts (heavy ports
    # want low concurrency from the first attempt).
    $portSchedule = $installSchedule
    if ($null -ne $port.Schedule -and $port.Schedule.Count -ge 1)
    {
        $portSchedule = [int[]]$port.Schedule
    }
    if ($port.Attempts -ge 1 -and $port.Attempts -ne $portSchedule.Count)
    {
        $portSchedule = Resize-InstallSchedule -Schedule $portSchedule -Count $port.Attempts
    }

    if (($portSchedule -join ',') -ne ($installSchedule -join ','))
    {
        Write-Info ("'{0}' has its own schedule: {1}." -f $port.Spec, (Format-InstallSchedule $portSchedule))
    }

    $portAttempts = $portSchedule.Count

    # THIS PORT'S OVERLAY LAYERS, from its own triplet. Passed on the command line rather than left to the
    # VCPKG_OVERLAY_PORTS the header exports: the flag overrides the variable, it is repeatable, and it puts the
    # search order in the logged command where it can be read afterwards.
    $portLayers = Resolve-OverlayLayers -OverlayConfig $Cfg.vcpkg.overlay_ports -Triplet $port.Triplet
    $overlayFlags = ""
    foreach ($layerName in $portLayers)
    {
        # Drive style with forward slashes, which is the form vcpkg.exe wants -- the same form
        # Convert-ToDriveStylePath produces for the header's VCPKG_OVERLAY_PORTS.
        $overlayFlags += " --overlay-ports='{0}:/overlays/{1}'" -f $driveLetter, $layerName
    }

    if ($portLayers.Count -gt 1 -or $portLayers[0] -ne "ports")
    {
        Write-Info ("'{0}' overlay layers: {1}" -f $port.Spec, ($portLayers -join ' then '))
    }

    for ($attempt = 1; $attempt -le $portAttempts; $attempt++)
    {
        # Retrying a port the user just interrupted would be the opposite of what they asked for.
        if (Test-CancelRequested) { $cancelledRun = $true; break }

        $concurrency = $portSchedule[$attempt - 1]

        if ($attempt -gt 1)
        {
            # Growing pause, off unless retry_delay_seconds is set: for failures concurrency cannot fix, such as a proxy
            # serving a cached 504 for minutes.
            $waitSeconds = $retryDelaySeconds * ($attempt - 1)

            if ($waitSeconds -gt 0)
            {
                Write-Warn ("Waiting {0} s before attempt {1} (vcpkg.retry_delay_seconds = {2})." -f
                            $waitSeconds, $attempt, $retryDelaySeconds)

                # SLICED, NOT ONE LONG SLEEP. A single Start-Sleep would make Ctrl-C unresponsive for the whole
                # wait, which on the last attempt of a long schedule is minutes of a run that looks hung.
                for ($waited = 0; $waited -lt $waitSeconds; $waited++)
                {
                    if (Test-CancelRequested) { break }
                    Start-Sleep -Seconds 1
                }

                if (Test-CancelRequested) { $cancelledRun = $true; break }
            }

            Write-Warn ("Retrying '{0}', attempt {1} of {2}, at concurrency {3}." -f
                        $port.Spec, $attempt, $portAttempts, (Format-InstallSchedule $concurrency))
        }

        # VCPKG_MAX_CONCURRENCY reaches make and ninja. 0 exports nothing: unset is vcpkg's own sizing.
        $concurrencyLine = ""
        if ($concurrency -ge 1) { $concurrencyLine = "export VCPKG_MAX_CONCURRENCY=$concurrency" }

        $installScript = $scriptHeader + @"

$concurrencyLine
./vcpkg install '$($port.Spec)' --triplet '$($port.Triplet)' --host-triplet '$vcpkgTriplet' --x-buildtrees-root='$buildtreesRoot'$overlayFlags
"@

        $tempName = "vcpkg_install_{0}_{1}_{2}.sh" -f $names.Key, ($port.Name -replace '[^A-Za-z0-9]', '_'), $attempt
        # When this attempt began, so the logs saved and quoted below are the ones IT wrote. Two seconds early, so a
        # log written in the attempt's first instant is never lost to how the clock and the file system round.
        $attemptStart = (Get-Date).AddSeconds(-2)
        $code = Invoke-Msys2Script -BashPath $msys2BashWin -ScriptBody $installScript -TempName $tempName

        if ($code -eq 0)
        {
            if ($attempt -gt 1)
            {
                Write-Warn ("'{0}' installed on attempt {1}. The first attempt failed and nothing about the port" -f
                            $port.Spec, $attempt)
                Write-Warn  "changed in between, so treat this as a symptom of the machine and not of the port."
                $retriedPorts += $port.Spec
            }
            break
        }

        # Save this attempt's logs now: vcpkg reuses fixed names, so the next attempt would overwrite them.
        $savedTo = Save-VcpkgFailureLogs -PortName $port.Name -Attempt $attempt `
                                         -BuildtreesRoot $buildtreesRoot -DriveLetter $driveLetter -Since $attemptStart -ToolchainKey $names.Key
        if (-not [string]::IsNullOrWhiteSpace($savedTo)) { Write-Info ("Failure logs kept in {0}" -f $savedTo) }

        if ($attempt -lt $portAttempts)
        {
            Write-Warn ("Installation of '{0}' failed (ExitCode={1})." -f $port.Spec, $code)
        }
    }

    # A cancelled port did not fail to build; it was stopped. Reporting it as a failure and then quoting a
    # non-existent error log would be actively misleading about what happened.
    if (Test-CancelRequested)
    {
        $cancelledRun = $true
        Write-Warn ("'{0}' was interrupted, not failed. Its buildtree is left as it is." -f $port.Spec)
        break
    }

    if ($code -ne 0)
    {
        Write-Error ("Installation of '{0}' failed on all {1} attempts, at concurrency {2} (ExitCode={3})." -f
                     $port.Spec, $portAttempts, (Format-InstallSchedule $portSchedule), $code)

        # Quote the port's own error log here: the cause is there, not in this run's log (an ffmpeg "resource" failure
        # was "make: gcc: No such file or directory"). And name the port that really failed: vcpkg builds the whole
        # dependency tree, and its "error: building <port>:<triplet> failed with:" line, already mirrored into this
        # log, names it (qtbase "failed" when md4c's download did).
        $failedPortName = $port.Name
        if ($globalLogFile -and (Test-Path -LiteralPath $globalLogFile))
        {
            $recent = @(Get-Content -LiteralPath $globalLogFile -Tail 600 -ErrorAction SilentlyContinue)
            for ($i = $recent.Count - 1; $i -ge 0; $i--)
            {
                $m = [regex]::Match([string]$recent[$i], 'error:\s+building\s+([A-Za-z0-9_.+-]+)(?:\[[^\]]*\])?:')
                if ($m.Success) { $failedPortName = $m.Groups[1].Value; break }
            }
        }

        if ($failedPortName -ne $port.Name)
        {
            Write-Error ("The port that actually failed is '{0}', a dependency pulled in by '{1}'." -f
                         $failedPortName, $port.Spec)
        }

        $portLogDir = Convert-ToWinPath ($buildtreesRoot -replace '^/([A-Za-z])/', '$1:/')
        $portLogDir = Join-Path $portLogDir $failedPortName

        if (Test-Path -LiteralPath $portLogDir)
        {
            # Newest first, and only what the LAST attempt wrote. The directory keeps the err logs of every earlier
            # run, and on a dual drive the other triplet's too; "the two newest" quoted one of those whenever this
            # attempt failed before writing two of its own -- an old cause printed under a new failure.
            $allErrLogs = @(Get-ChildItem -LiteralPath $portLogDir -Filter "*-err.log" -ErrorAction SilentlyContinue)
            $errLogs    = @($allErrLogs | Where-Object { $_.LastWriteTime -ge $attemptStart } |
                            Sort-Object LastWriteTime -Descending)

            foreach ($errLog in ($errLogs | Select-Object -First 2))
            {
                $tail = @(Get-Content -LiteralPath $errLog.FullName -Tail 25 -ErrorAction SilentlyContinue |
                          Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($tail.Count -eq 0) { continue }

                Write-Error ("--- tail of {0} ---" -f $errLog.Name)
                foreach ($tailLine in $tail) { Write-NoFormat ("    | " + $tailLine) }
            }

            if ($errLogs.Count -eq 0)
            {
                $older = if ($allErrLogs.Count -gt 0) { " ({0} older ones are from earlier runs or another triplet)" -f $allErrLogs.Count } else { "" }
                Write-Error "The last attempt left no *-err.log$older; look under $portLogDir for its other logs."
            }
        }
        else
        {
            Write-Error "No buildtree found at $portLogDir, so there is no port log to quote."
        }

        Write-Error "If the last attempt ran serialised, a race between parallel jobs is already ruled out."
        Write-Error "If this machine has failed other ports the same way, suspect the machine: lengthen"
        Write-Error "vcpkg.install_schedule or give this port its own, and test the memory when you can."
        Write-Error "See the full build output in: $globalLogFile"
        Abort-WithError
    }

    Write-Info "'$($port.Spec)' installed successfully."
}

if ($cancelledRun)
{
    Write-Warn "STEP 3: CANCELLED by the user."
}
else
{
    Write-Info "STEP 3: OK"
}

# STEP 4: Verify the installed ports.
# --------------------------------------------------------------------

Write-Info "STEP 4: Verify the installed ports."

# --x-json, written to a FILE: the plain listing truncates the name:triplet column, and the captured stream also carries
# the header's "[env] ..." lines, which break JSON parsing.
$listJsonWin  = Join-Path $env:TEMP ("vcpkg_list_{0}.json" -f $names.Key)
$listJsonUnix = Convert-ToMSYSPath $listJsonWin
Remove-Item -LiteralPath $listJsonWin -Force -ErrorAction SilentlyContinue

$listScript = $scriptHeader + @"

./vcpkg list --x-json > '$listJsonUnix'
"@

$listResult = Get-Msys2ScriptOutput -BashPath $msys2BashWin -ScriptBody $listScript -TempName ("vcpkg_list_{0}.sh" -f $names.Key)

if ($listResult.ExitCode -ne 0)
{
    Write-Error "Failed to list the installed vcpkg packages (ExitCode=$($listResult.ExitCode))."
    foreach ($line in $listResult.Output) { Write-Error ("    | " + $line) }
    Abort-WithError
}

if (-not (Test-Path -LiteralPath $listJsonWin))
{
    Write-Error "'vcpkg list --x-json' wrote no output file."
    foreach ($line in $listResult.Output) { Write-Error ("    | " + $line) }
    Abort-WithError
}

# The JSON is keyed by "name:triplet" and each value carries package_name, triplet, version and port_version as
# fields, so nothing has to be recovered from a formatted column.
$installedPorts    = @{}
$installedVersions = @{}

$listJson = $null
$listRaw  = Get-Content -LiteralPath $listJsonWin -Raw -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $listJsonWin -Force -ErrorAction SilentlyContinue

try
{
    $listJson = $listRaw | ConvertFrom-Json
}
catch
{
    # What was actually received is printed. A parse error without its input is a dead end: this exact message,
    # without the text behind it, cost an investigation that the first ten lines would have ended immediately.
    Write-Error "Could not parse the output of 'vcpkg list --x-json': $($_.Exception.Message)"
    Write-Error "What was received instead:"
    $shown = 0
    foreach ($line in ([string]$listRaw -split "`r?`n"))
    {
        if ($shown -ge 10) { Write-Error "    | ... (truncated)"; break }
        Write-Error ("    | " + $line)
        $shown++
    }
    Abort-WithError
}

foreach ($property in $listJson.PSObject.Properties)
{
    $entry = $property.Value
    $name  = [string]$entry.package_name
    if (-not $name) { continue }

    # Keyed by name AND triplet, because a package may be requested for a triplet other than the configured one
    # and "installed" then has to mean "installed for the triplet it was asked for". The field is authoritative, so
    # the "name:triplet" key of the JSON object needs no parsing.
    $entryTriplet = [string]$entry.triplet
    $installedPorts["{0}:{1}" -f $name, $entryTriplet] = $true

    # port_version 0 is the common case and vcpkg does not print "#0" anywhere, so neither does this.
    $version = [string]$entry.version
    if ($entry.PSObject.Properties.Name -contains "port_version")
    {
        $portVersion = [int]$entry.port_version
        if ($portVersion -gt 0) { $version = "{0}#{1}" -f $version, $portVersion }
    }
    if ($version) { $installedVersions["{0}:{1}" -f $name, $entryTriplet] = $version }
}

if ($installedPorts.Count -eq 0)
{
    Write-Error "'vcpkg list --x-json' reported no packages at all."
    Abort-WithError
}

$missing = @()
foreach ($port in $portSpecs)
{
    $key = "{0}:{1}" -f $port.Name, $port.Triplet

    if ($installedPorts.ContainsKey($key))
    {
        if ($installedVersions.ContainsKey($key)) { $version = $installedVersions[$key] }
        else                                      { $version = "(unknown)" }

        if ($port.Triplet -eq $vcpkgTriplet)
        {
            Write-Info ("Installed: {0} version {1}" -f $port.Name, $version)
        }
        else
        {
            Write-Info ("Installed: {0} version {1}  [triplet {2}]" -f $port.Name, $version, $port.Triplet)
        }
    }
    else
    {
        $missing += ("{0} ({1})" -f $port.Name, $port.Triplet)
    }
}

if ($missing.Count -gt 0)
{
    Write-Error ("The following configured ports are not installed: {0}" -f ($missing -join ", "))
    Write-Error "The installation is incomplete."
    Abort-WithError
}

$extraTripletCount = @($portSpecs | Where-Object { $_.Triplet -ne $vcpkgTriplet }).Count
if ($extraTripletCount -eq 0)
{
    Write-Info ("All {0} configured port(s) are installed for triplet '{1}'." -f $portSpecs.Count, $vcpkgTriplet)
}
else
{
    Write-Info ("All {0} configured port(s) are installed: {1} for '{2}' and {3} for another triplet." -f
                $portSpecs.Count, ($portSpecs.Count - $extraTripletCount), $vcpkgTriplet, $extraTripletCount)
}

Write-Info "STEP 4: OK"

# STEP 5: Emit the reference manifest.
# --------------------------------------------------------------------

# Skipped after a cancellation, so an interrupted run does not overwrite the record of the last complete one.
if ($cancelledRun)
{
    Write-Warn "STEP 5 and STEP 6 skipped: the run was cancelled, so the manifest and the inventory are"
    Write-Warn "left as the last complete run wrote them rather than overwritten with a partial state."
}
else
{

Write-Info "STEP 5: Emit the reference manifest."

# Not used by classic mode. It records the same dependency set in vcpkg manifest form so the
# environment can be moved to manifest mode later without re-authoring the configuration.

$dependencies = @()
foreach ($port in $portSpecs)
{
    if ($port.Features.Count -gt 0)
    {
        $dependencies += [PSCustomObject]@{ name = $port.Name; features = @($port.Features) }
    }
    else
    {
        $dependencies += $port.Name
    }
}

$manifest = [ordered]@{
    "name"         = (ConvertTo-ManifestName $names.ManifestName)
    "version-string" = "0.0.0"
    "description"  = ("Reference manifest generated by 4-Deps_VCPKG.ps1 for the {0} environment, toolchain {1}." -f $devEnvName, $names.Key)
    "dependencies" = $dependencies
}

$baselineCommit = [string]$envMap["VCPKG_BASELINE"]
if (-not [string]::IsNullOrWhiteSpace($baselineCommit) -and $baselineCommit -match '^[0-9a-fA-F]{40}$')
{
    $manifest["builtin-baseline"] = $baselineCommit
}
else
{
    Write-Warn "VCPKG_BASELINE is missing or not a full commit id; the manifest will have no 'builtin-baseline'."
}

try
{
    $manifestJson = [PSCustomObject]$manifest | ConvertTo-Json -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)
    Write-Info "Reference manifest written to: $manifestPath"
}
catch
{
    Write-Error "Failed to write the reference manifest '$manifestPath': $_"
    Abort-WithError
}

Write-Info "STEP 5: OK"

# --------------------------------------------------------------------
# STEP 6: Installation inventory
# --------------------------------------------------------------------
# What this environment is, written to <drive>:\installation and generated (a hand-kept list drifts):
#   vcpkg_packages_<key>.txt / .json   ports, versions, features (the JSON for diffing)
#   vcpkg_baseline.txt                 the baseline commit, one per drive
#   msys2_packages_<key>.txt           the MSYS2 side
#   environment_<key>.txt              the generated variables
# Per toolchain, and only this toolchain's contents: one vcpkg tree and one msys64 hold both.

Write-Info "STEP 6: Write the installation inventory."

$inventoryDir = "${driveLetter}:/installation"
if (-not (Test-Path -LiteralPath $inventoryDir))
{
    New-Item -ItemType Directory -Path $inventoryDir -Force | Out-Null
}

$stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

function Write-InventoryFile
{
    # @brief Write one inventory file with a header saying what it is and when it was made.
    param
    (
        [string]$Name,
        [string]$Title,
        [string[]]$Body
    )

    $dest  = Join-Path $inventoryDir $Name
    $lines = @(
        "=======================================================================",
        $Title,
        "=======================================================================",
        "Generated by step 4 on $stamp. Do not hand-edit: a re-run overwrites it.",
        ""
    ) + $Body

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($dest, $lines, $utf8NoBom)
    Write-Info "Wrote $dest"
}

# -- vcpkg packages ----------------------------------------------------
# From the JSON, narrowed to this toolchain's triplets; the text list is built from it too (plain 'vcpkg list' truncates).
$recordVcpkgTxt  = Get-DrivEnvRecordName -Name "vcpkg_packages.txt"  -Key $names.Key
$recordVcpkgJson = Get-DrivEnvRecordName -Name "vcpkg_packages.json" -Key $names.Key
try
{
    $jsonText = & $vcpkgExeWin list --x-json 2>$null
    if ($LASTEXITCODE -eq 0)
    {
        $inventory = ConvertTo-DrivEnvVcpkgInventory -Text ((@($jsonText) | ForEach-Object { [string]$_ }) -join "`n") -Triplets $ownTriplets
        Write-InventoryFile -Name $recordVcpkgTxt -Title ("VCPKG PACKAGES -- toolchain {0}, triplets {1}" -f $names.Key, (@($ownTriplets) -join ", ")) `
                            -Body $inventory.Lines

        $jsonDest  = Join-Path $inventoryDir $recordVcpkgJson
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($jsonDest, $inventory.Json, $utf8NoBom)
        Write-Info "Wrote $jsonDest"
    }
    else
    {
        Write-Warn "vcpkg list failed; $recordVcpkgTxt and $recordVcpkgJson not written."
    }
}
catch
{
    Write-Warn "Could not query vcpkg for the package inventory: $($_.Exception.Message)"
}

# -- baseline ----------------------------------------------------------
# The commit alone is not much use a year later; the subject line says
# what the baseline was, which is what makes it traceable.
try
{
    # The drive's git first (<toolchain root>\bin, then usr\bin), PATH last, so the record does not depend on who ran it.
    $gitSource = $null

    $gitCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($toolchainRoot)) { $gitCandidates += (Join-Path (Convert-ToWinPath $toolchainRoot) "bin\git.exe") }
    if (-not [string]::IsNullOrWhiteSpace($msys2Root)) { $gitCandidates += (Join-Path (Convert-ToWinPath $msys2Root) "usr\bin\git.exe") }

    foreach ($gitCandidate in $gitCandidates)
    {
        if (Test-Path -LiteralPath $gitCandidate) { $gitSource = $gitCandidate; break }
    }

    if (-not $gitSource)
    {
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCmd) { $gitSource = $gitCmd.Source }
    }

    $baseline = $null

    if ($gitSource -and $vcpkgRootWin -and (Test-Path -LiteralPath $vcpkgRootWin))
    {
        $baseline = & $gitSource -C $vcpkgRootWin log -1 `
            --format="%H%nAuthor: %an <%ae>%nDate: %aI%nSubject: %s" 2>&1
        if ($LASTEXITCODE -ne 0) { $baseline = $null }
    }

    if (-not $baseline)
    {
        # No git here, so the commit alone. Still worth recording: without it the package versions cannot be traced
        # back to an upstream state at all.
        $recorded = [string]$envMap["VCPKG_BASELINE"]
        if ($recorded)
        {
            $baseline = @($recorded, "(git was not available to describe this commit)")
        }
    }

    if ($baseline)
    {
        Write-InventoryFile -Name "vcpkg_baseline.txt" -Title "VCPKG BASELINE" -Body $baseline
    }
}
catch
{
    Write-Warn "Could not read the vcpkg baseline: $($_.Exception.Message)"
}

# -- MSYS2 side --------------------------------------------------------
try
{
    if ($msys2Bash -and (Test-Path -LiteralPath $msys2Bash))
    {
        $pac = & $msys2Bash -lc "pacman -Q" 2>&1
        if ($LASTEXITCODE -eq 0)
        {
            # This toolchain's prefix and the shared msys base, not the other compiler's packages. Assigned, not
            # wrapped in @(): Select-DrivEnvToolchainPackages comma-returns.
            $ownPrefix = (Resolve-DrivEnvMsys2Target -Target $Cfg.msys2.target).Prefix
            $ownPac    = Select-DrivEnvToolchainPackages -Lines ([string[]]@($pac)) -Prefix $ownPrefix
            Write-InventoryFile -Name (Get-DrivEnvRecordName -Name "msys2_packages.txt" -Key $names.Key) `
                                -Title ("MSYS2 PACKAGES -- toolchain {0} ({1}-* and the shared msys base)" -f $names.Key, $ownPrefix) -Body $ownPac
        }
    }
}
catch
{
    Write-Warn "Could not query pacman: $($_.Exception.Message)"
}

# -- the generated environment ----------------------------------------
try
{
    if ($envFilePath -and (Test-Path -LiteralPath $envFilePath))
    {
        Write-InventoryFile -Name (Get-DrivEnvRecordName -Name "environment.txt" -Key $names.Key) `
                            -Title ("GENERATED ENVIRONMENT VARIABLES -- toolchain {0}" -f $names.Key) `
            -Body (Get-Content -LiteralPath $envFilePath -Encoding UTF8)
    }
}
catch
{
    Write-Warn "Could not copy the environment file: $($_.Exception.Message)"
}

# -- the configuration it was built from -------------------------------
try
{
    Write-InventoryFile -Name (Get-DrivEnvRecordName -Name "configuration.txt" -Key $names.Key) `
                        -Title ("CONFIGURATION -- toolchain {0}" -f $names.Key) `
                        -Body (@("file: $ConfigPath") + @(Get-DrivEnvMetadataLines -Cfg $Cfg))
}
catch
{
    Write-Warn "Could not write the configuration record: $($_.Exception.Message)"
}

Write-Info "STEP 6: OK"

# STEP 7: Optional cleanup (build trees, package staging, downloads, binary cache).
# --------------------------------------------------------------------
#
# Only reached by a successful, uncancelled run (failures exit through Abort-WithError), after step 4 verified every
# port and step 6's vcpkg list finished. Nothing is removed unless vcpkg.cleanup says so; a summary is always logged.

$cleanup    = Get-DrivEnvCleanupSettings -Cfg $Cfg
$summary    = @()   # one row per category: what went, how much, and what stayed and why
$cleanStart = Get-Date

function Get-TreeBytes { param([string]$Path) return [double](Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum }
function Remove-Tree
{
    # Never fatal: a cleanup that fails after a good build must not fail the run. Returns the bytes freed.
    param([string]$Path, [string]$What)
    try { $b = Get-TreeBytes $Path; Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return $b }
    catch { Write-Warn ("Could not remove {0} '{1}': {2}" -f $What, $Path, $_.Exception.Message); return 0 }
}

Write-Info ("STEP 7: Cleanup (vcpkg.cleanup: buildtrees = {0}, packages = {1}, downloads = {2}, binary_cache = {3})." -f
            $cleanup.Buildtrees, $cleanup.Packages, $cleanup.Downloads, $cleanup.BinaryCache)

# -- build trees ---------------------------------------------------------
if ($cleanup.Buildtrees -eq "none")
{
    $summary += [pscustomobject]@{ Category = "buildtrees"; Removed = 0; Bytes = 0; Note = "kept (buildtrees = none)" }
}
else
{
    $buildtreesWin = Convert-ToWinPath ((Resolve-DrivEnvBuildtreesRoot -Cfg $Cfg -DriveLetter $driveLetter -Warn { param($m) Write-Warn $m }).Windows)
    if (-not (Test-Path -LiteralPath $buildtreesWin))
    {
        $summary += [pscustomobject]@{ Category = "buildtrees"; Removed = 0; Bytes = 0; Note = "root '$buildtreesWin' does not exist" }
    }
    else
    {
        # The selector is the whole safety of this feature: the root also holds the user's own builds
        # (DEVSYSTEM_BUILDTREES). A port directory is recognised by the <triplet>.vcpkg_abi_info.txt vcpkg leaves in it
        # (measured: 89 of 89 ports, 0 of 16 other folders), never by name. Get-DrivEnvBuildtreeCleanupPlan then keeps
        # other toolchains' trees, and the shared src until the last generated toolchain.
        $plans   = @()
        $allDirs = @(Get-ChildItem -LiteralPath $buildtreesWin -Directory -ErrorAction SilentlyContinue)
        foreach ($dir in $allDirs)
        {
            # Named $abiStamps, not $stamp: further up, $stamp is the timestamp written into the records.
            $abiStamps = @(Get-ChildItem -LiteralPath $dir.FullName -Filter "*.vcpkg_abi_info.txt" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            if ($abiStamps.Count -eq 0) { continue }
            $subNames = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            $plan = Get-DrivEnvBuildtreeCleanupPlan -SubdirNames $subNames -FileNames $abiStamps -OwnTriplets $ownTriplets `
                                                    -LastToolchain $isLastToolchain -Mode $cleanup.Buildtrees -OtherTriplets $otherTriplets
            if ($plan.Candidate) { $plans += [pscustomobject]@{ Dir = $dir; Plan = $plan } }
        }

        $freedBytes = 0
        foreach ($entry in $plans)
        {
            # 'logs' removes the source and build trees and keeps the logs in the port folder (for a first-attempt
            # success they exist nowhere else); 'all' removes the folder.
            if ($entry.Plan.RemoveWhole) { $freedBytes += Remove-Tree $entry.Dir.FullName "build tree" }
            else { foreach ($subName in @($entry.Plan.RemoveDirs)) { $freedBytes += Remove-Tree (Join-Path $entry.Dir.FullName $subName) "build tree" } }
        }

        # The root itself is never removed: step 1 creates it, vcpkg locks it, and a later `-From 4` expects it.
        if (-not (Test-Path -LiteralPath $buildtreesWin)) { New-Item -ItemType Directory -Path $buildtreesWin -Force | Out-Null }

        $summary += [pscustomobject]@{ Category = "buildtrees ($($cleanup.Buildtrees))"; Removed = $plans.Count; Bytes = $freedBytes
                                       Note = ("{0} folders kept: user builds, unstamped, or another toolchain's{1}" -f ($allDirs.Count - $plans.Count),
                                               $(if ($isLastToolchain) { "" } else { "; shared sources kept for the next toolchain" })) }
    }
}

# -- vcpkg\packages: staging, hardlinked into installed (removing it frees names, not data) --
if ($cleanup.Packages)
{
    $pkgRoot = Join-Path $vcpkgRootWin "packages"
    $bytes   = 0
    if (Test-Path -LiteralPath $pkgRoot) { $bytes = Remove-Tree $pkgRoot "vcpkg packages" }
    $summary += [pscustomobject]@{ Category = "packages"; Removed = $(if (Test-Path -LiteralPath $pkgRoot) { 0 } else { 1 }); Bytes = $bytes; Note = "$pkgRoot (recreated by vcpkg when it builds)" }
}

# -- shared by every toolchain: removed by the last generated one ---------
foreach ($shared in @(@{ On = $cleanup.Downloads;   Key = "downloads";    Path = (Join-Path $vcpkgRootWin "downloads") },
                      @{ On = $cleanup.BinaryCache; Key = "binary_cache"; Path = $binaryCacheWin }))
{
    if (-not $shared.On) { continue }
    if (-not $isLastToolchain)
    {
        $summary += [pscustomobject]@{ Category = $shared.Key; Removed = 0; Bytes = 0; Note = "kept: shared, cleaned by the last generated toolchain" }
        continue
    }
    $bytes = 0; $count = 0
    if (Test-Path -LiteralPath $shared.Path) { foreach ($item in @(Get-ChildItem -LiteralPath $shared.Path -Force)) { $bytes += Remove-Tree $item.FullName $shared.Key; $count++ } }
    $summary += [pscustomobject]@{ Category = $shared.Key; Removed = $count; Bytes = $bytes; Note = $shared.Path }
}

foreach ($row in $summary) { Write-Info ("  {0,-18} removed {1,4}  {2,10:N1} MB  {3}" -f $row.Category, $row.Removed, ($row.Bytes / 1MB), $row.Note) }
Write-Info ("Reclaimed {0:N1} MB in {1:N0} s." -f ((@($summary | ForEach-Object { $_.Bytes }) | Measure-Object -Sum).Sum / 1MB), ((Get-Date) - $cleanStart).TotalSeconds)
if ($cleanup.BinaryCache -and $isLastToolchain) { Write-Warn "The vcpkg binary cache was emptied: reinstalling a port now means building it again." }
Write-Info "STEP 7: OK"

}   # end of the "not cancelled" block guarding steps 5 and 6

# FINALIZATION
# --------------------------------------------------------------------

$scriptEnd = Get-Date
$elapsed = $scriptEnd - $scriptStart
$elapsedStr = ("{0:hh\:mm\:ss}" -f $elapsed)

# "completed successfully" must not be printed over a run the user stopped. The first version of the
# verification script cheerfully reported OK under thirty-nine failures; the same mistake is available here.
if ($cancelledRun)
{
    Write-Warn "VCPKG dependencies setup was CANCELLED before it finished."
}
else
{
    Write-Info "VCPKG dependencies setup completed successfully."
}
Write-Info "TOTAL EXECUTION TIME: $($elapsed.TotalSeconds) seconds  ($elapsedStr)"

# Named again here rather than left in the scrollback. A port that failed and then installed with nothing about it
# changed is not a fact about the port, and the value of the retry is lost if it silently absorbs the evidence.
if ($retriedPorts.Count -gt 0)
{
    Write-NoFormat ""
    Write-Warn ("{0} port(s) failed once and installed on the retry:" -f $retriedPorts.Count)
    foreach ($p in $retriedPorts) { Write-Warn ("    {0}" -f $p) }
    Write-Warn "Nothing about those ports changed between the attempts, so this says something about the MACHINE."
    Write-Warn "One is bad luck. Several, across unrelated ports, is worth investigating: the causes seen so far are"
    Write-Warn "an on-access virus scanner holding files open, and memory pressure making the compiler crash."
}

# ABOVE the prompt below, not after it: UserInteractive is True even with stdin redirected, and ReadKey then
# throws instead of waiting -- the trap Abort-WithError already documents. Anything after the prompt is
# skipped in precisely the non-interactive case where this copy is the only record anybody will have.
if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }

# The SAME guard as Abort-WithError, and for the same measured reason: UserInteractive is True even with
# stdin redirected, and ReadKey then THROWS instead of waiting. Unguarded, a step that did everything it
# was asked to would die here on its very last statement and report failure to whatever drove it.
if ([Environment]::UserInteractive -and -not [System.Console]::IsInputRedirected) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
}
$host.UI.RawUI.WindowTitle = $originalTitle

# A cancelled run exits non-zero. Anything driving these scripts in sequence has to be able to tell "the
# ports are installed" from "the user stopped me", and the console message alone does not survive a pipe.
if ($cancelledRun) { exit 1223 }

# --------------------------------------------------------------------
