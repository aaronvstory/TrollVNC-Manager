#Requires -Version 5.1
<#
.SYNOPSIS
    VNC Manager v5.0 - PowerShell Edition
.DESCRIPTION
    Modern iOS VNC connection manager with smart device detection,
    TightVNC/RealVNC support, auto-reconnect, and beautiful CLI interface.
#>

# ============================================================
#  CONFIGURATION
# ============================================================
$Script:Config = @{
    ConfigFile    = Join-Path $PSScriptRoot "device_config.ini"
    LibDir        = Join-Path $PSScriptRoot "lib"
    VncPassword   = ""
    QualityPreset = 3
    VcamMode      = $false
    ViewerPref    = "TightVNC"  # TightVNC or RealVNC
    VerboseMode   = $false
    LogDir        = Join-Path $env:TEMP "VNC_Manager_Logs"
}

$Script:Devices = @{
    1 = @{ UDID = ""; Name = "Device 1"; IP = "0.0.0.0"; Port = 5901 }
    2 = @{ UDID = ""; Name = "Device 2"; IP = "0.0.0.0"; Port = 5902 }
}

# ============================================================
#  CONNECTION STATE (Auto-Reconnect)
# ============================================================
# Initialize connection slots with factory pattern to reduce duplication
$Script:ConnectionSlots = @{}
foreach ($config in @(
    @{ Key = "USB1";  DeviceNum = 1; Mode = "USB" },
    @{ Key = "USB2";  DeviceNum = 2; Mode = "USB" },
    @{ Key = "WiFi1"; DeviceNum = 1; Mode = "WiFi" },
    @{ Key = "WiFi2"; DeviceNum = 2; Mode = "WiFi" }
)) {
    $Script:ConnectionSlots[$config.Key] = @{
        DeviceNum       = $config.DeviceNum
        Mode            = $config.Mode
        AutoReconnect   = $false
        Status          = "Disconnected"
        SupervisorJobId = $null
        StartTime       = $null
        LogPath         = $null
        LastLog         = $null
        LastActive      = $false
    }
}

# Mapping menu keys to slot keys
$Script:SlotKeyMap = @{
    "1" = "USB1"
    "2" = "USB2"
    "3" = "WiFi1"
    "4" = "WiFi2"
}

$Script:QualityPresets = @{
    1 = @{ Name = "Ultra";    TightFlags = "-encoding=tight -jpegimagequality=9 -compressionlevel=1"; RealFlags = "-Quality High -ColorLevel full -AutoReconnect" }
    2 = @{ Name = "High";     TightFlags = "-encoding=tight -jpegimagequality=7 -compressionlevel=3"; RealFlags = "-Quality High -AutoReconnect" }
    3 = @{ Name = "Balanced"; TightFlags = "-encoding=tight -jpegimagequality=5 -compressionlevel=5"; RealFlags = "-Quality Medium -AutoReconnect" }
    4 = @{ Name = "Stable";   TightFlags = "-encoding=tight -jpegimagequality=3 -compressionlevel=7"; RealFlags = "-Quality Low -ColorLevel rgb222 -AutoReconnect" }
    5 = @{ Name = "Minimal";  TightFlags = "-encoding=tight -jpegimagequality=1 -compressionlevel=9"; RealFlags = "-Quality Low -ColorLevel rgb111 -AutoReconnect" }
}

# ============================================================
#  SUPERVISOR JOB (Auto-Reconnect Logic)
# ============================================================
$Script:SupervisorBlock = {
    param(
        [string]$SlotKey,
        [int]$DeviceNum,
        [string]$Mode,
        [string]$UDID,
        [string]$IP,
        [int]$LocalPort,
        [string]$VncExe,
        [string]$VncArgs,
        [string]$IproxyExe,
        [string]$IdeviceIdExe,
        [int]$BaseDelay,
        [int]$MaxDelay,
        [string]$StopFlagPath,
        [string]$LogPath
    )

    $retryCount = 0
    $tunnelProc = $null

    # Helper to write timestamped output
    function Write-Log {
        param($Msg)
        $line = "$(Get-Date -Format 'HH:mm:ss') [$SlotKey] $Msg"
        Write-Output $line
        if ($LogPath) {
            try { Add-Content -Path $LogPath -Value $line } catch { }
        }
    }

    # Helper to calculate exponential backoff delay with jitter (PS 5.1 compatible)
    function Get-RetryDelay {
        param([int]$RetryCount, [int]$Base, [int]$Max)
        $delay = [Math]::Min($Base * [Math]::Pow(2, [Math]::Max(0, $RetryCount - 1)), $Max)
        # Cast to int for Get-Random compatibility with PowerShell 5.1
        $jitterRange = [int][Math]::Floor($delay * 0.2)
        $jitter = if ($jitterRange -gt 0) { Get-Random -Minimum (-$jitterRange) -Maximum ($jitterRange + 1) } else { 0 }
        return [Math]::Max(2, $delay + $jitter)
    }

    Write-Log "Supervisor started"

    while ($true) {
        # ═══════════════════════════════════════════════════════════
        # 1. CHECK STOP FLAG
        # ═══════════════════════════════════════════════════════════
        if (Test-Path $StopFlagPath) {
            Remove-Item $StopFlagPath -Force -ErrorAction SilentlyContinue
            Write-Log "Stop flag detected - exiting"
            break
        }

        # ═══════════════════════════════════════════════════════════
        # 2. CHECK DEVICE AVAILABILITY (USB only)
        # ═══════════════════════════════════════════════════════════
        if ($Mode -eq "USB" -and $UDID) {
            try {
                $devices = & $IdeviceIdExe -l 2>$null
                $deviceFound = $devices -match $UDID
                if (-not $deviceFound) {
                    Write-Log "Device not connected - waiting..."
                    Start-Sleep -Seconds 5
                    continue
                }
            } catch {
                Write-Log "Error checking device: $_"
            }
        }

        # ═══════════════════════════════════════════════════════════
        # 3. START TUNNEL (USB only)
        # ═══════════════════════════════════════════════════════════
        if ($Mode -eq "USB") {
            Write-Log "Starting tunnel on port $LocalPort"

            # Kill any existing iproxy tunnel on this port (only iproxy, not other services)
            Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
                    if ($proc -and $proc.Name -eq "iproxy") {
                        Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
                    }
                }

            Start-Sleep -Milliseconds 500

            # Start iproxy tunnel with error handling
            try {
                if (-not (Test-Path $IproxyExe)) {
                    throw "iproxy.exe not found at: $IproxyExe"
                }
                $tunnelProc = Start-Process -FilePath $IproxyExe `
                    -ArgumentList "-u $UDID $LocalPort 5901" `
                    -WindowStyle Hidden -PassThru
            } catch {
                Write-Log "ERROR: Failed to start iproxy: $_"
                $retryCount++
                $delay = Get-RetryDelay -RetryCount $retryCount -Base $BaseDelay -Max $MaxDelay
                Write-Log "Retry in $([Math]::Round($delay, 1))s (attempt $retryCount)"
                Start-Sleep -Seconds $delay
                continue
            }

            # Wait for tunnel
            $tunnelReady = $false
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Seconds 1
                $listener = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
                if ($listener) {
                    $tunnelReady = $true
                    Write-Log "Tunnel ready"
                    break
                }
            }

            if (-not $tunnelReady) {
                Write-Log "Tunnel failed to start"
                if ($tunnelProc -and -not $tunnelProc.HasExited) {
                    Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
                }
                $retryCount++
                $delay = Get-RetryDelay -RetryCount $retryCount -Base $BaseDelay -Max $MaxDelay
                Write-Log "Retry in $([Math]::Round($delay, 1))s (attempt $retryCount)"
                Start-Sleep -Seconds $delay
                continue
            }
        }

        # ═══════════════════════════════════════════════════════════
        # 4. START VNC VIEWER (blocking wait)
        # ═══════════════════════════════════════════════════════════
        # USB: connect to local tunnel port (5901 for Device 1, 5902 for Device 2)
        # WiFi: connect directly to device VNC server (always port 5901 on iOS)
        $server = if ($Mode -eq "USB") { "localhost:$LocalPort" } else { "${IP}:5901" }
        Write-Log "Connecting viewer to $server"

        $viewerStartTime = Get-Date
        try {
            if (-not (Test-Path $VncExe)) {
                throw "VNC viewer not found at: $VncExe"
            }
            $viewerProc = Start-Process -FilePath $VncExe `
                -ArgumentList "$VncArgs $server" `
                -PassThru -Wait
        } catch {
            Write-Log "ERROR: Viewer failed to start: $_"
            $viewerProc = $null
        }

        $viewerDuration = if ($viewerProc) { (Get-Date) - $viewerStartTime } else { [TimeSpan]::Zero }
        Write-Log "Viewer exited after $([Math]::Round($viewerDuration.TotalSeconds, 1))s"

        # ═══════════════════════════════════════════════════════════
        # 5. CHECK STOP FLAG AGAIN
        # ═══════════════════════════════════════════════════════════
        if (Test-Path $StopFlagPath) {
            Remove-Item $StopFlagPath -Force -ErrorAction SilentlyContinue
            Write-Log "Stop flag detected after viewer exit - exiting"
            if ($tunnelProc -and -not $tunnelProc.HasExited) {
                Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
            }
            break
        }

        # ═══════════════════════════════════════════════════════════
        # 6. CLEANUP TUNNEL
        # ═══════════════════════════════════════════════════════════
        if ($tunnelProc -and -not $tunnelProc.HasExited) {
            Write-Log "Stopping tunnel"
            Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
            $tunnelProc = $null
        }

        # ═══════════════════════════════════════════════════════════
        # 7. CALCULATE RETRY DELAY
        # ═══════════════════════════════════════════════════════════
        if ($viewerDuration.TotalSeconds -gt 30) {
            Write-Log "Connection was stable - resetting retry count"
            $retryCount = 0
        } else {
            $retryCount++
        }

        $actualDelay = Get-RetryDelay -RetryCount $retryCount -Base $BaseDelay -Max $MaxDelay

        Write-Log "Reconnecting in $([Math]::Round($actualDelay, 1))s (attempt $retryCount)"
        Start-Sleep -Seconds $actualDelay
    }

    # Cleanup
    if ($tunnelProc -and -not $tunnelProc.HasExited) {
        Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Log "Supervisor exiting"
}

