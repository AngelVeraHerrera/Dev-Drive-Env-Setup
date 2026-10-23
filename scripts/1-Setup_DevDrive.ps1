# ====================================================================
# SETUP WINDOWS DEV DRIVE SCRIPT
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
#          David Abuín Sánchez
# Updated: 20/10/2026
# Version: 3.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================

# FUNCTIONS
# --------------------------------------------------------------------

param
(
    # @brief JSON configuration. A bare name resolves against config/. Every step must get the same file.
    [string]$ConfigFile = "drivenv-cfg.json",

    # @brief Validate the configuration and stop, changing nothing.
    [switch]$ValidateOnly,

    # @brief Internal, for the elevated relaunch: no "Press any key" after a success (the runner is waiting), and the
    # account that started it, which environment.owner "current" means.
    [switch]$NoPause,
    [string]$OwnerAccount = ""
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
    $ts   = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][INFO][$msg]"
    Write-Host $line
    if ($globalLogFile) {Add-Content -Path $globalLogFile -Value $line}
}

function Write-Warn
{
    # @brief A warning line, shaped like Write-Info/Write-Error and mirrored into the log.
    param ($msg)
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][WARN][$msg]"
    Write-Host $line
    if ($globalLogFile) {Add-Content -Path $globalLogFile -Value $line}
}

function Write-Error 
{
    param ($msg)
    $ts   = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $line = "[$ts][ERROR][$msg]"
    Write-Host $line
    if ($globalLogFile){Add-Content -Path $globalLogFile -Value $line}
}

function Abort-WithError 
{
    $ts   = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
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
    $principal       = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DrivEnvMountTaskForVhd
{
    # @brief Every scheduled task that mounts this VHDX, whatever its name: found by action, never by name (a name
    # could match a vendor task). Parses the -Argument built below and by Import-DevDrive.ps1; keep them in step.
    # @param VhdPath Full path to the VHDX, compared normalised and case-insensitively.
    param ([string]$VhdPath)

    $wanted = $null
    try   { $wanted = [System.IO.Path]::GetFullPath($VhdPath) }
    catch { return @() }

    $found = @()
    foreach ($task in @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue))
    {
        foreach ($action in @($task.Actions))
        {
            $arguments = [string]$action.Arguments
            if ($arguments -notmatch 'Mount-VHD|Mount-DiskImage') { continue }

            $m = [regex]::Match($arguments, "-(?:Image)?Path\s+'([^']+)'")
            if (-not $m.Success) { continue }

            $candidate = $null
            try   { $candidate = [System.IO.Path]::GetFullPath($m.Groups[1].Value) }
            catch { continue }

            if ($candidate -and $candidate.Equals($wanted, [System.StringComparison]::OrdinalIgnoreCase))
            {
                $found += $task
                break
            }
        }
    }

    return $found
}

function Get-ScriptDirectory
{
    if ($PSScriptRoot) {
        return $PSScriptRoot
    } else {
        return Split-Path -Parent (Convert-Path -LiteralPath ([System.Environment]::GetCommandLineArgs()[0]))
    }
}

function Disable-HWDetection 
{
    Write-Info "Stopping ShellHWDetection service (to avoid format popup)..."
    try {
        Stop-Service -Name ShellHWDetection -Force -ErrorAction Stop
    }
    catch {
        Write-Error "Could not stop ShellHWDetection: $_"
    }
}

