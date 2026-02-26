# ====================================================================
# GENERIC WINDOWS DEV DRIVE SETUP SCRIPT
# --------------------------------------------------------------------
# Authors: Ángel Vera Herrera
#          David Abuín Sánchez
# Updated: 18/02/2026
# Version: 1.0.0
# --------------------------------------------------------------------
# License: MIT
# ====================================================================

# FUNCTIONS
# --------------------------------------------------------------------

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
    Write-Host ""
    Write-Host "Press any key to exit..."
    [void][System.Console]::ReadKey($true)
    $host.UI.RawUI.WindowTitle = $originalTitle
    exit 1
}

function Test-IsAdministrator 
{
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal       = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

# CHECK PERMISSIONS
# --------------------------------------------------------------------

if (-not (Test-IsAdministrator))
{
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb      = "runas"   # triggers UAC
    $psi.UseShellExecute = $true

    try
    {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    }
    catch
    {
        Write-Error "Elevation was cancelled or failed."
        Abort-WithError
    }

    exit 0
}

# CONFIGURATION
# --------------------------------------------------------------------

$ConfigPath = Join-Path $PSScriptRoot "generic_dev_drive_env-cfg.json"

if (-not (Test-Path $ConfigPath)) 
{
    Write-Error "Configuration file missing: $ConfigPath"
    Abort-WithError
}

try 
{
    $Cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
} catch 
{
    Write-Error "Invalid JSON in $ConfigPath"
    Abort-WithError 
}

$Global:DevDrive     = $Cfg.environment.driveLetter

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
$vhdIsFixed = [bool]$Cfg.environment.vhd_is_fixed

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
$vhdFilePath     = Join-Path $vhdPath ("{0}.vhdx" -f $driveLabel)
$vhdRoot         = [System.IO.Path]::GetPathRoot($vhdPath)
$setupScriptsDir = Join-Path $scriptDir "scripts_env"

$timestamp       = Get-Date -Format "yyyyMMdd_HHmmss"
$logsDir         = Join-Path $scriptDir "install_logs"
if (-not (Test-Path $logsDir)){New-Item -ItemType Directory -Path $logsDir | Out-Null}
$globalLogFile   = Join-Path $logsDir "${timestamp}_generic_devdrive-setup.log"
$globalLogFileUnix = $globalLogFile -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'

Clear-Host
$originalTitle = $host.UI.RawUI.WindowTitle
$host.UI.RawUI.WindowTitle = "GENERIC WINDOWS DEV DRIVE SETUP SCRIPT"

Write-NoFormat "==========================================================="
Write-NoFormat "  GENERIC WINDOWS DEV DRIVE SETUP SCRIPT"
Write-NoFormat "-----------------------------------------------------------------"
Write-NoFormat "  Authors: Ángel Vera Herrera"
Write-NoFormat "           David Abuín Sánchez"
Write-NoFormat "  Updated: 18/02/2026"
Write-NoFormat "  Version: 1.0.0"
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
if (Get-Volume -driveLetter $driveLetter -ErrorAction SilentlyContinue) {
    Write-Error "Drive letter $driveLetter is already in use."
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

Write-Info "Checking setup scripts folder..."
if (-not (Test-Path $setupScriptsDir)) {
    Write-Error "Setup scripts folder not found at: $setupScriptsDir"
    Abort-WithError
}


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

    Write-Info "Trusting volume as Dev Drive..."
    fsutil devdrv trust "$driveLetter`:" *> $null

    Write-Info "Disabling antivirus for Dev Drive..."
    fsutil devdrv enable /disallowAv *> $null
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

    try {
        if (Get-Command Add-MpPreference -ErrorAction SilentlyContinue) {
            Write-Info "Adding Microsoft Defender exclusion for ${driveLetter}:\ ..."
            Add-MpPreference -ExclusionPath "$driveLetter`:\" 2>$null
        }
        else {
            Write-Info "Microsoft Defender cmdlets not found; skipping AV exclusion."
        }
    }
    catch {
        Write-Error "Could not add Defender exclusion: $_"
    }
}

Write-Info "STEP 4: OK"

Enable-HWDetection

# STEP 5: Reattach (DevDrive only)
# --------------------------------------------------------------------

if ($useDevDrive) {
    Write-Info "STEP 5: Dismount and Reattach DevDrive to apply policies."

    try {
        Write-Info "Dismounting VHDX..."
        Dismount-VHD -Path $vhdFilePath -ErrorAction Stop
        Start-Sleep -Seconds 1

        Write-Info "Re-mounting VHDX..."
        Mount-VHD -Path $vhdFilePath -ErrorAction Stop
    }
    catch {
        Write-Error "Error during Dismount-VHD / Mount-VHD: $_"
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

    Start-Sleep -Milliseconds 200
    Write-Info "STEP 5: OK"
} else {
    Write-Info "STEP 5: Skipped (standard NTFS VHDX - no DevDrive reattach needed)."
}

# STEP 6: Create Workspace Folder Structure
# --------------------------------------------------------------------

Write-Info "STEP 6: Create Workspace Folder Structure."

Write-Info "Creating workspace folder tree inside drive $driveLetter..."

$folders = 
@(
    "${driveLetter}:/buildtrees",
    "${driveLetter}:/deploys",
    "${driveLetter}:/logs/env",
    "${driveLetter}:/env/launcher",
    "${driveLetter}:/env/settings",
    "${driveLetter}:/workspace"
)

foreach ($f in $folders) {
    if (-Not (Test-Path $f)) {
        New-Item -ItemType Directory -Path $f | Out-Null
        Write-Info "Created folder: $f"
    }
}

Write-Info "Copying bash scripts..."

$targetDir   = "${driveLetter}:/env/launcher"
$prefix = $devEnvName.ToLowerInvariant()
$scriptFiles = Get-ChildItem -Path $setupScriptsDir -Filter "*.sh" -File
foreach ($script in $scriptFiles) {
    try 
    {
        $newName  = "{0}_{1}" -f $prefix, $script.Name
        $destPath = Join-Path $targetDir $newName
        Copy-Item -Path $script.FullName -Destination $destPath -Force
        Write-Info "Copied: $newName"
    }
    catch {
        Write-Error "Failed to copy $($script.Name): $_"
        Abort-WithError
    }
}

Write-Info "Copying bat scripts..."

$scriptFiles = Get-ChildItem -Path $setupScriptsDir -Filter "*.bat" -File
foreach ($script in $scriptFiles) 
{
    try 
    {
        $newName  = "{0}_{1}" -f $prefix, $script.Name
        $destPath = Join-Path $targetDir $newName
        Copy-Item -Path $script.FullName -Destination $destPath -Force
        Write-Info "Copied: $newName"
    }
    catch {
        Write-Error "Failed to copy $($script.Name): $_"
        Abort-WithError
    }
}

Write-Info "STEP 6: OK"

# STEP 7: Restore AutoplayHandlers 
# --------------------------------------------------------------------

Write-Info "STEP 7: Restore AutoplayHandlers."
Write-Info "Re-enabling AutoplayHandlers..."
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers" `
                 -Name "DisableAutoplay" -Value 0
Write-Info "STEP 7: OK"

# STEP 8: Setup environment variables and shortcut
# --------------------------------------------------------------------

Write-Info "STEP 8: Setup environment variables and shortcut."

# Env file (lowercase)
$envFilePath = Join-Path "$driveLetter`:" (("env/{0}_env_variables.env" -f $devEnvName).ToLower())

# Normalized drive letter forms
$driveLetterNorm = $driveLetter.Trim().TrimEnd(':')
$driveRootWin    = "${driveLetterNorm}:"
$driveRootUnix   = "${driveLetterNorm}:/"

# Paths (use forward slashes to match your scheme)
$deploysDir    = "${driveRootUnix}deploys"
$workspaceDir  = "${driveRootUnix}workspace"
$buildtreesDir = "${driveRootUnix}buildtrees"

Write-Info "DEVDRIVE_NAME       = $driveLabel"
Write-Info "DEVDRIVE_LETTER     = $driveRootWin"
Write-Info "DEVSYSTEM_NAME      = $devEnvName"
Write-Info "DEVSYSTEM_DEPLOYS   = $deploysDir"
Write-Info "DEVSYSTEM_WORKSPACE = $workspaceDir"
Write-Info "DEVSYSTEM_BUILDTREES= $buildtreesDir"

# Ensure file exists (and overwrite to avoid duplicates)
$envLines = @(
    "DEVDRIVE_NAME=$driveLabel",
    "DEVDRIVE_LETTER=$driveRootWin",
    "DEVSYSTEM_NAME=$devEnvName",
    "DEVSYSTEM_DEPLOYS=$deploysDir",
    "DEVSYSTEM_WORKSPACE=$workspaceDir",
    "DEVSYSTEM_BUILDTREES=$buildtreesDir"
)

Write-Info "Writing environment variables to $envFilePath"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stream    = [System.IO.StreamWriter]::new($envFilePath, $false, $utf8NoBom)  # overwrite
foreach ($line in $envLines) { $stream.WriteLine($line) }
$stream.Close()

Write-Info "Creating shortcut to Dev Drive on desktop..."

$volumeLabel  = $driveLabel
$WshShell     = New-Object -ComObject WScript.Shell
$desktopPath  = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath ("$volumeLabel.lnk")
$shortcut     = $WshShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath   = $vhdFilePath
$shortcut.WindowStyle  = 1
$shortcut.IconLocation = "shell32.dll,8"
$shortcut.Description  = "Shortcut to VHDX image for $volumeLabel"
$shortcut.Save()

Write-Info "Shortcut created: $shortcutPath"
Write-Info "STEP 8: OK"

Start-Sleep -Milliseconds 300

# STEP 9: Configure automatic mount at startup
# --------------------------------------------------------------------

Write-Info "STEP 9: Configure automatic mount at startup."

$taskName = $driveLabel
$taskExists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($taskExists) {
    Write-Info "Scheduled task '$taskName' already exists. Replacing..."
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -Command `"Mount-VHD -Path '$vhdFilePath' -ErrorAction SilentlyContinue`""

$trigger = New-ScheduledTaskTrigger -AtStartup

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Description "Automatically mounts development VHDX at startup." `
    -Force | Out-Null

Write-Info "STEP 9: OK"

# FINALIZATION
# --------------------------------------------------------------------

$scriptEnd  = Get-Date
$elapsed    = $scriptEnd - $scriptStart
$elapsedStr = ("{0:hh\:mm\:ss}" -f $elapsed)

Write-Info "DevDrive created successfully at ${driveLetter}:"
Write-Info "TOTAL EXECUTION TIME: $($elapsed.TotalSeconds) seconds  ($elapsedStr)"

Write-Host ""
Write-Host "Press any key to exit..."
[void][System.Console]::ReadKey($true)
$host.UI.RawUI.WindowTitle = $originalTitle