# ============================================================
#  UI HELPERS
# ============================================================
function Clear-HostSafe {
    try {
        if ($Host -and $Host.UI -and $Host.UI.RawUI) {
            Clear-Host
        }
    } catch {
        # Non-interactive hosts can throw on Clear-Host; ignore.
    }
}

function Start-SupervisorJob {
    param(
        [string]$Name,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList
    )

    $threadJobCmd = Get-Command Start-ThreadJob -ErrorAction SilentlyContinue
    if ($threadJobCmd) {
        return Start-ThreadJob -Name $Name -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    }

    return Start-Job -Name $Name -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Write-Header {
    param([string]$Title, [string]$Subtitle = "")
    Clear-HostSafe
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║" -ForegroundColor Cyan -NoNewline
    Write-Host ("  $Title".PadRight(58)) -ForegroundColor White -NoNewline
    Write-Host "║" -ForegroundColor Cyan
    if ($Subtitle) {
        Write-Host "  ║" -ForegroundColor Cyan -NoNewline
        Write-Host ("  $Subtitle".PadRight(58)) -ForegroundColor DarkGray -NoNewline
        Write-Host "║" -ForegroundColor Cyan
    }
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section {
    param([string]$Title)
    Write-Host "  ┌─ " -ForegroundColor DarkCyan -NoNewline
    Write-Host $Title -ForegroundColor Yellow -NoNewline
    Write-Host " ─────────────────────────────────────────────┐" -ForegroundColor DarkCyan
}

function Write-SectionEnd {
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Status {
    param([string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host "    $Label : " -ForegroundColor Gray -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Write-MenuItem {
    param([string]$Key, [string]$Label, [string]$Extra = "")
    Write-Host "    [" -NoNewline
    Write-Host $Key -ForegroundColor Green -NoNewline
    Write-Host "] " -NoNewline
    Write-Host $Label -ForegroundColor White -NoNewline
    if ($Extra) {
        Write-Host "  $Extra" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
}

function Write-MenuItemWithStatus {
    param(
        [string]$Key,
        [string]$Label,
        [string]$Extra = "",
        [string]$SlotKey = $null
    )

    Write-Host "    [" -NoNewline
    Write-Host $Key -ForegroundColor Green -NoNewline
    Write-Host "] " -NoNewline
    Write-Host $Label -ForegroundColor White -NoNewline

    if ($Extra) {
        Write-Host "  $Extra" -ForegroundColor DarkGray -NoNewline
    }

    if ($SlotKey) {
        $status = Get-SlotStatusIndicator -SlotKey $SlotKey
        Write-Host "  " -NoNewline
        Write-Host $status.Symbol -ForegroundColor $status.Color -NoNewline
        Write-Host " $($status.StatusText)" -ForegroundColor $status.Color -NoNewline

        if ($status.HasAR) {
            Write-Host " [AR]" -ForegroundColor Cyan -NoNewline
        }
    }

    Write-Host ""

    if ($SlotKey -and $Script:Config.VerboseMode) {
        $logLine = $Script:ConnectionSlots[$SlotKey].LastLog
        if ($logLine) {
            $snippet = if ($logLine.Length -gt 90) { $logLine.Substring(0, 90) + "..." } else { $logLine }
            Write-Host "        log: $snippet" -ForegroundColor DarkGray
        }
    }
}

function Write-Success { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Error { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "  → $Msg" -ForegroundColor Cyan }
function Write-Warning { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }

# ============================================================
#  STATUS HELPER FUNCTIONS (Auto-Reconnect)
# ============================================================
function Get-SlotStatusIndicator {
    param([string]$SlotKey)

    $slot = $Script:ConnectionSlots[$SlotKey]

    # Refresh status from job if running
    Update-SlotStatus -SlotKey $SlotKey

    $symbol = switch ($slot.Status) {
        "Connected"      { [char]0x25CF }  # ●
        "ReconnectWait"  { [char]0x25D0 }  # ◐
        "TunnelStarting" { [char]0x25D0 }  # ◐
        "ViewerStarting" { [char]0x25D0 }  # ◐
        "DeviceMissing"  { [char]0x2717 }  # ✗
        "Error"          { [char]0x2717 }  # ✗
        default          { [char]0x25CB }  # ○
    }

    $color = switch ($slot.Status) {
        "Connected"      { "Green" }
        "ReconnectWait"  { "Yellow" }
        "TunnelStarting" { "Yellow" }
        "ViewerStarting" { "Yellow" }
        "DeviceMissing"  { "Red" }
        "Error"          { "Red" }
        default          { "DarkGray" }
    }

    $statusText = switch ($slot.Status) {
        "Connected"      { "Connected" }
        "ReconnectWait"  { "Reconnecting" }
        "TunnelStarting" { "Starting..." }
        "ViewerStarting" { "Starting..." }
        "DeviceMissing"  { "No Device" }
        "Error"          { "Error" }
        default          { "Disconnected" }
    }

    return @{
        Symbol     = $symbol
        Color      = $color
        StatusText = $statusText
        HasAR      = $slot.AutoReconnect
        LastLog    = $slot.LastLog
    }
}

function Update-SlotStatus {
    param([string]$SlotKey)

    $slot = $Script:ConnectionSlots[$SlotKey]

    # If no supervisor job, status is disconnected
    if (-not $slot.SupervisorJobId) {
        if ($slot.Status -notin @("Disconnected", "Error")) {
            $slot.Status = "Disconnected"
        }
        return
    }

    # Check job status
    $job = Get-Job -Id $slot.SupervisorJobId -ErrorAction SilentlyContinue
    if (-not $job) {
        $slot.SupervisorJobId = $null
        $slot.Status = "Disconnected"
        return
    }

    if ($job.State -eq "Completed" -or $job.State -eq "Failed") {
        # Job finished - get output for debugging
        $output = Receive-Job -Id $slot.SupervisorJobId -ErrorAction SilentlyContinue
        Remove-Job -Id $slot.SupervisorJobId -Force -ErrorAction SilentlyContinue
        $slot.SupervisorJobId = $null
        $slot.Status = "Disconnected"
        return
    }

    # Job is running - attempt to infer status
    if (-not $slot.StartTime) {
        $slot.StartTime = Get-Date
    }

    if ($slot.Mode -eq "USB") {
        if (-not (Ensure-ConfigDefaults)) { return }

        $udid = $Script:Devices[$slot.DeviceNum].UDID
        if ($udid) {
            $ideviceId = Join-Path $Script:Config.LibDir "idevice_id.exe"
            if (Test-Path $ideviceId) {
                $devices = & $ideviceId -l 2>$null
                $pattern = [regex]::Escape($udid)
                $matches = if ($devices) { $devices | Where-Object { $_ -match $pattern } } else { @() }
                if ($devices -and -not $matches) {
                    $slot.Status = "DeviceMissing"
                    return
                }
            }
        }

        $listener = Get-NetTCPConnection -LocalPort $Script:Devices[$slot.DeviceNum].Port -State Listen -ErrorAction SilentlyContinue
        if ($listener) {
            $slot.Status = "Connected"
            return
        }
    }

    if ($Script:Config.VerboseMode -and $slot.LogPath -and (Test-Path $slot.LogPath)) {
        try {
            # Use FileStream with ReadWrite sharing to avoid locking issues
            $stream = [System.IO.FileStream]::new($slot.LogPath, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $reader = [System.IO.StreamReader]::new($stream)
            $lines = @()
            while (-not $reader.EndOfStream) {
                $lines += $reader.ReadLine()
            }
            if ($lines.Count -gt 0) {
                $slot.LastLog = $lines[-1].Trim()
            }
            $reader.Close()
            $stream.Close()
        } catch {
            # Fallback to Get-Content if FileStream fails
            $last = Get-Content -Path $slot.LogPath -Tail 1 -ErrorAction SilentlyContinue
            if ($last) { $slot.LastLog = $last.Trim() }
        }
    } elseif (-not $Script:Config.VerboseMode) {
        $slot.LastLog = $null
    }

    $elapsed = (Get-Date) - $slot.StartTime
    if ($elapsed.TotalSeconds -gt 15) {
        $slot.Status = "ReconnectWait"
    } elseif ($slot.Status -eq "Disconnected") {
        $slot.Status = "Connected"
    }
}

function Update-AllSlotStatuses {
    foreach ($slotKey in $Script:ConnectionSlots.Keys) {
        Update-SlotStatus -SlotKey $slotKey
    }
}

# ============================================================
#  SUPERVISED CONNECTION FUNCTIONS
# ============================================================
function Start-SupervisedConnection {
    param(
        [string]$SlotKey
    )

    if (-not (Ensure-ConfigDefaults)) {
        Write-Error "Config defaults not initialized."
        return
    }

    $slot = $Script:ConnectionSlots[$SlotKey]
    $device = $Script:Devices[$slot.DeviceNum]
    $viewer = Get-VncViewer

    if (-not $viewer) {
        Write-Error "No VNC viewer found"
        return
    }

    # Stop any existing connection for this slot
    if ($slot.SupervisorJobId) {
        Stop-SupervisedConnection -SlotKey $SlotKey
    }

    # Create stop flag path
    $stopFlagPath = Join-Path $env:TEMP "vnc_stop_$SlotKey.flag"
    if (Test-Path $stopFlagPath) {
        Remove-Item $stopFlagPath -Force
    }

    # Build arguments
    $logDir = $Script:Config.LogDir
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    $logPath = Join-Path $logDir "supervisor_$SlotKey.log"
    Set-Content -Path $logPath -Value "" -Force

    $jobArgs = @(
        $SlotKey,
        $slot.DeviceNum,
        $slot.Mode,
        $device.UDID,
        $device.IP,
        $device.Port,
        $viewer.Path,
        $viewer.Flags,
        (Join-Path $Script:Config.LibDir "iproxy.exe"),
        (Join-Path $Script:Config.LibDir "idevice_id.exe"),
        2,   # BaseDelay
        60,  # MaxDelay
        $stopFlagPath,
        $logPath
    )

    # Start supervisor job with distinctive name for reliable identification
    $job = Start-SupervisorJob -Name "VNC-Supervisor-$SlotKey" -ScriptBlock $Script:SupervisorBlock -ArgumentList $jobArgs

    # Update state
    $slot.SupervisorJobId = $job.Id
    $slot.Status = if ($slot.Mode -eq "USB") { "TunnelStarting" } else { "ViewerStarting" }
    $slot.StartTime = Get-Date
    $slot.LogPath = $logPath
    $slot.LastLog = $null
    $slot.LastActive = $true
    Export-Config

    Write-Success "Started auto-reconnect for $SlotKey (Job $($job.Id))"
    return
}

function Stop-SupervisedConnection {
    param(
        [string]$SlotKey,
        [switch]$ClearLastActive
    )

    $slot = $Script:ConnectionSlots[$SlotKey]

    # Set stop flag to signal supervisor to exit
    $stopFlagPath = Join-Path $env:TEMP "vnc_stop_$SlotKey.flag"
    Set-Content -Path $stopFlagPath -Value "stop" -Force

    Start-Sleep -Milliseconds 500

    # Stop job
    if ($slot.SupervisorJobId) {
        $job = Get-Job -Id $slot.SupervisorJobId -ErrorAction SilentlyContinue
        if ($job) {
            Stop-Job -Id $slot.SupervisorJobId -ErrorAction SilentlyContinue
            Remove-Job -Id $slot.SupervisorJobId -Force -ErrorAction SilentlyContinue
        }
    }

    # NOTE: We don't kill viewer/tunnel from here. The supervisor job manages its own
    # viewer/tunnel lifecycle. When we set the stop flag, the supervisor will:
    # 1. Detect the flag at its next checkpoint
    # 2. Clean up its tunnel (if USB mode)
    # 3. Exit gracefully
    # The viewer will close when the supervisor stops relaunching it.

    # Reset state
    $slot.SupervisorJobId = $null
    $slot.Status = "Disconnected"
    $slot.StartTime = $null
    $slot.LogPath = $null
    $slot.LastLog = $null
    if ($ClearLastActive) {
        $slot.LastActive = $false
        Export-Config
    }

    Write-Success "Stopped connection for $SlotKey"
}

function Stop-AllSupervisedConnections {
    param([switch]$ClearLastActive)

    foreach ($slotKey in $Script:ConnectionSlots.Keys) {
        $slot = $Script:ConnectionSlots[$slotKey]
        if ($slot.SupervisorJobId) {
            Stop-SupervisedConnection -SlotKey $slotKey -ClearLastActive:$ClearLastActive
        }
    }

    if ($ClearLastActive) {
        foreach ($slotKey in $Script:ConnectionSlots.Keys) {
            $Script:ConnectionSlots[$slotKey].LastActive = $false
        }
        Export-Config
    }
}

# ============================================================
#  DEVICE MANAGEMENT
# ============================================================
function Get-ConnectedDevices {
    if (-not (Ensure-ConfigDefaults)) { return @() }
    if (-not $Script:Config.LibDir) { return @() }

    $ideviceId = Join-Path $Script:Config.LibDir "idevice_id.exe"
    $ideviceInfo = Join-Path $Script:Config.LibDir "ideviceinfo.exe"

    if (-not (Test-Path $ideviceId)) {
        if ($Script:Config.VerboseMode) {
            Write-Warning "idevice_id.exe not found in lib/ - libimobiledevice tools may be missing"
        }
        return @()
    }

    $udids = & $ideviceId -l 2>$null
    if (-not $udids) { return @() }

    $devices = @()
    foreach ($udid in $udids) {
        $udid = $udid.Trim()
        if (-not $udid) { continue }

        $device = @{
            UDID = $udid
            Name = "Unknown"
            Model = "Unknown"
            iOS = "Unknown"
            Paired = $false
        }

        if (Test-Path $ideviceInfo) {
            $name = & $ideviceInfo -u $udid -k DeviceName 2>$null
            $model = & $ideviceInfo -u $udid -k ProductType 2>$null
            $ios = & $ideviceInfo -u $udid -k ProductVersion 2>$null

            if ($name) { $device.Name = $name.Trim() }
            if ($model) { $device.Model = $model.Trim() }
            if ($ios) { $device.iOS = $ios.Trim() }
            $device.Paired = ($name -ne $null -and $name -ne "")
        }

        $devices += $device
    }

    return $devices
}

function Invoke-DevicePair {
    param([string]$UDID)

    if (-not (Ensure-ConfigDefaults)) { return $false }
    if (-not $Script:Config.LibDir) { return $false }

    $idevicePair = Join-Path $Script:Config.LibDir "idevicepair.exe"
    if (-not (Test-Path $idevicePair)) {
        Write-Error "idevicepair.exe not found"
        return $false
    }

    Write-Info "Triggering trust dialog on device..."
    Write-Warning "Please tap 'Trust' on the device screen!"

    $result = & $idevicePair -u $UDID pair 2>&1

    if ($result -match "SUCCESS") {
        Write-Success "Device paired successfully!"
        return $true
    } elseif ($result -match "trust dialog") {
        Write-Warning "Trust dialog shown - tap 'Trust' on device, then try again"
        return $false
    } else {
        Write-Error "Pairing failed: $result"
        return $false
    }
}

function Invoke-DeviceValidate {
    param([string]$UDID)

    if (-not (Ensure-ConfigDefaults)) { return $false }
    if (-not $Script:Config.LibDir) { return $false }

    $idevicePair = Join-Path $Script:Config.LibDir "idevicepair.exe"
    if (-not (Test-Path $idevicePair)) { return $false }

    $result = & $idevicePair -u $UDID validate 2>&1
    return $result -match "SUCCESS"
}

# ============================================================
#  CONFIG MANAGEMENT
# ============================================================
function Get-ScriptRootSafe {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($PSCommandPath) { return (Split-Path -Parent $PSCommandPath) }
    return $PWD.Path
}

function Ensure-ConfigDefaults {
    if (-not $Script:Config) { $Script:Config = @{} }

    $root = Get-ScriptRootSafe
    if (-not $root) { return $false }

    if (-not $Script:Config.ConfigFile) { $Script:Config.ConfigFile = Join-Path $root "device_config.ini" }
    if (-not $Script:Config.LibDir) { $Script:Config.LibDir = Join-Path $root "lib" }

    if ($null -eq $Script:Config.VncPassword) { $Script:Config.VncPassword = "test1234" }
    if ($null -eq $Script:Config.QualityPreset) { $Script:Config.QualityPreset = 3 }
    if ($null -eq $Script:Config.ViewerPref) { $Script:Config.ViewerPref = "TightVNC" }
    if ($null -eq $Script:Config.VcamMode) { $Script:Config.VcamMode = $false }
    if ($null -eq $Script:Config.VerboseMode) { $Script:Config.VerboseMode = $false }
    if (-not $Script:Config.LogDir) {
        $tempRoot = if ($env:TEMP) { $env:TEMP } elseif ($env:TMP) { $env:TMP } else { $root }
        $Script:Config.LogDir = Join-Path $tempRoot "VNC_Manager_Logs"
    }

    return $true
}

function Get-ConfigPath {
    if (-not (Ensure-ConfigDefaults)) { return $null }
    return $Script:Config.ConfigFile
}

function Import-Config {
    $configPath = Get-ConfigPath
    if (-not $configPath) { return }
    if (-not (Test-Path $configPath)) { return }

    Get-Content $configPath | ForEach-Object {
        if ($_ -match "^(\w+)=(.*)$") {
            $key = $Matches[1]
            $value = $Matches[2]

            switch ($key) {
                "UDID1" { $Script:Devices[1].UDID = $value }
                "NAME1" { $Script:Devices[1].Name = $value }
                "IP1"   { $Script:Devices[1].IP = $value }
                "UDID2" { $Script:Devices[2].UDID = $value }
                "NAME2" { $Script:Devices[2].Name = $value }
                "IP2"   { $Script:Devices[2].IP = $value }
                "VNC_PASSWORD"   { $Script:Config.VncPassword = $value }
                "QUALITY_PRESET" { $Script:Config.QualityPreset = [int]$value }
                "VCAM_MODE"      { $Script:Config.VcamMode = $value -eq "1" }
                "VERBOSE_MODE"   { $Script:Config.VerboseMode = $value -eq "1" }
                "VIEWER_PREF"    { $Script:Config.ViewerPref = if ($value -eq "2") { "RealVNC" } else { "TightVNC" } }
                "AUTORECONNECT_USB1"  { $Script:ConnectionSlots["USB1"].AutoReconnect = $value -eq "1" }
                "AUTORECONNECT_USB2"  { $Script:ConnectionSlots["USB2"].AutoReconnect = $value -eq "1" }
                "AUTORECONNECT_WIFI1" { $Script:ConnectionSlots["WiFi1"].AutoReconnect = $value -eq "1" }
                "AUTORECONNECT_WIFI2" { $Script:ConnectionSlots["WiFi2"].AutoReconnect = $value -eq "1" }
                "LAST_ACTIVE_USB1"    { $Script:ConnectionSlots["USB1"].LastActive = $value -eq "1" }
                "LAST_ACTIVE_USB2"    { $Script:ConnectionSlots["USB2"].LastActive = $value -eq "1" }
                "LAST_ACTIVE_WIFI1"   { $Script:ConnectionSlots["WiFi1"].LastActive = $value -eq "1" }
                "LAST_ACTIVE_WIFI2"   { $Script:ConnectionSlots["WiFi2"].LastActive = $value -eq "1" }
            }
        }
    }
}

function Export-Config {
    $configPath = Get-ConfigPath
    if (-not $configPath) {
        Write-Warning "Config path not set; skipping save."
        return
    }

    $viewerNum = if ($Script:Config.ViewerPref -eq "RealVNC") { "2" } else { "1" }
    $vcamNum = if ($Script:Config.VcamMode) { "1" } else { "0" }
    $verboseNum = if ($Script:Config.VerboseMode) { "1" } else { "0" }

    # Auto-reconnect values
    $arUsb1 = if ($Script:ConnectionSlots["USB1"].AutoReconnect) { "1" } else { "0" }
    $arUsb2 = if ($Script:ConnectionSlots["USB2"].AutoReconnect) { "1" } else { "0" }
    $arWifi1 = if ($Script:ConnectionSlots["WiFi1"].AutoReconnect) { "1" } else { "0" }
    $arWifi2 = if ($Script:ConnectionSlots["WiFi2"].AutoReconnect) { "1" } else { "0" }
    $laUsb1 = if ($Script:ConnectionSlots["USB1"].LastActive) { "1" } else { "0" }
    $laUsb2 = if ($Script:ConnectionSlots["USB2"].LastActive) { "1" } else { "0" }
    $laWifi1 = if ($Script:ConnectionSlots["WiFi1"].LastActive) { "1" } else { "0" }
    $laWifi2 = if ($Script:ConnectionSlots["WiFi2"].LastActive) { "1" } else { "0" }

    @"
UDID1=$($Script:Devices[1].UDID)
NAME1=$($Script:Devices[1].Name)
IP1=$($Script:Devices[1].IP)
UDID2=$($Script:Devices[2].UDID)
NAME2=$($Script:Devices[2].Name)
IP2=$($Script:Devices[2].IP)
VNC_PASSWORD=$($Script:Config.VncPassword)
QUALITY_PRESET=$($Script:Config.QualityPreset)
VCAM_MODE=$vcamNum
VERBOSE_MODE=$verboseNum
VIEWER_PREF=$viewerNum
AUTORECONNECT_USB1=$arUsb1
AUTORECONNECT_USB2=$arUsb2
AUTORECONNECT_WIFI1=$arWifi1
AUTORECONNECT_WIFI2=$arWifi2
LAST_ACTIVE_USB1=$laUsb1
LAST_ACTIVE_USB2=$laUsb2
LAST_ACTIVE_WIFI1=$laWifi1
LAST_ACTIVE_WIFI2=$laWifi2
"@ | Out-String | ForEach-Object {
    $tempPath = "$configPath.tmp"
    Set-Content -Path $tempPath -Value $_ -Encoding UTF8
    Move-Item -Path $tempPath -Destination $configPath -Force
}
}

# ============================================================
#  VNC VIEWERS
# ============================================================
function Get-VncViewer {
    if (-not (Ensure-ConfigDefaults)) { return $null }

    $tightPaths = @(
        "C:\Program Files\TightVNC\tvnviewer.exe"
        "C:\Program Files (x86)\TightVNC\tvnviewer.exe"
    )
    $realPaths = @(
        "C:\Program Files\RealVNC\VNC Viewer\vncviewer.exe"
        "C:\Program Files (x86)\RealVNC\VNC Viewer\vncviewer.exe"
    )

    $tightExe = $tightPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    $realExe = $realPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($Script:Config.ViewerPref -eq "RealVNC" -and $realExe) {
        return @{ Path = $realExe; Name = "RealVNC"; Flags = $Script:QualityPresets[$Script:Config.QualityPreset].RealFlags }
    } elseif ($tightExe) {
        return @{ Path = $tightExe; Name = "TightVNC"; Flags = $Script:QualityPresets[$Script:Config.QualityPreset].TightFlags }
    } elseif ($realExe) {
        return @{ Path = $realExe; Name = "RealVNC"; Flags = $Script:QualityPresets[$Script:Config.QualityPreset].RealFlags }
    }

    return $null
}

function Switch-Viewer {
    if ($Script:Config.ViewerPref -eq "TightVNC") {
        $Script:Config.ViewerPref = "RealVNC"
    } else {
        $Script:Config.ViewerPref = "TightVNC"
    }
    Export-Config
    Write-Success "Switched to $($Script:Config.ViewerPref)"
}

# ============================================================
#  TUNNEL MANAGEMENT
# ============================================================
function Get-TunnelStatus {
    $status = @{ Port5901 = $false; Port5902 = $false }

    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
    $status.Port5901 = ($listeners | Where-Object { $_.LocalPort -eq 5901 }) -ne $null
    $status.Port5902 = ($listeners | Where-Object { $_.LocalPort -eq 5902 }) -ne $null

    return $status
}

function Stop-Tunnel {
    param([int]$Port)

    # Only kill iproxy processes on the specified port, not other services
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.Name -eq "iproxy") {
                Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
            }
        }
}

function Stop-AllTunnels {
    param([switch]$ClearLastActive)
    Write-Info "Stopping all tunnels and connections..."

    # First stop all supervised connections (gracefully)
    Stop-AllSupervisedConnections -ClearLastActive:$ClearLastActive

    # Then force-kill any remaining processes
    Stop-Tunnel 5901
    Stop-Tunnel 5902
    Stop-Process -Name tvnviewer -Force -ErrorAction SilentlyContinue
    Stop-Process -Name vncviewer -Force -ErrorAction SilentlyContinue

    # Don't kill ALL iproxy - only ones on our ports (handled by Stop-Tunnel)

    Write-Success "All tunnels stopped"
}

function Start-Tunnel {
    param([string]$UDID, [int]$LocalPort, [int]$RemotePort = 5901)

    if (-not (Ensure-ConfigDefaults)) {
        Write-Error "Config defaults not initialized."
        return $false
    }

    $iproxy = Join-Path $Script:Config.LibDir "iproxy.exe"
    if (-not (Test-Path $iproxy)) {
        Write-Error "iproxy.exe not found in lib folder"
        return $false
    }

    if (-not $Script:Config.VcamMode) {
        Stop-Tunnel $LocalPort
    }

    Start-Process -FilePath $iproxy -ArgumentList "-u $UDID $LocalPort $RemotePort" -WindowStyle Minimized

    # Wait for tunnel
    $timeout = 10
    for ($i = 0; $i -lt $timeout; $i++) {
        Start-Sleep -Seconds 1
        $listener = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
        if ($listener) {
            Write-Success "Tunnel ready on port $LocalPort"
            return $true
        }
    }

    Write-Error "Tunnel timeout on port $LocalPort"
    return $false
}

function Connect-VNC {
    param([string]$Server, [int]$Port = 5901)

    $viewer = Get-VncViewer
    if (-not $viewer) {
        Write-Error "No VNC viewer found. Install TightVNC or RealVNC."
        Write-Host "    TightVNC: https://www.tightvnc.com/download.php" -ForegroundColor DarkGray
        Write-Host "    RealVNC:  https://www.realvnc.com/en/connect/download/viewer/" -ForegroundColor DarkGray
        return
    }

    Write-Info "Connecting via $($viewer.Name) to ${Server}:${Port}..."
    $args = "$($viewer.Flags) ${Server}:${Port}"
    Start-Process -FilePath $viewer.Path -ArgumentList $args
}

# ============================================================
#  CONNECTION FUNCTIONS
# ============================================================
function Connect-USB {
    param([int]$DeviceNum)

    $device = $Script:Devices[$DeviceNum]
    if (-not $device.UDID) {
        Write-Error "Device $DeviceNum not configured"
        return
    }

    Write-Info "Connecting to $($device.Name) via USB..."

    if (Start-Tunnel -UDID $device.UDID -LocalPort $device.Port) {
        Connect-VNC -Server "localhost" -Port $device.Port
    }
}

function Connect-WiFi {
    param([int]$DeviceNum)

    $device = $Script:Devices[$DeviceNum]
    if ($device.IP -eq "0.0.0.0") {
        Write-Error "$($device.Name) WiFi not configured"
        return
    }

    Write-Info "Connecting to $($device.Name) via WiFi ($($device.IP))..."
    Connect-VNC -Server $device.IP -Port 5901
}

function Connect-BothUSB {
    foreach ($slotKey in @("USB1", "USB2")) {
        Connect-Slot -SlotKey $slotKey
        Start-Sleep -Milliseconds 500
    }
}

function Connect-BothWiFi {
    foreach ($slotKey in @("WiFi1", "WiFi2")) {
        Connect-Slot -SlotKey $slotKey
        Start-Sleep -Milliseconds 500
    }
}

function Connect-Slot {
    param([string]$SlotKey)

    $slot = $Script:ConnectionSlots[$SlotKey]
    $device = $Script:Devices[$slot.DeviceNum]

    # Validation
    if ($slot.Mode -eq "USB" -and -not $device.UDID) {
        Write-Error "Device $($slot.DeviceNum) not configured (no UDID)"
        Start-Sleep -Seconds 2
        return
    }

    if ($slot.Mode -eq "WiFi" -and $device.IP -eq "0.0.0.0") {
        Write-Error "$($device.Name) WiFi not configured"
        Start-Sleep -Seconds 2
        return
    }

    Write-Info "Connecting $SlotKey ($($device.Name) via $($slot.Mode))..."

    if ($slot.AutoReconnect) {
        # Use supervised connection
        Start-SupervisedConnection -SlotKey $SlotKey
    } else {
        # Use original connection method (no auto-reconnect)
        if ($slot.Mode -eq "USB") {
            Connect-USB -DeviceNum $slot.DeviceNum
        } else {
            Connect-WiFi -DeviceNum $slot.DeviceNum
        }
        $slot.LastActive = $true
        Export-Config
    }
}

function Reconnect-AllWithAR {
    Write-Info "Reconnecting all slots with Auto-Reconnect enabled..."

    $reconnected = 0
    $skipped = 0

    foreach ($slotKey in $Script:ConnectionSlots.Keys) {
        $slot = $Script:ConnectionSlots[$slotKey]
        if ($slot.AutoReconnect) {
            $device = $Script:Devices[$slot.DeviceNum]

            # Validate configuration before starting supervisor
            if ($slot.Mode -eq "USB" -and -not $device.UDID) {
                Write-Warning "Skipping $slotKey - Device $($slot.DeviceNum) not configured (no UDID)"
                $skipped++
                continue
            }

            if ($slot.Mode -eq "WiFi" -and $device.IP -eq "0.0.0.0") {
                Write-Warning "Skipping $slotKey - $($device.Name) WiFi not configured"
                $skipped++
                continue
            }

            Write-Info "Reconnecting $slotKey..."
            Start-SupervisedConnection -SlotKey $slotKey
            $reconnected++
            Start-Sleep -Milliseconds 500
        }
    }

    if ($reconnected -gt 0) {
        Write-Success "Reconnect initiated for $reconnected AR-enabled slot(s)"
    }
    if ($skipped -gt 0) {
        Write-Warning "Skipped $skipped slot(s) due to missing configuration"
    }
    Start-Sleep -Seconds 1
}

# ============================================================
#  DEVICE SCANNER UI
# ============================================================
function Show-DeviceScanner {
    Write-Header "DEVICE SCANNER" "Detecting connected iOS devices..."

    Write-Info "Scanning USB devices..."
    $devices = Get-ConnectedDevices

    if ($devices.Count -eq 0) {
        Write-Warning "No devices found. Check USB connections."
        Read-Host "  Press Enter to continue"
        return
    }

    Write-Host ""
    Write-Section "CONNECTED DEVICES"
    Write-Host ""

    $i = 1
    foreach ($device in $devices) {
        $pairStatus = if ($device.Paired) { "✓ Paired" } else { "○ Not Paired" }
        $pairColor = if ($device.Paired) { "Green" } else { "Yellow" }

        Write-Host "    [$i] " -NoNewline -ForegroundColor Green
        Write-Host $device.Name -ForegroundColor White
        Write-Host "        Model: " -ForegroundColor Gray -NoNewline
        Write-Host $device.Model -ForegroundColor Cyan
        Write-Host "        iOS:   " -ForegroundColor Gray -NoNewline
        Write-Host $device.iOS -ForegroundColor Cyan
        Write-Host "        UDID:  " -ForegroundColor Gray -NoNewline
        Write-Host $device.UDID -ForegroundColor DarkGray
        Write-Host "        Status:" -ForegroundColor Gray -NoNewline
        Write-Host " $pairStatus" -ForegroundColor $pairColor
        Write-Host ""
        $i++
    }

    Write-SectionEnd

    Write-Host "    [P] Pair a device    [A] Auto-assign to slots    [B] Back" -ForegroundColor Gray
    Write-Host ""

    $choice = Read-Host "  Select"

    switch ($choice.ToUpper()) {
        "P" {
            $devNum = Read-Host "  Enter device number to pair"
            if ($devNum -ge 1 -and $devNum -le $devices.Count) {
                Invoke-DevicePair -UDID $devices[$devNum - 1].UDID
            }
            Read-Host "  Press Enter to continue"
        }
        "A" {
            if ($devices.Count -ge 1) {
                $Script:Devices[1].UDID = $devices[0].UDID
                $Script:Devices[1].Name = $devices[0].Name
                Write-Success "Slot 1: $($devices[0].Name)"
            }
            if ($devices.Count -ge 2) {
                $Script:Devices[2].UDID = $devices[1].UDID
                $Script:Devices[2].Name = $devices[1].Name
                Write-Success "Slot 2: $($devices[1].Name)"
            }
            Export-Config
            Read-Host "  Press Enter to continue"
        }
    }
}

# ============================================================
#  QUALITY MENU
# ============================================================
function Show-QualityMenu {
    Write-Header "QUALITY SETTINGS"

    Write-Section "PRESETS"
    Write-Host ""

    foreach ($key in 1..5) {
        $preset = $Script:QualityPresets[$key]
        $marker = if ($key -eq $Script:Config.QualityPreset) { " ◄" } else { "" }
        $color = if ($key -eq $Script:Config.QualityPreset) { "Green" } else { "White" }

        Write-Host "    [$key] " -NoNewline -ForegroundColor Green
        Write-Host "$($preset.Name)$marker" -ForegroundColor $color
    }

    Write-Host ""
    Write-SectionEnd

    Write-Host "    [B] Back" -ForegroundColor Gray
    Write-Host ""

    $choice = Read-Host "  Select quality"

    if ($choice -match "^[1-5]$") {
        $Script:Config.QualityPreset = [int]$choice
        Export-Config
        Write-Success "Quality set to $($Script:QualityPresets[$choice].Name)"
        Start-Sleep -Seconds 1
    }
}

# ============================================================
#  AUTO-RECONNECT MENU
# ============================================================
function Show-AutoReconnectMenu {
    while ($true) {
        Write-Header "AUTO-RECONNECT SETTINGS"

        Write-Section "TOGGLE PER SLOT"
        Write-Host ""

        foreach ($key in @("1", "2", "3", "4")) {
            $slotKey = $Script:SlotKeyMap[$key]
            $slot = $Script:ConnectionSlots[$slotKey]
            $device = $Script:Devices[$slot.DeviceNum]
            $arStatus = if ($slot.AutoReconnect) { "ON  $([char]0x2713)" } else { "OFF" }
            $arColor = if ($slot.AutoReconnect) { "Green" } else { "DarkGray" }

            $label = if ($slot.Mode -eq "USB") {
                "USB  $($device.Name)"
            } else {
                "WiFi $($device.Name)"
            }

            Write-Host "    [$key] " -NoNewline
            Write-Host $label.PadRight(25) -ForegroundColor White -NoNewline
            Write-Host $arStatus -ForegroundColor $arColor
        }

        Write-Host ""
        Write-SectionEnd

        Write-MenuItem "A" "Toggle ALL"
        Write-MenuItem "C" "Clear Auto-Start Memory"
        Write-MenuItem "B" "Back"
        Write-Host ""

        $choice = Read-Host "  Select slot to toggle"

        # Use SlotKeyMap for slot selection (data-driven instead of switch)
        if ($Script:SlotKeyMap.ContainsKey($choice)) {
            Toggle-AutoReconnect -SlotKey $Script:SlotKeyMap[$choice]
        } else {
            switch ($choice.ToUpper()) {
                "A" {
                    $allOn = ($Script:ConnectionSlots.Values | Where-Object { $_.AutoReconnect }).Count -eq 4
                    $newValue = -not $allOn
                    foreach ($slotKey in $Script:ConnectionSlots.Keys) {
                        $Script:ConnectionSlots[$slotKey].AutoReconnect = $newValue
                    }
                    Export-Config
                    $status = if ($newValue) { "ON" } else { "OFF" }
                    Write-Success "All auto-reconnect set to $status"
                    Start-Sleep -Seconds 1
                }
                "C" {
                    foreach ($slotKey in $Script:ConnectionSlots.Keys) {
                        $Script:ConnectionSlots[$slotKey].LastActive = $false
                    }
                    Export-Config
                    Write-Success "Cleared auto-start memory for all slots"
                    Start-Sleep -Seconds 1
                }
                "B" { return }
            }
        }
    }
}

function Toggle-AutoReconnect {
    param([string]$SlotKey)

    $slot = $Script:ConnectionSlots[$SlotKey]
    $slot.AutoReconnect = -not $slot.AutoReconnect
    Export-Config

    $status = if ($slot.AutoReconnect) { "ON" } else { "OFF" }
    Write-Success "$SlotKey auto-reconnect: $status"

    # If turning ON and already connected, start supervisor
    if ($slot.AutoReconnect -and $slot.Status -eq "Connected") {
        Write-Info "Starting supervisor for existing connection..."
        Start-SupervisedConnection -SlotKey $SlotKey
    }

    # If turning OFF, stop supervisor but leave connection
    if (-not $slot.AutoReconnect -and $slot.SupervisorJobId) {
        Write-Info "Stopping supervisor (connection remains)..."
        # Just stop the job, don't kill the viewer
        $stopFlagPath = Join-Path $env:TEMP "vnc_stop_$SlotKey.flag"
        Set-Content -Path $stopFlagPath -Value "stop" -Force
    }
    if (-not $slot.AutoReconnect) {
        $slot.LastActive = $false
        Export-Config
    }

    Start-Sleep -Seconds 1
}

# ============================================================
#  SETTINGS MENU
# ============================================================
function Show-SettingsMenu {
    $qualityName = $Script:QualityPresets[$Script:Config.QualityPreset].Name
    $vcamStr = if ($Script:Config.VcamMode) { "ON" } else { "OFF" }

    while ($true) {
        $qualityName = $Script:QualityPresets[$Script:Config.QualityPreset].Name
        $vcamStr = if ($Script:Config.VcamMode) { "ON" } else { "OFF" }

        Write-Header "SETTINGS" "Device configuration & preferences"

        # Current Status
        Write-Host "    Viewer: " -ForegroundColor Gray -NoNewline
        Write-Host $Script:Config.ViewerPref -ForegroundColor Cyan -NoNewline
        Write-Host "   Quality: " -ForegroundColor Gray -NoNewline
        Write-Host $qualityName -ForegroundColor Cyan -NoNewline
        Write-Host "   vCam: " -ForegroundColor Gray -NoNewline
        Write-Host $vcamStr -ForegroundColor $(if ($Script:Config.VcamMode) { "Green" } else { "DarkGray" })
        Write-Host ""

        # Device 1
        Write-Section "$($Script:Devices[1].Name)"
        Write-Host ""
        Write-MenuItem "1" "WiFi IP" "($($Script:Devices[1].IP))"
        Write-MenuItem "3" "Rename" ""
        Write-Host "        UDID: $($Script:Devices[1].UDID)" -ForegroundColor DarkGray
        Write-Host ""
        Write-SectionEnd

        # Device 2
        Write-Section "$($Script:Devices[2].Name)"
        Write-Host ""
        Write-MenuItem "2" "WiFi IP" "($($Script:Devices[2].IP))"
        Write-MenuItem "4" "Rename" ""
        Write-Host "        UDID: $($Script:Devices[2].UDID)" -ForegroundColor DarkGray
        Write-Host ""
        Write-SectionEnd

        # Tools & Preferences
        Write-Section "TOOLS & PREFERENCES"
        Write-Host ""
        Write-MenuItem "S" "Scan Devices" "(detect & pair)"
        Write-MenuItem "Q" "Quality Preset" "($qualityName)"
        Write-MenuItem "C" "vCam Mode" "($vcamStr)"
        Write-MenuItem "V" "Switch Viewer" "($($Script:Config.ViewerPref))"
        Write-MenuItem "P" "VNC Password" ""
        Write-MenuItem "L" "Verbose Logs" "($(if ($Script:Config.VerboseMode) { 'ON' } else { 'OFF' }))"
        Write-Host ""
        Write-SectionEnd

        Write-MenuItem "B" "Back to Main Menu" ""
        Write-Host ""

        $choice = Read-Host "  Select"

        switch ($choice.ToUpper()) {
            "1" {
                $newIP = Read-Host "  Enter WiFi IP for $($Script:Devices[1].Name)"
                if ($newIP -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
                    $Script:Devices[1].IP = $newIP
                    Export-Config
                    Write-Success "WiFi IP set to $newIP"
                } else {
                    Write-Error "Invalid IP format (e.g., 192.168.1.100)"
                }
                Start-Sleep -Seconds 1
            }
            "2" {
                $newIP = Read-Host "  Enter WiFi IP for $($Script:Devices[2].Name)"
                if ($newIP -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
                    $Script:Devices[2].IP = $newIP
                    Export-Config
                    Write-Success "WiFi IP set to $newIP"
                } else {
                    Write-Error "Invalid IP format (e.g., 192.168.1.100)"
                }
                Start-Sleep -Seconds 1
            }
            "3" {
                $newName = Read-Host "  Enter new name for Device 1"
                if ($newName) {
                    $Script:Devices[1].Name = $newName
                    Export-Config
                    Write-Success "Device renamed to $newName"
                }
                Start-Sleep -Seconds 1
            }
            "4" {
                $newName = Read-Host "  Enter new name for Device 2"
                if ($newName) {
                    $Script:Devices[2].Name = $newName
                    Export-Config
                    Write-Success "Device renamed to $newName"
                }
                Start-Sleep -Seconds 1
            }
            "S" { Show-DeviceScanner }
            "Q" { Show-QualityMenu }
            "C" {
                $Script:Config.VcamMode = -not $Script:Config.VcamMode
                Export-Config
                Write-Success "vCam Mode: $(if ($Script:Config.VcamMode) { 'ON' } else { 'OFF' })"
                Start-Sleep -Seconds 1
            }
            "V" {
                Switch-Viewer
                Start-Sleep -Seconds 1
            }
            "P" {
                $newPass = Read-Host "  Enter new VNC password"
                if ($newPass) {
                    $Script:Config.VncPassword = $newPass
                    Export-Config
                    Write-Success "VNC password updated"
                }
                Start-Sleep -Seconds 1
            }
            "L" {
                $Script:Config.VerboseMode = -not $Script:Config.VerboseMode
                Export-Config
                Write-Success "Verbose Logs: $(if ($Script:Config.VerboseMode) { 'ON' } else { 'OFF' })"
                Start-Sleep -Seconds 1
            }
            "B" { return }
        }
    }
}

# ============================================================
#  MAIN MENU
# ============================================================
function Show-MainMenu {
    # Refresh all statuses
    Update-AllSlotStatuses

    $tunnels = Get-TunnelStatus
    $tunnelStr = if ($tunnels.Port5901 -and $tunnels.Port5902) { "Both" }
                 elseif ($tunnels.Port5901) { "5901" }
                 elseif ($tunnels.Port5902) { "5902" }
                 else { "None" }
    $tunnelColor = if ($tunnelStr -eq "None") { "DarkGray" } else { "Green" }

    $qualityName = $Script:QualityPresets[$Script:Config.QualityPreset].Name
    $vcamStr = if ($Script:Config.VcamMode) { "ON" } else { "OFF" }
    $vcamColor = if ($Script:Config.VcamMode) { "Green" } else { "DarkGray" }
    $verboseStr = if ($Script:Config.VerboseMode) { "ON" } else { "OFF" }
    $verboseColor = if ($Script:Config.VerboseMode) { "Green" } else { "DarkGray" }

    Write-Header "VNC MANAGER v5.0" "PowerShell Edition + Auto-Reconnect"

    # Status bar
    Write-Host "    Viewer: " -ForegroundColor Gray -NoNewline
    Write-Host $Script:Config.ViewerPref -ForegroundColor Cyan -NoNewline
    Write-Host "   Quality: " -ForegroundColor Gray -NoNewline
    Write-Host $qualityName -ForegroundColor Cyan -NoNewline
    Write-Host "   Tunnels: " -ForegroundColor Gray -NoNewline
    Write-Host $tunnelStr -ForegroundColor $tunnelColor -NoNewline
    Write-Host "   vCam: " -ForegroundColor Gray -NoNewline
    Write-Host $vcamStr -ForegroundColor $vcamColor -NoNewline
    Write-Host "   Verbose: " -ForegroundColor Gray -NoNewline
    Write-Host $verboseStr -ForegroundColor $verboseColor
    Write-Host ""

    # USB Connections
    Write-Section "USB"
    Write-Host ""
    Write-MenuItemWithStatus -Key "1" -Label $Script:Devices[1].Name -Extra ":$($Script:Devices[1].Port)" -SlotKey "USB1"
    Write-MenuItemWithStatus -Key "2" -Label $Script:Devices[2].Name -Extra ":$($Script:Devices[2].Port)" -SlotKey "USB2"
    Write-MenuItem "B" "Both USB"
    Write-Host ""
    Write-SectionEnd

    # WiFi Connections
    $wifi1Str = if ($Script:Devices[1].IP -eq "0.0.0.0") { "(not set)" } else { "($($Script:Devices[1].IP))" }
    $wifi2Str = if ($Script:Devices[2].IP -eq "0.0.0.0") { "(not set)" } else { "($($Script:Devices[2].IP))" }

    Write-Section "WIFI"
    Write-Host ""
    Write-MenuItemWithStatus -Key "3" -Label $Script:Devices[1].Name -Extra $wifi1Str -SlotKey "WiFi1"
    Write-MenuItemWithStatus -Key "4" -Label $Script:Devices[2].Name -Extra $wifi2Str -SlotKey "WiFi2"
    Write-MenuItem "W" "Both WiFi"
    Write-Host ""
    Write-SectionEnd

    # Auto-Reconnect Section
    Write-Section "AUTO-RECONNECT"
    Write-Host ""
    Write-MenuItem "A" "Toggle Auto-Reconnect..."
    Write-MenuItem "R" "Reconnect All (AR enabled)"
    Write-Host ""
    Write-SectionEnd

    # Quick Actions
    Write-Section "ACTIONS"
    Write-Host ""
    Write-MenuItem "S" "Settings" "(devices, quality, WiFi IPs)"
    Write-MenuItem "V" "Switch Viewer" "($($Script:Config.ViewerPref))"
    Write-MenuItem "K" "Kill All Connections"
    Write-MenuItem "X" "Exit"
    Write-Host ""
    Write-SectionEnd
}

# ============================================================
#  FIRST-RUN WIZARD
# ============================================================
function Invoke-FirstRunWizard {
    Write-Host ""
    Write-Header -Title "FIRST RUN SETUP WIZARD"
    Write-Host ""
    Write-Host "  Welcome to VNC Manager v5.0!" -ForegroundColor Cyan
    Write-Host "  This wizard will help you set up your iOS devices." -ForegroundColor Gray
    Write-Host ""

    # Scan for connected devices
    Write-Host "  [1/4] Scanning for connected iOS devices..." -ForegroundColor Yellow
    $ideviceIdPath = Join-Path $Script:Config.LibDir "idevice_id.exe"

    if (-not (Test-Path $ideviceIdPath)) {
        Write-Host "  ERROR: idevice_id.exe not found in lib/ directory!" -ForegroundColor Red
        Write-Host "  Please ensure libimobiledevice binaries are in the lib/ folder." -ForegroundColor Gray
        Read-Host "  Press Enter to exit"
        exit 1
    }

    $detectedDevices = & $ideviceIdPath -l 2>$null | Where-Object { $_.Trim() -ne "" }

    if (-not $detectedDevices) {
        Write-Host "  No devices detected. Please ensure:" -ForegroundColor Yellow
        Write-Host "    - Your iOS device is connected via USB" -ForegroundColor Gray
        Write-Host "    - iTunes or Apple Devices drivers are installed" -ForegroundColor Gray
        Write-Host "    - The device is unlocked and trusted" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  You can add devices manually later from the settings menu." -ForegroundColor Cyan
        Write-Host ""
    } else {
        Write-Host "  Found $($detectedDevices.Count) device(s)!" -ForegroundColor Green
        Write-Host ""

        # Fetch device info for each detected device
        $ideviceInfoPath = Join-Path $Script:Config.LibDir "ideviceinfo.exe"
        $deviceInfo = @{}

        # Display device info table
        Write-Section "DETECTED DEVICES"
        Write-Host ""

        $deviceIndex = 1
        foreach ($udid in $detectedDevices) {
            $deviceName = "Unknown"
            $deviceModel = "Unknown"
            $iOSVersion = "Unknown"

            if (Test-Path $ideviceInfoPath) {
                $name = & $ideviceInfoPath -u $udid -k DeviceName 2>$null
                $model = & $ideviceInfoPath -u $udid -k ProductType 2>$null
                $ios = & $ideviceInfoPath -u $udid -k ProductVersion 2>$null

                if ($name) { $deviceName = $name.Trim() }
                if ($model) { $deviceModel = $model.Trim() }
                if ($ios) { $iOSVersion = $ios.Trim() }
            }

            $deviceInfo[$udid] = @{
                Name = $deviceName
                Model = $deviceModel
                iOS = $iOSVersion
            }

            # Display device info
            Write-Host "    [$deviceIndex] " -ForegroundColor Cyan -NoNewline
            Write-Host "$deviceName" -ForegroundColor White -NoNewline
            Write-Host " ($deviceModel, iOS $iOSVersion)" -ForegroundColor Gray
            $deviceIndex++
        }

        Write-Host ""
        Write-SectionEnd
    }

    # Populate device 1
    Write-Host "  [2/4] Device 1 Configuration" -ForegroundColor Yellow
    if ($detectedDevices -and $detectedDevices.Count -ge 1) {
        $udid1 = $detectedDevices[0]
        $Script:Devices[1].UDID = $udid1
        $defaultName1 = if ($deviceInfo.ContainsKey($udid1)) { $deviceInfo[$udid1].Name } else { "Device 1" }

        Write-Host "    Detected: $defaultName1" -ForegroundColor Green
        Write-Host "    Model:    $($deviceInfo[$udid1].Model)" -ForegroundColor Gray
        Write-Host "    iOS:      $($deviceInfo[$udid1].iOS)" -ForegroundColor Gray
        Write-Host "    UDID:     $udid1" -ForegroundColor DarkGray
        Write-Host ""
    } else {
        $Script:Devices[1].UDID = ""
        $defaultName1 = "Device 1"
        Write-Host "    (Not detected - add manually later)" -ForegroundColor DarkGray
        Write-Host ""
    }

    $name1 = Read-Host "    Device Name (press Enter to use: $defaultName1)"
    if ($name1) { $Script:Devices[1].Name = $name1 } else { $Script:Devices[1].Name = $defaultName1 }

    Write-Host "    TIP: Find WiFi IP on your iOS device:" -ForegroundColor Cyan
    Write-Host "         Settings > WiFi > (tap the 'i' icon) > IP Address" -ForegroundColor Gray
    $ip1 = Read-Host "    WiFi IP Address (optional, e.g., 192.168.1.100)"
    if ($ip1) { $Script:Devices[1].IP = $ip1 } else { $Script:Devices[1].IP = "192.168.1.100" }
    Write-Host ""

    # Populate device 2
    Write-Host "  [3/4] Device 2 Configuration" -ForegroundColor Yellow
    if ($detectedDevices -and $detectedDevices.Count -ge 2) {
        $udid2 = $detectedDevices[1]
        $Script:Devices[2].UDID = $udid2
        $defaultName2 = if ($deviceInfo.ContainsKey($udid2)) { $deviceInfo[$udid2].Name } else { "Device 2" }

        Write-Host "    Detected: $defaultName2" -ForegroundColor Green
        Write-Host "    Model:    $($deviceInfo[$udid2].Model)" -ForegroundColor Gray
        Write-Host "    iOS:      $($deviceInfo[$udid2].iOS)" -ForegroundColor Gray
        Write-Host "    UDID:     $udid2" -ForegroundColor DarkGray
        Write-Host ""
    } else {
        $Script:Devices[2].UDID = ""
        $defaultName2 = "Device 2"
        Write-Host "    (Not detected - add manually later)" -ForegroundColor DarkGray
        Write-Host ""
    }

    $name2 = Read-Host "    Device Name (press Enter to use: $defaultName2)"
    if ($name2) { $Script:Devices[2].Name = $name2 } else { $Script:Devices[2].Name = $defaultName2 }

    Write-Host "    TIP: Find WiFi IP on your iOS device:" -ForegroundColor Cyan
    Write-Host "         Settings > WiFi > (tap the 'i' icon) > IP Address" -ForegroundColor Gray
    $ip2 = Read-Host "    WiFi IP Address (optional, e.g., 192.168.1.101)"
    if ($ip2) { $Script:Devices[2].IP = $ip2 } else { $Script:Devices[2].IP = "192.168.1.101" }
    Write-Host ""

    # Set defaults
    Write-Host "  [4/4] Default Settings" -ForegroundColor Yellow
    Write-Host "    RECOMMENDED: Leave VNC password blank (press Enter) for easier setup." -ForegroundColor Cyan
    Write-Host "    You can set a password if your VNC server requires one." -ForegroundColor Gray
    $vncPass = Read-Host "    VNC Password (default: blank/none)"
    if ($vncPass) { $Script:Config.VncPassword = $vncPass } else { $Script:Config.VncPassword = "" }
    $Script:Config.QualityPreset = 3  # Balanced
    $Script:Config.ViewerPref = "TightVNC"
    $Script:Config.VcamMode = $false
    $Script:Config.VerboseMode = $false
    Write-Host ""

    # Save configuration
    Write-Host "  Creating device_config.ini..." -ForegroundColor Yellow
    Export-Config
    Write-Host "  Configuration saved successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Setup complete! Starting VNC Manager..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
}

# ============================================================
#  MAIN LOOP
# ============================================================
function Main {
    # Check for first run
    $configPath = Get-ConfigPath
    if (-not $configPath -or -not (Test-Path $configPath)) {
        Invoke-FirstRunWizard
    }

    Import-Config

    # ═══════════════════════════════════════════════════════════
    # STARTUP CLEANUP
    # ═══════════════════════════════════════════════════════════

    # Remove any orphan stop flags
    Get-ChildItem -Path $env:TEMP -Filter "vnc_stop_*.flag" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Remove orphan background jobs (jobs started by VNC supervisor)
    Get-Job -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "VNC-Supervisor-*" } |
        Remove-Job -Force -ErrorAction SilentlyContinue

    # Kill orphan iproxy processes on managed ports
    foreach ($port in @(5901, 5902)) {
        Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            ForEach-Object {
                $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
                if ($proc.Name -eq "iproxy") {
                    Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
                }
            }
    }

    # Register cleanup on exit - comprehensive cleanup matching Stop-AllSupervisedConnections
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        # Stop all supervised connections (jobs and stop flags)
        foreach ($slotKey in $Script:ConnectionSlots.Keys) {
            $slot = $Script:ConnectionSlots[$slotKey]
            if ($slot.SupervisorJobId) {
                $stopFlagPath = Join-Path $env:TEMP "vnc_stop_$slotKey.flag"
                Set-Content -Path $stopFlagPath -Value "stop" -Force
                Stop-Job -Id $slot.SupervisorJobId -ErrorAction SilentlyContinue
                Remove-Job -Id $slot.SupervisorJobId -Force -ErrorAction SilentlyContinue
            }
        }

        # Kill any remaining iproxy tunnels on managed ports
        foreach ($port in @(5901, 5902)) {
            Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
                    if ($proc -and $proc.Name -eq "iproxy") {
                        Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
                    }
                }
        }

        # Kill any remaining VNC viewers
        Stop-Process -Name tvnviewer -Force -ErrorAction SilentlyContinue
        Stop-Process -Name vncviewer -Force -ErrorAction SilentlyContinue
    } -SupportEvent

    # Auto-start only slots that were previously active
    $toStart = $Script:ConnectionSlots.Keys | Where-Object {
        $s = $Script:ConnectionSlots[$_]
        $s.AutoReconnect -and $s.LastActive
    }
    if ($toStart.Count -gt 0) {
        Write-Info "Auto-Reconnect enabled for $($toStart.Count) active slot(s) - starting..."
        foreach ($slotKey in $toStart) {
            Start-SupervisedConnection -SlotKey $slotKey
            Start-Sleep -Milliseconds 300
        }
    }

    while ($true) {
        Show-MainMenu
        $choice = Read-Host "  Select"

        switch ($choice.ToUpper()) {
            "1" { Connect-Slot -SlotKey "USB1" }
            "2" { Connect-Slot -SlotKey "USB2" }
            "B" { Connect-BothUSB }
            "3" { Connect-Slot -SlotKey "WiFi1" }
            "4" { Connect-Slot -SlotKey "WiFi2" }
            "W" { Connect-BothWiFi }
            "A" { Show-AutoReconnectMenu }
            "R" { Reconnect-AllWithAR }
            "S" { Show-SettingsMenu }
            "V" { Switch-Viewer; Start-Sleep -Seconds 1 }
            "K" {
                # Stop-AllTunnels already calls Stop-AllSupervisedConnections internally
                Stop-AllTunnels -ClearLastActive
                Start-Sleep -Seconds 1
            }
            "X" {
                Stop-AllSupervisedConnections
                return
            }
        }

        Start-Sleep -Milliseconds 500
    }
}

# Run
Main