function Enable-HWDetection 
{
    Write-Info "Restarting ShellHWDetection service..."
    try {
        Start-Service -Name ShellHWDetection -ErrorAction Stop
    }
    catch {
        Write-Error "Could not start ShellHWDetection: $_"
    }
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
} catch 
{
    Write-Error "Invalid JSON in ${ConfigPath}: $($_.Exception.Message)"
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
$metaLine = Get-DrivEnvMetadataSummary -Cfg $Cfg; if ($metaLine) { Write-Info $metaLine }

# diskpart, fsutil and powershell.exe are called by name from System32: make sure PATH has it (appended, nothing shadowed).
[void](Add-DrivEnvWindowsSystemPath -Report { param($m) Write-Info $m })

if ($ValidateOnly)
{
    Write-Info "-ValidateOnly was given, so nothing further will run."
    exit 0
}

# CHECK PERMISSIONS
# --------------------------------------------------------------------
# After validation: -ValidateOnly must never trigger a UAC prompt.


if (-not (Test-IsAdministrator))
{
    # Forward -ConfigFile, or the elevated child would provision the default configuration instead.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "powershell.exe"
    $childArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigFile `"$ConfigFile`""

    # Forward -ValidateOnly too, so a later reordering cannot turn a check into a real run.
    if ($ValidateOnly) { $childArguments += " -ValidateOnly" }

    # The account running THIS (unelevated) process is the one the drive's files go to (environment.owner "current"):
    # elevated, the child may run as another account. Started by the runner (stdin redirected): no final pause, or
    # the run would wait on a key in a window of its own.
    $childArguments += (" -OwnerAccount `"{0}`"" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    if ([Console]::IsInputRedirected) { $childArguments += " -NoPause" }

    $psi.Arguments = $childArguments
    $psi.Verb      = "runas"   # triggers UAC
    $psi.UseShellExecute = $true

    try
    {
        $childProcess = [System.Diagnostics.Process]::Start($psi)
    }
    catch
    {
        # Cancelling the UAC prompt lands here: ShellExecuteEx reports 1223, "operation cancelled by the user".
        Write-Error "Elevation was cancelled or failed."
        Abort-WithError
    }

    # Wait for the elevated run and exit with its code, so callers see its failures.
    if ($null -eq $childProcess)
    {
        Write-Error "Elevation returned no process, so the result of the elevated run cannot be known."
        Abort-WithError
    }

    Write-Info "Elevated run started as PID $($childProcess.Id). Waiting for it to finish..."
    $childProcess.WaitForExit()

    # Read through a guard: the handle ShellExecuteEx hands back for an elevated process is enough to wait on, and
    # normally enough to query, but a failure to read the code must not become a crash in place of a verdict.
    $childExitCode = 1
    try
    {
        $childExitCode = $childProcess.ExitCode
    }
    catch
    {
        Write-Error "The elevated run finished but its exit code could not be read. Treating that as a failure."
    }

    if ($childExitCode -eq 0)
    {
        Write-Info "Elevated run finished successfully."
    }
    else
    {
        Write-Error "The elevated run failed with exit code $childExitCode. Its own log records why."
    }

    exit $childExitCode
}


if (-not $Cfg.environment)
{
    Write-Error "Missing 'environment' object in config JSON: $ConfigPath"
    Abort-WithError 
}

$driveLabel  = [string]$Cfg.environment.dev_drive_label
$driveLetter = [string]$Cfg.environment.dev_drive_letter
$devEnvName  = [string]$Cfg.environment.dev_env_name
$vhdPath     = [string]$Cfg.environment.vhd_root
$sizeGB      = [int]   $Cfg.environment.vhd_size_gb
$useDevDriveConfig = [bool]$Cfg.environment.use_dev_drive
$forceDiskpart = [bool]$Cfg.environment.force_diskpart
$vhdIsFixed = [bool]$Cfg.environment.vhd_fixed   # key is vhd_fixed; the old vhd_is_fixed always read $null

# Keys defaulting to TRUE are read presence-first: [bool]$null would turn them off for older configurations.
$createDesktopShortcuts = $true
if ($Cfg.environment.PSObject.Properties.Name -contains "create_desktop_shortcuts")
{
    $createDesktopShortcuts = [bool]$Cfg.environment.create_desktop_shortcuts
}

$automountAtStartup = $true
if ($Cfg.environment.PSObject.Properties.Name -contains "automount_at_startup")
{
    $automountAtStartup = [bool]$Cfg.environment.automount_at_startup
}

if ([string]::IsNullOrWhiteSpace($driveLabel))  {Write-Error "Missing environment.dev_drive_label"; Abort-WithError}
if ([string]::IsNullOrWhiteSpace($driveLetter)) {Write-Error "Missing environment.dev_drive_letter"; Abort-WithError}
if ([string]::IsNullOrWhiteSpace($devEnvName))  {Write-Error "Missing environment.dev_env_name"; Abort-WithError}
if ([string]::IsNullOrWhiteSpace($vhdPath))     {Write-Error "Missing environment.vhd_root"; Abort-WithError}
if ($sizeGB -le 0)                              {Write-Error "Invalid environment.vhd_size_gb"; Abort-WithError}

# Dev Drive size constraint
if ($useDevDriveConfig -and $sizeGB -lt 50) 
{
    Write-Error "Dev Drive requires at least 50GB. Current size: ${sizeGB}GB."
    Abort-WithError
}

$driveLetter = $driveLetter.Trim().TrimEnd(':')         
$vhdPath     = $vhdPath -replace '/', '\'            

# Prevent saving VHDX to the same drive letter that will be used for the Dev Drive
if (($vhdPath -split ':')[0] -eq $driveLetter) {
    Write-Error "Error: You cannot save the VHDX to the same drive you are creating (${driveLetter}:)."
    Abort-WithError
}

#Verify that the physical destination disk actually exists
if (-not (Test-Path "$(($vhdPath -split ':')[0]):\" -ErrorAction SilentlyContinue)) {
    Write-Error "Error: The physical disk for vhd_root does not exist."
    Abort-WithError
}

# INITIAL PREPARATION
# --------------------------------------------------------------------

$scriptStart     = Get-Date
$scriptDir       = Get-ScriptDirectory
# The generator root, one level above scripts/.
$drivEnvRoot = Split-Path -Parent $scriptDir
$vhdFilePath     = Join-Path $vhdPath ("{0}.vhdx" -f $driveLabel)
$vhdRoot         = [System.IO.Path]::GetPathRoot($vhdPath)

$timestamp       = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir         = Join-Path $drivEnvRoot "logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile   = Join-Path $logsDir "${timestamp}_generic_devdrive-setup.log"
$globalLogFileUnix = $globalLogFile -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'

Clear-Host
$originalTitle = $host.UI.RawUI.WindowTitle
$host.UI.RawUI.WindowTitle = "SETUP WINDOWS DEV DRIVE SCRIPT"

Write-NoFormat "==========================================================="
Write-NoFormat "  SETUP WINDOWS DEV DRIVE SCRIPT"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "  Authors: Ángel Vera Herrera"
Write-NoFormat "           David Abuín Sánchez"
Write-NoFormat "  Updated: 20/10/2026"
Write-NoFormat "  Version: 3.0.0"
Write-NoFormat "================================================================="
Write-NoFormat "Parameters:"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "Drive Label    = $driveLabel"
Write-NoFormat "Drive Letter   = $driveLetter"
Write-NoFormat "Size (GB)      = $sizeGB"
Write-NoFormat "Dev Env Name   = $devEnvName"
Write-NoFormat "VHDX Root      = $vhdRoot"
Write-NoFormat "VHDX Path      = $vhdPath"
Write-NoFormat "Current Path   = $scriptDir"
Write-NoFormat "Use Dev Drive  = $useDevDriveConfig"
Write-NoFormat "Force Diskpart = $forceDiskpart"
Write-NoFormat "VHD Fixed      = $vhdIsFixed"
Write-NoFormat "================================================================="

# STEP 1: Initial checks.
# --------------------------------------------------------------------

Write-Info "STEP 1: Initial checks and preparations."

if (-not $forceDiskpart)
{
    Write-Info "Checking Hyper-V PowerShell module (New-VHD)..."
    try {
        $hvCmd = Get-Command New-VHD -ErrorAction SilentlyContinue
        if (-not $hvCmd) {
            Write-Error "Hyper-V PowerShell module not found. Cmdlets like New-VHD/Mount-VHD are unavailable."
            Write-Error "Please enable Hyper-V Management Tools:"
            Write-Error "  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -All"
            Abort-WithError
        }
        Write-Info "Hyper-V PowerShell module available."
    }
    catch {
        Write-Error "Error checking Hyper-V module."
        Abort-WithError
    }
}
else
{
    Write-Info "Using Diskpart. Skipping Hyper-V module check."
}

Write-Info "Checking OS compatibility..."
$useDevDrive = $false
try {
    $osInfo = Get-ComputerInfo | Select-Object OsName, OsBuildNumber
    Write-Info "Detected OS: $($osInfo.OsName) | Build: $($osInfo.OsBuildNumber)"

    $osName  = $osInfo.OsName
    $osBuild = [int]$osInfo.OsBuildNumber
    $isWin11 = ($osName -match "Windows 11") -and ($osBuild -ge 22000)

    if ($isWin11 -and $useDevDriveConfig) 
    {
        $useDevDrive = $true
        Write-Info "Dev Drive mode enabled (Windows 11 + config flag)."
    } 
    else 
    {
        $useDevDrive = $false
        Write-Info "Standard NTFS mode enabled."
    }
}
catch {
    Write-Error "Could not determine OS version."
    Abort-WithError
}

Write-Info "Checking letter format..."
if ($driveLetter -notmatch '^[A-Z]$') {
    Write-Error "Invalid drive letter format: $driveLetter"
    Abort-WithError
}

Write-Info "Checking if VHD already exists..."
if (Test-Path $vhdFilePath) {
    Write-Error "VHD already exists: $vhdFilePath"
    Abort-WithError
}

Write-Info "Checking if drive letter is in use..."

# Get-Volume misses letters held by a mapped drive, a subst or an attached VHD without a volume: GetLogicalDrives does not.
$letterHolder = $null
if (Get-Volume -driveLetter $driveLetter -ErrorAction SilentlyContinue) {
    $letterHolder = "a mounted volume"
}
elseif (@([System.IO.Directory]::GetLogicalDrives() | ForEach-Object { $_.Substring(0, 1) }) -contains $driveLetter) {
    $letterHolder = "something that is not a volume: a mapped network drive, a subst, " +
                    "or an attached disk with no mounted filesystem"
}
if ($null -ne $letterHolder) {
    Write-Error "Drive letter $driveLetter is already in use by $letterHolder."
    Abort-WithError
}

Write-Info "Checking disk space..."
try {
    $requiredBytes = $sizeGB * 1GB
    $rootDrive     = ($vhdRoot -split ':')[0]
    $volume        = Get-Volume -DriveLetter $rootDrive -ErrorAction Stop
    $freeBytes     = $volume.SizeRemaining
    Write-Info "Available Space = $freeBytes bytes"
    Write-Info "Required Space  = $requiredBytes bytes"
    if ($freeBytes -lt $requiredBytes) {
        Write-Error "Not enough free space on drive $rootDrive"
        Abort-WithError
    }
}
catch {
    Write-Error "Could not determine free space on drive..."
    Abort-WithError
}

Write-Info "Checking VHD folder..."
if (!(Test-Path $vhdPath)) {
    Write-Info "Creating folder: $vhdPath"
    New-Item -ItemType Directory -Path $vhdPath | Out-Null
}

Write-Info "Add VHD folder to Defender exclusion..."
Add-MpPreference -ExclusionPath $vhdPath

Write-Info "STEP 1: OK"

# STEP 2: Disable AutoplayHandlers to avoid Windows popup
# --------------------------------------------------------------------

Write-Info "STEP 2: Disable AutoplayHandlers to avoid Windows popup."
Write-Info "Disabling AutoplayHandlers temporarily..."
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" `
                 -Name "DisableAutoplay" -Value 1
Write-Info "STEP 2: OK"

# STEP 3: Create and Attach the VHD (New-VHD / Mount-VHD)
# --------------------------------------------------------------------

Write-Info "STEP 3: Create and Attach the VHD."

$useHyperV = $false

if (-not $forceDiskpart)
{
    try {
        $hvCmd = Get-Command New-VHD -ErrorAction SilentlyContinue
        if ($hvCmd) {
            $useHyperV = $true
            Write-Info "Using Hyper-V VHDX creation method."
        } else {
            Write-Info "Hyper-V cmdlets not available. Falling back to DiskPart."
            $useHyperV = $false
        }
    }
    catch {
        Write-Error ("Error checking Hyper-V cmdlets: {0}" -f $_.Exception.Message)
        Abort-WithError
    }
}
else
{
    Write-Info "force_diskpart=true → Using DiskPart method."
    $useHyperV = $false
}

Disable-HWDetection

try
{
    # Capture disk list BEFORE attaching the VHD (for reliable identification)
    $before = @(Get-Disk | Select-Object -ExpandProperty Number)

    if ($useHyperV)
    {
        try {
            $vhdTypeMsg = if ($vhdIsFixed) { "Fixed" } else { "Dynamic" }
            Write-Info "Creating $vhdTypeMsg VHDX (Hyper-V) at $vhdFilePath (Size = ${sizeGB}GB)..."
            if ($vhdIsFixed) 
            {
                New-VHD -Path $vhdFilePath -SizeBytes ($sizeGB * 1GB) -Fixed   -ErrorAction Stop | Out-Null
            } 
            else 
            {
                New-VHD -Path $vhdFilePath -SizeBytes ($sizeGB * 1GB) -Dynamic -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-Error ("New-VHD failed: {0}" -f $_.Exception.Message)
            Abort-WithError
        }

        Start-Sleep -Milliseconds 1500

        try {
            Write-Info "Mounting VHDX (Hyper-V)..."
            Mount-VHD -Path $vhdFilePath -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Error ("Mount-VHD failed: {0}" -f $_.Exception.Message)
            Abort-WithError
        }
    }
    else
    {
        try 
        {
            $maxMB = [int]($sizeGB * 1024)
            $dpType = if ($vhdIsFixed) { "fixed" } else { "expandable" }

            Write-Info "Creating VHDX (DiskPart) type=$dpType at $vhdFilePath (Size = ${sizeGB}GB)..."

            $diskpartScript = @"
create vdisk file="$vhdFilePath" maximum=$maxMB type=$dpType
select vdisk file="$vhdFilePath"
attach vdisk
"@

            $dpOut = ($diskpartScript | diskpart 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) {
                Write-Error ("DiskPart failed (exit {0}): {1}" -f $LASTEXITCODE, $dpOut)
                Abort-WithError
            }
        }
        catch {
            Write-Error ("DiskPart VHD creation/attach failed: {0}" -f $_.Exception.Message)
            Abort-WithError
        }
    }

    Start-Sleep -Milliseconds 1000

    # Identify newly attached disk number by diff
    $after = @(Get-Disk | Select-Object -ExpandProperty Number)

    $newDiskNumber = (Compare-Object $before $after |
                      Where-Object SideIndicator -eq "=>" |
                      Select-Object -First 1 -ExpandProperty InputObject)

    if (-not $newDiskNumber)
    {
        Write-Error "Could not determine newly attached disk number after attach."
        Abort-WithError
    }

    try {
        $disk = Get-Disk -Number $newDiskNumber -ErrorAction Stop
    }
    catch {
        Write-Error ("Get-Disk failed for Disk Number {0}: {1}" -f $newDiskNumber, $_.Exception.Message)
        Abort-WithError
    }

    Write-Info "Using Disk Number: $($disk.Number) for initialization."
    Write-Info "STEP 3: OK"
}
finally
{
    # Always restore ShellHWDetection even if something fails
    Enable-HWDetection
}

# STEP 4: Initialize disk, partition and format
# --------------------------------------------------------------------

if ($useDevDrive) 
{
    Write-Info "STEP 4: Initialize disk and format as DevDrive (Windows 11)."

    try {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru | `
            New-Partition -DriveLetter $driveLetter -UseMaximumSize | `
            Format-Volume -DevDrive -NewFileSystemLabel $driveLabel -Confirm:$false -Force *> $null
    }
    catch {
        Write-Error "Disk initialization/partition/format failed (DevDrive): $_"
        Abort-WithError
    }

    Start-Sleep -Milliseconds 500

    # Undo a global 'fsutil devdrv enable /disallowAv' -- this step ran it until 2026-10-21, and it outlives the drive
    # it was run for: with it Defender attaches to NO Dev Drive, performance mode included. A policy that forbids
    # antivirus on Dev Drives still wins over this.
    $allowOut = & fsutil devdrv enable /allowAv 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warn "fsutil devdrv enable /allowAv reported exit ${LASTEXITCODE}: $allowOut" }
    else { Write-Info "Antivirus filters allowed on Dev Drives (fsutil devdrv enable /allowAv)." }

    Write-Info "Trusting volume as Dev Drive..."
    $trustOut = & fsutil devdrv trust "$driveLetter`:" 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        Write-Error "fsutil devdrv trust failed (exit $LASTEXITCODE): $trustOut"
        Abort-WithError
    }

    # A trusted Dev Drive gets Defender's performance mode (asynchronous scanning), which Microsoft recommends over
    # both /disallowAv (no antivirus filter on ANY Dev Drive) and path exclusions (no scanning at all).
    # https://learn.microsoft.com/windows/dev-drive/  -- performance mode needs real-time protection on.
    $devdrvState = & fsutil devdrv query "$driveLetter`:" 2>&1
    Write-NoFormat ("  fsutil devdrv query: " + ($devdrvState -join " "))
}
else {
    Write-Info "STEP 4: Initialize disk and format as NTFS (Windows 10 / non-DevDrive)."

    try {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru | `
            New-Partition -DriveLetter $driveLetter -UseMaximumSize | `
            Format-Volume -FileSystem NTFS -NewFileSystemLabel $driveLabel -Confirm:$false -Force | Out-Null
    }
    catch {
        Write-Error "Disk initialization/partition/format failed (NTFS): $_"
        Abort-WithError
    }

    Start-Sleep -Milliseconds 500
}

# --------------------------------------------------------------------
# Defender path exclusion, NTFS only
# --------------------------------------------------------------------
# A Dev Drive is covered by performance mode (above). On NTFS an exclusion is the only speed-up there is; the
# host-folder exclusion does not cover files opened as <letter>:\.
# Not the fix for openssl's "Permission denied" renaming Makefile: that is a race between its own concurrent
# add-depends.pl runs, handled by step 3 (Update-VcpkgScriptPatches, serial retry).
try {
    if ($useDevDrive) {
        Write-Info "Dev Drive: no Defender exclusion; it is scanned in performance mode."
    }
    elseif (Get-Command Add-MpPreference -ErrorAction SilentlyContinue) {
        Write-Info "Adding Microsoft Defender exclusion for ${driveLetter}:\ ..."

        # No `2>$null` here any more, and -ErrorAction Stop so the catch below actually sees a failure. The
        # previous version discarded stderr, which made every way this can fail look exactly like success.
        Add-MpPreference -ExclusionPath "${driveLetter}:\" -ErrorAction Stop

        # Read it back: Tamper Protection or a managed policy can make Add-MpPreference a silent no-op.
        $exclusions = @((Get-MpPreference).ExclusionPath)

        if ($exclusions -contains "${driveLetter}:\") {
            Write-Info "Defender exclusion confirmed for ${driveLetter}:\"
        }
        else {
            Write-Warn "Defender accepted the call, but ${driveLetter}:\ is NOT in the exclusion list."
            Write-Warn "Tamper Protection or a managed policy is the usual reason. Check with:"
            Write-Warn "    (Get-MpComputerStatus).IsTamperProtected"
            Write-Warn "Builds still work without it. On-access scanning widens the window for file-locking"
            Write-Warn "races during builds, so expect the occasional transient failure and a retry that passes."
        }
    }
    else {
        Write-Info "Microsoft Defender cmdlets not found; skipping AV exclusion."
    }
}
catch {
    # Not fatal: an environment without the exclusion builds correctly, only slower and slightly more prone to
    # transient file-locking failures. Failing the whole drive setup over it would be out of proportion.
    Write-Warn "Could not add the Defender exclusion: $_"
    Write-Warn "Continuing. Builds work without it; on-access scanning costs speed and can cause transient"
    Write-Warn "file-locking failures. Add ${driveLetter}:\ by hand in Windows Security if you want it."
}

# --------------------------------------------------------------------
# Two more things that cost build performance, and neither needs administrator rights
# --------------------------------------------------------------------
# CONTENT INDEXING: NotContentIndexed on the volume root, as the drive's properties dialog sets it. It only stops
# content extraction for objects that inherit it at creation (vcpkg/ does, msys64/ does not: 7-Zip sets attributes
# per entry); it does not keep the drive out of the index. What does is the indexer's crawl scope, which nothing
# here controls. Cheap, so kept. Untested on a Dev Drive (this machine is Windows 10).
#
# RECYCLE BIN: NukeOnDelete, so deleted build trees (gigabytes per port) are freed, not kept. Per volume, HKCU, no
# elevation needed.
try {
    $driveRoot = "$driveLetter`:\"

    if (Test-Path $driveRoot)
    {
        Write-Info "Suppressing content indexing on $driveRoot ..."
        $rootItem = Get-Item $driveRoot -Force
        if ($rootItem.Attributes -band [System.IO.FileAttributes]::NotContentIndexed)
        {
            Write-Info "Content indexing of file contents was already suppressed on the volume root."
        }
        else
        {
            $rootItem.Attributes = $rootItem.Attributes -bor [System.IO.FileAttributes]::NotContentIndexed
            Write-Info "Content indexing of file contents suppressed on the volume root. Note this does not remove the volume from the Windows Search crawl scope."
        }
    }
}
catch {
    # Not fatal. A drive that gets indexed is a slower drive, not a broken one.
    Write-Warn ("Could not suppress content indexing: {0}" -f $_.Exception.Message)
}

try {
    # The recycle bin is configured per volume, keyed by the volume's own GUID rather than by drive letter --
    # which is the right key, because the letter can change and the setting should follow the volume.
    $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    # UniqueId reads like \\?\Volume{a1b2...}\ so the GUID has to be pulled out of it; the registry key is
    # named by the braced GUID alone.
    $uniqueId = [string]$vol.UniqueId
    $m = [regex]::Match($uniqueId, '(\{[0-9A-Fa-f-]+\})')

    if ($m.Success)
    {
        $guid = $m.Groups[1].Value
        $bucket = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\$guid"

        if (-not (Test-Path $bucket)) { New-Item -Path $bucket -Force | Out-Null }
        New-ItemProperty -Path $bucket -Name "NukeOnDelete" -Value 1 -PropertyType DWord -Force | Out-Null

        Write-Info "Recycle bin disabled for this volume ($guid): deletes free space immediately."
    }
    else
    {
        Write-Warn "Could not read the volume GUID; leaving the recycle bin as it is."
    }
}
catch {
    Write-Warn ("Could not disable the recycle bin for this volume: {0}" -f $_.Exception.Message)
}

Write-Info "STEP 4: OK"

Enable-HWDetection

# STEP 5: Reattach (DevDrive only)
# --------------------------------------------------------------------

if ($useDevDrive) {
    Write-Info "STEP 5: Dismount and Reattach DevDrive to apply policies."

    # The Storage module's cmdlets, not Hyper-V's: a drive built with diskpart on a PC without Hyper-V got here too.
    try {
        Write-Info "Dismounting VHDX..."
        Dismount-DiskImage -ImagePath $vhdFilePath -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 1

        Write-Info "Re-mounting VHDX..."
        Mount-DiskImage -ImagePath $vhdFilePath -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "Error during Dismount-DiskImage / Mount-DiskImage: $_"
        Abort-WithError
    }

    $maxWait = 10
    $tries   = 0
    do {
        Start-Sleep -Milliseconds 500
        $volume = Get-Volume -driveLetter $driveLetter -ErrorAction SilentlyContinue
        $tries++
    } while (-not $volume -and $tries -lt $maxWait)

    if ($volume) {
        Write-Info "Dev Drive is re-mounted and ready at ${driveLetter}:"
    } else {
        Write-Error "Dev Drive did not reappear after remounting."
        Abort-WithError
    }

    # Filters attach at mount time, so this is the state the drive will work in: WdFilter attached is Defender there.
    Write-NoFormat ("  fsutil devdrv query: " + ((& fsutil devdrv query "$driveLetter`:" 2>&1) -join " "))
    try
    {
        if ((Get-MpPreference -ErrorAction Stop).PerformanceModeStatus -eq 1)
        {
            Write-Warn "Defender's performance mode is OFF on this PC, so the Dev Drive is scanned synchronously."
            Write-Warn "Set-MpPreference -PerformanceModeStatus Enabled (elevated) turns it on, unless a policy turned it off."
        }
    }
    catch { Write-Warn "Microsoft Defender could not be queried for performance mode: $($_.Exception.Message)" }

    Start-Sleep -Milliseconds 200
    Write-Info "STEP 5: OK"
} else {
    Write-Info "STEP 5: Skipped (standard NTFS VHDX - no DevDrive reattach needed)."
}

# STEP 6: Create Workspace Folder Structure
# --------------------------------------------------------------------

Write-Info "STEP 6: Create Workspace Folder Structure."

Write-Info "Creating workspace folder tree inside drive $driveLetter..."

# The workspace folder comes from workspace.default_folder (default "workspace"), through the same resolver that
# step 2 publishes as DEVSYSTEM_WORKSPACE and step 6 clones into.
$workspaceFolder = Resolve-DrivEnvWorkspaceFolder -Cfg $Cfg
if ([string]::IsNullOrWhiteSpace($workspaceFolder))
{
    # A hand-edited config must not be able to make this script create directories outside the drive it owns.
    Write-Error "workspace.default_folder: '$($Cfg.workspace.default_folder)' must be relative to the drive root, with no drive letter and no '..'."
    Abort-WithError
}

# vcpkg's build trees, created now from the same resolver step 4 uses. Default <drive>:/bt: short on purpose, since
# Qt's autogen paths under a long triplet hit the 260-character limit of MSYS2's GCC (no long-path manifest).
$buildtreesFolder = (Resolve-DrivEnvBuildtreesRoot -Cfg $Cfg -DriveLetter $driveLetter `
                                                   -Warn { param($m) Write-Warn $m }).Folder

$folders = 
@(
    "${driveLetter}:/$buildtreesFolder",

    # Temporaries for vcpkg's builds. The triplets point TMP and TEMP here, but only if the directory exists,
    # so this line is what actually keeps a port's configure scratch off the system disk.
    "${driveLetter}:/tmp",

    "${driveLetter}:/deploys",
    "${driveLetter}:/installation",
    "${driveLetter}:/logs/env",

    # setup/ gets each step's log, vcpkg/ the logs of failed ports; created now so step 4's first failure has a target.
    "${driveLetter}:/logs/setup",
    "${driveLetter}:/logs/vcpkg",
    "${driveLetter}:/env/launcher",
    "${driveLetter}:/env/settings",
    "${driveLetter}:/testing",
    "${driveLetter}:/$workspaceFolder"
)

# --------------------------------------------------------------------
# environment.custom_folders
# --------------------------------------------------------------------
# Extra folders, relative to the drive root (the validator refuses absolute paths and '..'). Entries holding
# ${DEVSYSTEM_TOOLCHAIN_ID} are per toolchain and created by step 3. Not wrapped in @(): the function comma-returns.
foreach ($rel in (Get-DrivEnvCustomFolders -Cfg $Cfg -ToolchainKey ''))
{
    $folders += "${driveLetter}:/$rel"
}

foreach ($f in $folders) {
    if (-Not (Test-Path $f)) {
        New-Item -ItemType Directory -Path $f -Force | Out-Null
        Write-Info "Created folder: $f"
    }
}

# Launchers are per toolchain and deployed by step 2.

# --------------------------------------------------------------------
# Testing material
# --------------------------------------------------------------------
# drive\samples travels with the drive as <drive>:/testing, so a drive can be checked without the generator.
# Never overwrites: files already on the drive are kept. environment.install_testing_material = false skips it.
$treeWanted = @{ "testing" = $true }
if ($Cfg.environment.PSObject.Properties.Name -contains 'install_testing_material') { $treeWanted["testing"] = [bool]$Cfg.environment.install_testing_material }

foreach ($tree in @("testing"))
{
    if (-not $treeWanted[$tree])
    {
        Write-Info "$tree material not requested (environment.install_${tree}_material = false), skipping."
        continue
    }

    $source = Join-Path $drivEnvRoot "drive\samples"
    if (-not (Test-Path -LiteralPath $source))
    {
        Write-Info "No $tree tree in the generator, nothing to copy."
        continue
    }

    $target = "${driveLetter}:/$tree"
    Write-Info "Copying $tree material to $target ..."

    $copied = 0
    $kept   = 0
    foreach ($item in (Get-ChildItem -LiteralPath $source -Recurse -File))
    {
        $rel  = $item.FullName.Substring($source.Length).TrimStart("\", "/")
        $dest = Join-Path $target $rel
        $destDir = Split-Path -Parent $dest

        if (-not (Test-Path -LiteralPath $destDir))
        {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        if (Test-Path -LiteralPath $dest)
        {
            $kept++
            continue
        }

        Copy-Item -LiteralPath $item.FullName -Destination $dest
        $copied++
    }

    Write-Info "$tree : $copied file(s) copied, $kept already present and left alone."
}

Write-Info "STEP 6: OK"

# STEP 7: Restore AutoplayHandlers 
# --------------------------------------------------------------------

Write-Info "STEP 7: Restore AutoplayHandlers."
Write-Info "Re-enabling AutoplayHandlers..."
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" `
                 -Name "DisableAutoplay" -Value 0
Write-Info "STEP 7: OK"

# STEP 8: Drive shortcut
# --------------------------------------------------------------------

Write-Info "STEP 8: Drive shortcut."

# No env file here: step 2 writes one per toolchain, starting with the drive header from Get-DrivEnvDriveEnvValues.
$volumeLabel  = $driveLabel
$desktopPath  = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath ("$volumeLabel.lnk")

if ($createDesktopShortcuts)
{
    Write-Info "Creating shortcut to Dev Drive on desktop..."

    $WshShell     = New-Object -ComObject WScript.Shell
    $shortcut     = $WshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath   = $vhdFilePath
    $shortcut.WindowStyle  = 1
    $shortcut.IconLocation = "shell32.dll,8"
    $shortcut.Description  = "Shortcut to VHDX image for $volumeLabel"
    $shortcut.Save()

    Write-Info "Shortcut created: $shortcutPath"
}
else
{
    # Removed (not just skipped) when turned off, and only if it points at this VHDX, so it is ours.
    if (Test-Path -LiteralPath $shortcutPath)
    {
        try
        {
            $probe = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
            if ($probe.TargetPath -eq $vhdFilePath)
            {
                Remove-Item -LiteralPath $shortcutPath -Force
                Write-Info "Desktop shortcuts not requested (environment.create_desktop_shortcuts = false); removed '$shortcutPath'."
            }
            else
            {
                Write-Warn "'$shortcutPath' exists but points at '$($probe.TargetPath)', not at this drive's VHDX. Left alone."
            }
        }
        catch
        {
            Write-Warn ("Could not inspect '{0}', so it was left alone: {1}" -f $shortcutPath, $_.Exception.Message)
        }
    }
    else
    {
        Write-Info "Desktop shortcuts not requested (environment.create_desktop_shortcuts = false); nothing created."
    }
}

Write-Info "STEP 8: OK"

Start-Sleep -Milliseconds 300

# STEP 9: Configure automatic mount at startup
# --------------------------------------------------------------------

Write-Info "STEP 9: Configure automatic mount at startup."

# Named DrivEnv_<label>_<letter>, so two drives with one label do not overwrite each other's task. Renaming is safe
# because the lookup below finds older tasks by the VHDX they mount and unregisters them first.
$taskName = "DrivEnv_{0}_{1}" -f $driveLabel, $driveLetter

# Any task mounting this VHDX belongs to this environment and is replaced.
$ownedTasks = @(Get-DrivEnvMountTaskForVhd -VhdPath $vhdFilePath)

if ($automountAtStartup)
{
    foreach ($existing in $ownedTasks)
    {
        Write-Info ("Replacing the existing mount task '{0}{1}'." -f $existing.TaskPath, $existing.TaskName)
        Unregister-ScheduledTask -TaskName $existing.TaskName -TaskPath $existing.TaskPath -Confirm:$false
    }

    # Mount-DiskImage, not Mount-VHD: the Storage module is always there, the Hyper-V one only where Hyper-V is enabled
    # (a diskpart-built drive on such a PC never mounted at startup).
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -Command `"Mount-DiskImage -ImagePath '$vhdFilePath' -ErrorAction SilentlyContinue`""

    $trigger = New-ScheduledTaskTrigger -AtStartup

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    # Explicit -TaskPath, where the lookup looks; the description names the VHDX for a person reading Task Scheduler.
    Register-ScheduledTask `
        -TaskName $taskName `
        -TaskPath '\' `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Description "DrivEnv-Win automatic mount for $vhdFilePath" `
        -Force | Out-Null

    Write-Info "Registered mount task '$taskName' for '$vhdFilePath'."
}
else
{
    # Removed rather than left running: a task nobody asked for, mounting a drive at every boot, is exactly the
    # kind of thing that survives for years because it is invisible.
    if ($ownedTasks.Count -gt 0)
    {
        foreach ($existing in $ownedTasks)
        {
            Unregister-ScheduledTask -TaskName $existing.TaskName -TaskPath $existing.TaskPath -Confirm:$false
            Write-Info ("Automatic mount not requested (environment.automount_at_startup = false); removed '{0}{1}'." -f $existing.TaskPath, $existing.TaskName)
        }
        Write-Info "This drive will no longer mount by itself. Mount-DiskImage -ImagePath '$vhdFilePath' still works."
    }
    else
    {
        Write-Info "Automatic mount not requested (environment.automount_at_startup = false); nothing registered."
    }
}

Write-Info "STEP 9: OK"

# STEP 10: Hand the drive to its owner
# --------------------------------------------------------------------
# This step runs elevated, so what it created belongs to Administrators; environment.owner says who it should be
# ("current": whoever started the run, passed by the unelevated parent as -OwnerAccount). The tree is small here;
# Generate-DrivEnv.ps1 repeats this over the whole drive after an elevated run.

Write-Info "STEP 10: Hand the drive to its owner (environment.owner)."
try
{
    $ownerArg = Resolve-DrivEnvOwner -Cfg $Cfg -Current $OwnerAccount
    $ownerCode = Set-DrivEnvDriveOwner -Path "${driveLetter}:\" -Owner $ownerArg -Report { param($m) Write-NoFormat $m }
    if ($ownerCode -eq 0) { Write-Info "Drive owned by $ownerArg." } else { Write-Warn "$ownerCode item(s) could not be handed to $ownerArg (see above)." }
}
catch { Write-Warn $_.Exception.Message }
Write-Info "STEP 10: OK"

# FINALIZATION
# --------------------------------------------------------------------

$scriptEnd  = Get-Date
$elapsed    = $scriptEnd - $scriptStart
$elapsedStr = ("{0:hh\:mm\:ss}" -f $elapsed)

Write-Info "DevDrive created successfully at ${driveLetter}:"
Write-Info "TOTAL EXECUTION TIME: $($elapsed.TotalSeconds) seconds  ($elapsedStr)"

# Copy the log before the prompt: in a non-interactive run nothing after it executes.
if (Get-Command Copy-SetupLogToDrive -ErrorAction SilentlyContinue) { Copy-SetupLogToDrive -LogFile $globalLogFile -DriveLetter $driveLetter }

# Same guard as Abort-WithError: ReadKey throws when stdin is redirected. -NoPause: the runner is waiting on this.
if (-not $NoPause -and [Environment]::UserInteractive -and -not [System.Console]::IsInputRedirected) {
    Write-Host ""
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
}
$host.UI.RawUI.WindowTitle = $originalTitle
