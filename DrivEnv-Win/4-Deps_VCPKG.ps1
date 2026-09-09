# ====================================================================
# VCPKG DEPENDENCIES SETUP SCRIPT
# --------------------------------------------------------------------
# Authors: Angel Vera Herrera
#          David Abuin Sanchez
# Updated: 26/08/2026
# Version: 1.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================
#
# Prerequisites: 1-Setup_DevDrive.ps1, 2-Setup_MSYS2.ps1 and
# 3-Clone_VCPKG.ps1 must have completed.
#
# Installation model: vcpkg CLASSIC mode. Ports are installed once into
# <VCPKG_ROOT>\installed and shared by every project on the dev drive,
# which is what the generated environment (VCPKG_ROOT / VCPKG_BIN on the
# PATH) exposes. A reference manifest is also emitted under <drive>:\env
# so the environment can be migrated to vcpkg manifest mode later without
# re-authoring the configuration.
#
# ====================================================================

# FUNCTIONS
# --------------------------------------------------------------------

param
(
    # @brief Path to the JSON configuration driving this run.
    #
    # A bare file name or a relative path resolves against THIS SCRIPT'S directory, so the common case -- a config
    # sitting beside the scripts -- needs no path at all. An absolute path is taken as given, which is what lets a
    # config live outside the repository. Omit it entirely for the generic configuration.
    #
    # All four scripts take the same switch and must be given the SAME file: they hand state to each other through
    # the generated .env on the dev drive, and mixing configs between steps produces an environment that matches
    # neither.
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief Validate the configuration and stop, changing nothing.
    #
    # The validation runs on every invocation regardless; this switch only stops the script afterwards. Useful for
    # checking an edited configuration in a second, and for checking one BEFORE a step that takes an hour.
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

    # UserInteractive alone is NOT enough. It reports True for any process in a normal user session, including one
    # launched from another script with its input redirected -- and there ReadKey THROWS instead of waiting, so the
    # lines below never run: the window title is left changed and the deliberate `exit 1` becomes an unhandled
    # PowerShell error. Verified on this machine: UserInteractive=True with stdin redirected, ReadKey throws.
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

    foreach ($raw in (Get-Content -LiteralPath $Path))
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
    # @brief Common preamble entering the MSYS2 target environment and exporting the vcpkg
    #        variables in Windows drive form, which is what vcpkg.exe needs.
    #
    # The variables are exported here rather than sourced from the .env file on purpose: the
    # launcher bootstrap converts drive paths to POSIX form when it loads that file, which is
    # right for an interactive shell but wrong for a native Windows binary such as vcpkg.exe.
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

    # NOTE: 'set -e' must NOT be active while the target environment is entered. The MSYS2
    # 'shell' helper (and /etc/profile) return a non-zero status internally, which under
    # 'set -e' aborts the whole script silently, with no output and exit code 1. The
    # environment is therefore validated explicitly instead.
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
# WHY THIS EXISTS. Ctrl-C used to do the worst possible thing here: PowerShell tore down its own pipeline and
# returned the prompt, while bash and everything below it -- vcpkg, cmake, ninja, a dozen compilers -- carried on
# building, invisible, writing into the buildtree and holding the vcpkg lock. The run looked stopped and was not.
#
# A shared object rather than a plain variable, because the handler runs on a different thread than the loop that
# reads it. Setting one boolean property is safe; assigning a script-scope variable across threads is the kind of
# thing that works until it does not.
$script:cancelState = [pscustomobject]@{ Requested = $false }

function Enable-CancelHandling
{
    # @brief Take over Ctrl-C so a cancelled run can stop its own children before it exits.
    #
    # $e.Cancel = $true tells the runtime NOT to terminate us. That is the whole point: the default behaviour
    # kills this script and orphans the build. With the default suppressed, the polling loop in
    # Invoke-Msys2Script sees the request, kills the process tree, and the script exits through its normal
    # reporting path -- summary, preserved logs, restored window title, non-zero exit code.
    #
    # A SECOND Ctrl-C is deliberately left to the runtime: if the tree-kill itself wedges, the user must still
    # be able to get out. So this registers once and does not re-arm.
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
    # @brief Compile the three kernel32 calls needed to kill a build by JOB rather than by parent chain.
    #
    # WHY NOT taskkill /T, WHICH WAS THE FIRST ATTEMPT AND MEASURABLY DOES NOT WORK HERE. taskkill walks the
    # Win32 parent chain. Killing `bash -lc "bash script"` kills the outer bash, the inner bash dies with it,
    # and any grandchild is left holding a parent pid that now refers to a dead process -- so the rest of the
    # walk cannot see it. Tested: a script running `sleep 300 &` plus a foreground `sleep 300` returned 1223 in
    # 3.4 s with TWO sleep processes still running. For a real build that is ninja and a dozen compilers still
    # writing into the buildtree after the run reported itself stopped, which is the exact failure this feature
    # exists to prevent.
    #
    # A job object is tracked by the kernel by MEMBERSHIP. TerminateJobObject kills every process in the job no
    # matter what happened to any parent, and KILL_ON_JOB_CLOSE means that if this script dies outright -- a
    # second Ctrl-C, a closed console window, a crash -- Windows tears the build down as the handle closes.
    # That is strictly better than what the old code could offer even in principle.
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
    # @brief Kill a build: the job object if there is one, and taskkill as a second sweep.
    #
    # BOTH, deliberately. The job object is the reliable mechanism, but a process spawned in the microseconds
    # between Process.Start and AssignProcessToJobObject is outside the job, and taskkill's parent walk is
    # exactly what catches that case. They fail in different directions, so running both is cheaper than
    # choosing.
    #
    # BY PID AND JOB HANDLE, NEVER BY IMAGE NAME. This machine routinely has the user's own compilers running
    # against another drive; a "kill every clang++" would take their work with it.
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
    # @brief Run a bash script inside the MSYS2 login shell, mirroring its output into the log.
    #        Returns the exit code of the script itself, or 1223 if the run was cancelled.
    #
    # HOW THE OUTPUT GETS HERE, and why it is not a pipe. Reading a child's stdout and stderr through pipes from
    # PowerShell means either two synchronous readers -- which deadlock the moment one pipe's buffer fills while
    # we are blocked on the other -- or event handlers that fire on threadpool threads and would need the log
    # writer to be thread-safe. Instead BASH itself merges the two and redirects them into a file, and this
    # function tails that file. Same interleaving the old `2>&1` produced, no pipe to deadlock on, and the poll
    # loop is exactly the place where a cancellation request can be noticed.
    #
    # 1223 is ERROR_CANCELLED. Any non-zero code would do, but a caller that logs the number deserves one that
    # means something.
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

# THE INSTALL-SCHEDULE AND OVERLAY-LAYER HELPERS LIVE UP HERE, WITH THE OTHER FUNCTIONS, AND THAT IS NOT
# TIDINESS. PowerShell executes a script top to bottom, so a function is only callable BELOW its own
# definition. These were first placed next to the install loop that is their main consumer, which left the
# port-parsing loop around line 460 calling ConvertTo-InstallSchedule three hundred lines before it existed:
#     The term 'ConvertTo-InstallSchedule' is not recognized as a name of a cmdlet, function, script file...
# once per package carrying its own schedule. The errors are non-terminating, so the run CONTINUED and those
# packages silently fell back to the global schedule -- a wrong result rather than a stopped script, which is
# the worse of the two outcomes.
function Resolve-OverlayLayers
{
    # @brief The overlay port layers one triplet should search, in order. Returns layer NAMES, not paths.
    #
    # Matched exactly on the triplet, then on "*", then falling back to the single shared layer. The order of
    # the returned list is the search order vcpkg is given, and vcpkg takes the first layer that contains the
    # port -- so a specific layer earlier in the list overrides the shared one later in it.
    #
    # Why this is resolved PER PORT rather than once for the whole run: it is what lets one vcpkg tree hold two
    # triplets with different overlays, which is the shape a dual GCC/clang environment needs. The overlay path
    # is not a property of the tree; it is an argument to each invocation, and step 3 of this script invokes
    # vcpkg once per port.
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
    # @brief Turn a JSON install_schedule array into the list of concurrencies the retry loop uses: entry N is
    #        what attempt N runs with, and 0 means "export nothing and let vcpkg size the build".
    #
    # No validation here on purpose. DrivEnvConfig.ps1 has already checked the shape -- an array of objects whose
    # only key is an optional non-negative int -- and a second copy of that check would only give the two
    # something to disagree about. An entry with no 'concurrency' is 0, which is the documented meaning of {}.
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

# A relative -ConfigFile is relative to the script, not to the caller's working directory: these scripts are
# routinely launched by double-click and from elsewhere, and resolving against the cwd would silently pick a
# different config depending on where the shell happened to be.
$ConfigPath = if ([System.IO.Path]::IsPathRooted($ConfigFile))
{
    $ConfigFile
}
else
{
    Join-Path $PSScriptRoot $ConfigFile
}

if (-not (Test-Path $ConfigPath))
{
    Write-Error "Configuration file missing: $ConfigPath"
    Abort-WithError
}

try
{
    $Cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
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

$cfgProblems = @(Test-DrivEnvConfig -Config $Cfg)
if ($cfgProblems.Count -gt 0)
{
    Write-Error ("Configuration has {0} problem(s): {1}" -f $cfgProblems.Count, $ConfigPath)
    foreach ($cfgProblem in $cfgProblems) { Write-Error "    $cfgProblem" }
    Abort-WithError
}

Write-Info "Configuration validated against the schema: no problems."

if ($ValidateOnly)
{
    Write-Info "-ValidateOnly was given, so nothing further will run."
    if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }
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

    # An OPTIONAL per-package triplet, for the case where one library has to be built differently from the rest.
    # Fast DDS is the reason it exists: its MinGW DLL does not export the vtable of TypeSupport nor the
    # traits<>::make_shared instantiations, so nothing that defines a DDS type can link against a shared build.
    #
    # Omitting the field means the configured triplet. There is deliberately NO separate "default triplet" key:
    # vcpkg.target.triplet already is the default, and two fields meaning the same thing is how they drift apart.
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
    # OPTIONAL per-port overrides, resolved later against the global default rather than here, because the
    # default they override is not read until the install phase.
    #
    # Kept as $null and 0 for "not given". A one-attempt schedule is @(0), and PowerShell collapses a
    # one-element array to the truthiness of its single element, so `if ($pSchedule)` would be FALSE for a
    # perfectly valid schedule. Every test on these two is therefore explicit.
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

$envFilePath  = Join-Path "$driveLetter`:" (("env/{0}_env_variables.env" -f $devEnvName).ToLower())
$manifestPath = Join-Path "$driveLetter`:" (("env/{0}_vcpkg_reference.json" -f $devEnvName).ToLower())

# INITIAL PREPARATION
# --------------------------------------------------------------------

$scriptStart = Get-Date
$scriptDir   = Get-ScriptDirectory

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir = Join-Path $scriptDir "install_logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile = Join-Path $logsDir "${timestamp}_vcpkg-deps-setup.log"
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
Write-NoFormat "  Updated: 19/08/2026"
Write-NoFormat "  Version: 1.0.0"
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
# NO ELEVATION IS REQUIRED HERE, and demanding it was a mistake inherited from step 1. This block used to abort
# unless the shell was already elevated, which sent people to reopen an Administrator terminal for no reason.
#
# This step writes to the dev drive and to the user's TEMP, and nothing else: no services, no registry, no machine
# environment variables, no VHD, no Defender exclusions, no scheduled tasks. Step 1 needs administrator rights
# because it creates and formats a volume; this one needs only a volume that already exists. The drive root carries
# the stock "Authenticated Users: Modify" ACE, inherited by everything on it, so an ordinary user can do all of it.
# Steps 2, 5 and 6 never had the check and have always worked -- step 6 clones repositories onto the same drive
# unelevated.
#
# Running elevated is WORSE than unnecessary: every directory vcpkg creates -- buildtrees, packages, installed,
# downloads -- ends up owned by BUILTIN\Administrators rather than by the person who will build against it.
if (Test-IsAdministrator)
{
    Write-Warn "Running elevated. Nothing in this step needs it, and it leaves the vcpkg tree owned by"
    Write-Warn "Administrators rather than by you. An ordinary terminal is the better choice for steps 2 to 6."
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
    Write-Error "Run steps 1 to 3 before this script."
    Abort-WithError
}

$envMap = Read-EnvFile $envFilePath

$msys2Root = [string]$envMap["MSYS2_ROOT"]
$toolchainRoot = Get-DrivEnvToolchainRoot -EnvMap $envMap -Warn { param($m) Write-Warn $m }
$msys2Bash = [string]$envMap["MSYS2_BASH"]
$msys2Env  = [string]$envMap["MSYS2_ENV"]

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

# INTERRUPTING THIS STEP IS SAFE, and no cancellation machinery is needed to make it so.
#
# Ctrl-C in the console sends CTRL_C_EVENT to the whole process group, and the MSYS2 child is started with
# the call operator in that same group, so bash and vcpkg receive it directly rather than being orphaned.
#
# What it costs is the port being built at that moment and nothing else. vcpkg installs package by package:
# it stages into packages/<port>_<triplet>/ and only then commits into installed/ and writes the status
# record, so an interrupted port is simply not installed. Everything already reported as installed above
# stays installed, and re-running this step resumes from there -- vcpkg does not rebuild what the status
# database already accounts for.
#
# The vcpkg-running.lock files are not a hazard either, which is the part that looks alarming. They are
# zero-byte files that stay on disk permanently and carry an OS-level exclusive lock while vcpkg runs;
# Windows releases that lock when the process dies, however it dies. Verified on a drive whose builds had
# been interrupted repeatedly: all five lock files present, and "vcpkg list" ran and listed 102 packages.
#
# So there is nothing to clean up and nothing to unwind. The only thing an interruption needs is for
# somebody to know that, which is why it is written here rather than implemented.
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

# THE DEFAULT INSTALL SCHEDULE: one entry per attempt, each the build concurrency that attempt runs with, and
# 0 meaning "export nothing and let vcpkg size the build from the hardware".
#
# Configurable because it is a property of the MACHINE and not of the configuration. A machine whose compiler
# segfaults at a different pass on every run needs more attempts; one that only falls over under load needs a
# lower concurrency; neither should mean editing this script.
#
# The built-in default reproduces exactly what this step has always done -- first attempt at vcpkg's own
# concurrency, every attempt after it serialised -- so a configuration written before schedules existed behaves
# identically. Four attempts because one machine here needed five to get qtshadertools through.
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

# WHERE VCPKG UNPACKS AND COMPILES, and why it is not left at vcpkg's default.
#
# vcpkg builds under <root>/buildtrees/<port>/<triplet>-rel/. With this triplet name that prefix is 69
# characters, and Qt's autogen filenames are long enough that qtdeclarative reached 261 against the
# 260-character cap Windows applies to programs without a long-path manifest -- which MSYS2's GCC lacks, so
# LongPathsEnabled=1 in the registry does not help. The build failed with
# "error: opening dependency file ...: No such file or directory".
#
# A short root is the whole fix, and it is free: buildtrees is scratch and is not part of any package ABI.
# <drive>:/bt puts that same path at 247 and leaves room for Qt to grow; /buildtrees would put it at 255.
# One resolver, shared with step 1, which is what creates this directory. The POSIX form is what bash gets,
# since the install script runs under MSYS2. See Resolve-DrivEnvBuildtreesRoot for why this is not done here.
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

    # ONE RETRY, AND THE SECOND ATTEMPT IS SERIALISED. Not a plain repeat of the same command: the failures this
    # absorbs are concurrency- and resource-shaped, so running the retry with one job is what actually changes the
    # odds rather than just rolling the dice again.
    #
    # Three real failures on one machine, none of them a build error, all of them gone on a manual re-run:
    #
    #   openssl          Trying to rename Makefile-179 -> Makefile: Permission denied
    #                    A Win32 rename onto a file another process holds open without FILE_SHARE_DELETE.
    #                    openssl's dependmagic macro makes six targets each start with a recursive `make depend`,
    #                    so at -j>1 several add-depends.pl processes rename onto the same Makefile.
    #   mongo-c-driver   internal compiler error: Segmentation fault, during the GIMPLE fre pass
    #   glib             Access violation, out of the meson configure
    #
    # Retrying is safe precisely because vcpkg is per-package: everything installed before the failure is left
    # alone, so an attempt costs only the port that failed and never the tree behind it.
    #
    # WHAT THIS DELIBERATELY DOES NOT DO is hide the problem. Every retry is logged loudly and every port that
    # needed one is named again in the summary, because three unrelated programs crashing on one machine and none
    # on another is the signature of that machine, not of vcpkg -- and a retry that quietly succeeds would erase
    # the only evidence of it.
    $code = 1

    # THIS PORT'S SCHEDULE: the global default, unless the port asked for something else.
    #
    # A port-level install_schedule replaces the shape; a port-level max_install_attempts sets the length. Both
    # are optional and they compose the same way they do globally. This exists because the ports that need
    # throttling are not the ports that need retrying: qtbase and opencv4 have translation units that take
    # gigabytes on their own and want a low concurrency from the FIRST attempt, while a small port that failed
    # once is worth simply trying again at full speed.
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
            Write-Warn ("Retrying '{0}', attempt {1} of {2}, at concurrency {3}." -f
                        $port.Spec, $attempt, $portAttempts, (Format-InstallSchedule $concurrency))
        }

        # VCPKG_MAX_CONCURRENCY is read by vcpkg itself and passed down to the port's build system, which is what
        # makes it reach make and ninja rather than only vcpkg's own scheduling.
        #
        # Zero exports NOTHING rather than exporting 0: an explicit 0 is not documented to mean "unlimited", and
        # leaving the variable unset is the only way to get vcpkg's own sizing back.
        $concurrencyLine = ""
        if ($concurrency -ge 1) { $concurrencyLine = "export VCPKG_MAX_CONCURRENCY=$concurrency" }

        $installScript = $scriptHeader + @"

$concurrencyLine
./vcpkg install '$($port.Spec)' --triplet '$($port.Triplet)' --host-triplet '$vcpkgTriplet' --x-buildtrees-root='$buildtreesRoot'$overlayFlags
"@

        $tempName = "vcpkg_install_{0}_{1}.sh" -f ($port.Name -replace '[^A-Za-z0-9]', '_'), $attempt
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

        # THE FAILED ATTEMPT'S LOGS, SAVED NOW, because the next attempt destroys them.
        #
        # vcpkg writes the port's logs into the buildtree under fixed names -- build-<triplet>-rel-err.log and
        # friends -- so attempt 2 overwrites attempt 1's. With a four-entry schedule that leaves exactly one
        # set of logs on disk at the end: the last attempt's. The first failure is usually the informative one,
        # and the interesting comparison is between attempts, which is precisely what gets thrown away.
        #
        # Saved on the last attempt too. The tail quoted below is 25 lines of the two newest files, which is
        # enough to see a cause but not enough to diagnose one, and a re-run of this step overwrites even that.
        $savedTo = Save-VcpkgFailureLogs -PortName $port.Name -Attempt $attempt `
                                         -BuildtreesRoot $buildtreesRoot -DriveLetter $driveLetter
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

        # THE PORT'S OWN ERROR LOG, QUOTED HERE, because without it this run log does not contain the reason.
        #
        # vcpkg prints "See logs for more information:" and a list of paths on the dev drive, and that is where
        # the cause actually is -- the run log ends up with the CMake wrapper's complaint and nothing else. An
        # ffmpeg failure read as four attempts dying identically at every concurrency, which looks exactly like
        # a resource problem; the reason was one line in the port's own stderr:
        #     make: gcc: No such file or directory
        # a missing binary, invariant under concurrency, and invisible in the log that was being read. Quoting
        # the tail here costs nothing and puts the cause next to the failure.
        $portLogDir = Convert-ToWinPath ($buildtreesRoot -replace '^/([A-Za-z])/', '$1:/')
        $portLogDir = Join-Path $portLogDir $port.Name

        if (Test-Path -LiteralPath $portLogDir)
        {
            # Newest first: a retried port leaves several, and the last attempt is the interesting one.
            $errLogs = @(Get-ChildItem -LiteralPath $portLogDir -Filter "*-err.log" -ErrorAction SilentlyContinue |
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
                Write-Error "The port left no *-err.log; look under $portLogDir for its other logs."
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

# --x-json, not the plain listing, and this is a bug fix rather than a preference. `vcpkg list` pads the
# "name:triplet" column to a fixed width and TRUNCATES what does not fit, with an ellipsis:
#
#   qt-advanced-docking-system:x64-mingw-ucrt-dynam...4.5.0   Create customizable layouts...
#
# The triplet is simply gone. Matching against it then fails and the port is reported as not installed although it
# built and installed perfectly -- 46 files, DLL and headers included. Any port whose name is long enough to eat the
# column hits this, and a 30-character triplet leaves very little of it.
# The JSON is redirected to a FILE rather than read back from the captured stream, and that is the fix for a real
# failure. New-Msys2ScriptHeader ends by echoing three "[env] ..." diagnostic lines to stdout, and
# Get-Msys2ScriptOutput captures stdout and stderr together -- so what came back began
#
#     [env] MSYSTEM=UCRT64
#
# and parsing it as JSON failed with "Unexpected character encountered while parsing value: e", because "[" opens an
# array and position 1 is the "e" of "env". The diagnostics are worth keeping and any command may add a warning of
# its own, so the answer is not to silence the stream but to stop mixing a data channel into it.
$listJsonWin  = Join-Path $env:TEMP "vcpkg_list.json"
$listJsonUnix = Convert-ToMSYSPath $listJsonWin
Remove-Item -LiteralPath $listJsonWin -Force -ErrorAction SilentlyContinue

$listScript = $scriptHeader + @"

./vcpkg list --x-json > '$listJsonUnix'
"@

$listResult = Get-Msys2ScriptOutput -BashPath $msys2BashWin -ScriptBody $listScript -TempName "vcpkg_list.sh"

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

# SKIPPED AFTER A CANCELLATION, and this is about not destroying evidence rather than about tidiness. This
# step and the next write "what this environment IS" -- the manifest and the inventory. After an interrupt
# the environment is half-built, and writing those files would replace an accurate record of the last
# complete run with an inaccurate record of an interrupted one. Step 4 still runs: "what is installed right
# now" is precisely the question a cancelled run leaves open.
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
    "name"         = (ConvertTo-ManifestName $devEnvName)
    "version-string" = "0.0.0"
    "description"  = ("Reference manifest generated by 4-Deps_VCPKG.ps1 for the {0} environment." -f $devEnvName)
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
# A record of WHAT THIS ENVIRONMENT ACTUALLY IS, written to the drive
# next to the hand-written notes. Generated rather than maintained,
# because a list of a hundred packages is not something anybody keeps
# accurate by hand -- and the moment it is inaccurate it is worse than
# absent.
#
# What each file answers:
#   vcpkg_packages.txt   which ports, which versions, which features
#   vcpkg_packages.json  the same, in a form worth diffing between two
#                        environments or two dates
#   vcpkg_baseline.txt   the baseline commit and what it was, so a
#                        version can be traced back to an upstream state
#   msys2_packages.txt   the MSYS2 side, which vcpkg knows nothing about
#   environment.txt      the generated variables, verbatim

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
try
{
    $listText = & $vcpkgExeWin list 2>&1
    if ($LASTEXITCODE -eq 0)
    {
        Write-InventoryFile -Name "vcpkg_packages.txt" -Title "VCPKG PACKAGES" -Body $listText
    }
    else
    {
        Write-Warn "vcpkg list failed; vcpkg_packages.txt not written."
    }

    $jsonText = & $vcpkgExeWin list --x-json 2>&1
    if ($LASTEXITCODE -eq 0)
    {
        $jsonDest  = Join-Path $inventoryDir "vcpkg_packages.json"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($jsonDest, $jsonText, $utf8NoBom)
        Write-Info "Wrote $jsonDest"
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
    # Prefer the git ON THE DRIVE over whatever the caller happens to have on PATH, the same way and for the same
    # reason step 3 does it: this environment is self-contained, and asking Get-Command first made the richness of
    # the record depend on the PATH of whoever launched the script rather than on the drive. Someone running step 4
    # from a plain PowerShell with no system git got the bare commit; from the environment launcher, the full
    # description. Same drive, same baseline, two different inventories.
    #
    # Step 2 installs the MinGW flavour, which lands in <DEVSYSTEM_TOOLCHAIN_ROOT>\bin; the plain MSYS package would land in
    # <MSYS2_ROOT>\usr\bin. Both are accepted. PATH stays as a last resort so nothing is lost where it used to work.
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
        # -c safe.directory: a clone on a drive this account does not own is refused by git as "dubious
        # ownership", which is right for anything that writes and pointless for one read of the log.
        $baseline = & $gitSource -c "safe.directory=*" -C $vcpkgRootWin log -1 `
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
            Write-InventoryFile -Name "msys2_packages.txt" -Title "MSYS2 PACKAGES" -Body $pac
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
        Write-InventoryFile -Name "environment.txt" -Title "GENERATED ENVIRONMENT VARIABLES" `
            -Body (Get-Content -LiteralPath $envFilePath)
    }
}
catch
{
    Write-Warn "Could not copy the environment file: $($_.Exception.Message)"
}

Write-Info "STEP 6: OK"

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
