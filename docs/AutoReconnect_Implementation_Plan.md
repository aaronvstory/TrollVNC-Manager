# Auto-Reconnect Feature - Implementation Plan

**Project:** VNC Manager v5.0
**File:** `VNC_Manager.ps1`
**Date:** January 2026
**Reference:** See `AutoReconnect_Feature_Design.md` for full design rationale

---

## Quick Context

VNC Manager is a PowerShell script that connects to iOS devices via VNC (TrollVNC server). This implementation adds an **auto-reconnect feature** that:

1. Monitors VNC viewer processes
2. Automatically reconnects when viewer closes unexpectedly
3. Shows visual status indicators in the menu
4. Allows per-slot enable/disable of auto-reconnect
5. Uses exponential backoff to prevent rapid retries

**Architecture:** Background Jobs with Supervisor Pattern (recommended by Gemini + Codex analysis)

---

## File Structure

```
VNC_Manager_v5.0/
├── VNC_Manager.ps1          # Main script (modify this)
├── device_config.ini        # Config file (add AR settings)
├── docs/
│   ├── AutoReconnect_Feature_Design.md
│   └── AutoReconnect_Implementation_Plan.md  # This file
└── lib/
    ├── iproxy.exe
    ├── idevice_id.exe
    └── ...
```

---

## Phase 1: State Infrastructure

### Step 1.1: Add Connection Slots Data Structure

**Location:** After line 25 (after `$Script:Devices`)

```powershell
# ============================================================
#  CONNECTION STATE (Auto-Reconnect)
# ============================================================
$Script:ConnectionSlots = @{
    "USB1" = @{
        DeviceNum       = 1
        Mode            = "USB"
        AutoReconnect   = $false
        Status          = "Disconnected"
        ManualStopFlag  = $false
        ViewerPid       = $null
        TunnelPid       = $null
        SupervisorJobId = $null
        RetryCount      = 0
        LastAttemptTime = $null
        LastError       = ""
    }
    "USB2" = @{
        DeviceNum       = 2
        Mode            = "USB"
        AutoReconnect   = $false
        Status          = "Disconnected"
        ManualStopFlag  = $false
        ViewerPid       = $null
        TunnelPid       = $null
        SupervisorJobId = $null
        RetryCount      = 0
        LastAttemptTime = $null
        LastError       = ""
    }
    "WiFi1" = @{
        DeviceNum       = 1
        Mode            = "WiFi"
        AutoReconnect   = $false
        Status          = "Disconnected"
        ManualStopFlag  = $false
        ViewerPid       = $null
        TunnelPid       = $null
        SupervisorJobId = $null
        RetryCount      = 0
        LastAttemptTime = $null
        LastError       = ""
    }
    "WiFi2" = @{
        DeviceNum       = 2
        Mode            = "WiFi"
        AutoReconnect   = $false
        Status          = "Disconnected"
        ManualStopFlag  = $false
        ViewerPid       = $null
        TunnelPid       = $null
        SupervisorJobId = $null
        RetryCount      = 0
        LastAttemptTime = $null
        LastError       = ""
    }
}

# Mapping menu keys to slot keys
$Script:SlotKeyMap = @{
    "1" = "USB1"
    "2" = "USB2"
    "3" = "WiFi1"
    "4" = "WiFi2"
}
```

### Step 1.2: Modify Import-Config

**Location:** Inside `Import-Config` function (around line 174)

**Add these cases to the switch statement:**

```powershell
"AUTORECONNECT_USB1"  { $Script:ConnectionSlots["USB1"].AutoReconnect = $value -eq "1" }
"AUTORECONNECT_USB2"  { $Script:ConnectionSlots["USB2"].AutoReconnect = $value -eq "1" }
"AUTORECONNECT_WIFI1" { $Script:ConnectionSlots["WiFi1"].AutoReconnect = $value -eq "1" }
"AUTORECONNECT_WIFI2" { $Script:ConnectionSlots["WiFi2"].AutoReconnect = $value -eq "1" }
```

### Step 1.3: Modify Export-Config

**Location:** Inside `Export-Config` function (around line 198)

**Replace the entire function with:**

```powershell
function Export-Config {
    $viewerNum = if ($Script:Config.ViewerPref -eq "RealVNC") { "2" } else { "1" }
    $vcamNum = if ($Script:Config.VcamMode) { "1" } else { "0" }

    # Auto-reconnect values
    $arUsb1 = if ($Script:ConnectionSlots["USB1"].AutoReconnect) { "1" } else { "0" }
    $arUsb2 = if ($Script:ConnectionSlots["USB2"].AutoReconnect) { "1" } else { "0" }
    $arWifi1 = if ($Script:ConnectionSlots["WiFi1"].AutoReconnect) { "1" } else { "0" }
    $arWifi2 = if ($Script:ConnectionSlots["WiFi2"].AutoReconnect) { "1" } else { "0" }

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
VIEWER_PREF=$viewerNum
AUTORECONNECT_USB1=$arUsb1
AUTORECONNECT_USB2=$arUsb2
AUTORECONNECT_WIFI1=$arWifi1
AUTORECONNECT_WIFI2=$arWifi2
"@ | Set-Content $Script:Config.ConfigFile -Encoding UTF8
}
```

### Step 1.4: Add Status Helper Functions

**Location:** After `Write-Warning` function (around line 89)

```powershell
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

    # Job is running - check for recent output to determine state
    # For now, assume connected if job is running
    if ($slot.Status -eq "Disconnected") {
        $slot.Status = "Connected"
    }
}

function Update-AllSlotStatuses {
    foreach ($slotKey in $Script:ConnectionSlots.Keys) {
        Update-SlotStatus -SlotKey $slotKey
    }
}
```

---

## Phase 2: Supervisor Job Implementation

### Step 2.1: Add Supervisor Script Block

**Location:** After the Connection Slots definition (after Step 1.1)

```powershell
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
        [string]$StopFlagPath
    )

    $retryCount = 0
    $tunnelProc = $null

    # Helper to write timestamped output
    function Write-Log { param($Msg) Write-Output "$(Get-Date -Format 'HH:mm:ss') [$SlotKey] $Msg" }

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

            # Kill any existing tunnel on this port
            Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue |
                ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }

            Start-Sleep -Milliseconds 500

            $tunnelProc = Start-Process -FilePath $IproxyExe `
                -ArgumentList "-u $UDID $LocalPort 5901" `
                -WindowStyle Hidden -PassThru

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
                $delay = [Math]::Min($BaseDelay * [Math]::Pow(2, $retryCount - 1), $MaxDelay)
                Write-Log "Retry in $delay seconds (attempt $retryCount)"
                Start-Sleep -Seconds $delay
                continue
            }
        }

        # ═══════════════════════════════════════════════════════════
        # 4. START VNC VIEWER (blocking wait)
        # ═══════════════════════════════════════════════════════════
        $server = if ($Mode -eq "USB") { "localhost:$LocalPort" } else { "${IP}:5901" }
        Write-Log "Connecting viewer to $server"

        $viewerStartTime = Get-Date
        try {
            $viewerProc = Start-Process -FilePath $VncExe `
                -ArgumentList "$VncArgs $server" `
                -PassThru -Wait
        } catch {
            Write-Log "Viewer failed to start: $_"
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

        $delay = [Math]::Min($BaseDelay * [Math]::Pow(2, [Math]::Max(0, $retryCount - 1)), $MaxDelay)
        $jitter = Get-Random -Minimum (-$delay * 0.2) -Maximum ($delay * 0.2)
        $actualDelay = [Math]::Max(2, $delay + $jitter)

        Write-Log "Reconnecting in $([Math]::Round($actualDelay, 1))s (attempt $retryCount)"
        Start-Sleep -Seconds $actualDelay
    }

    # Cleanup
    if ($tunnelProc -and -not $tunnelProc.HasExited) {
        Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
    }
    Write-Log "Supervisor exiting"
}
```

### Step 2.2: Add Start/Stop Supervised Connection Functions

**Location:** After the Supervisor Block

```powershell
function Start-SupervisedConnection {
    param(
        [string]$SlotKey
    )

    $slot = $Script:ConnectionSlots[$SlotKey]
    $device = $Script:Devices[$slot.DeviceNum]
    $viewer = Get-VncViewer

    if (-not $viewer) {
        Write-Error "No VNC viewer found"
        return $false
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
        $stopFlagPath
    )

    # Start supervisor job
    $job = Start-Job -ScriptBlock $Script:SupervisorBlock -ArgumentList $jobArgs

    # Update state
    $slot.SupervisorJobId = $job.Id
    $slot.Status = if ($slot.Mode -eq "USB") { "TunnelStarting" } else { "ViewerStarting" }
    $slot.ManualStopFlag = $false
    $slot.RetryCount = 0
    $slot.LastAttemptTime = Get-Date

    Write-Success "Started auto-reconnect for $SlotKey (Job $($job.Id))"
    return $true
}

function Stop-SupervisedConnection {
    param(
        [string]$SlotKey
    )

    $slot = $Script:ConnectionSlots[$SlotKey]

    # Set stop flag
    $stopFlagPath = Join-Path $env:TEMP "vnc_stop_$SlotKey.flag"
    Set-Content -Path $stopFlagPath -Value "stop" -Force
    $slot.ManualStopFlag = $true

    Start-Sleep -Milliseconds 500

    # Stop job
    if ($slot.SupervisorJobId) {
        $job = Get-Job -Id $slot.SupervisorJobId -ErrorAction SilentlyContinue
        if ($job) {
            Stop-Job -Id $slot.SupervisorJobId -ErrorAction SilentlyContinue
            Remove-Job -Id $slot.SupervisorJobId -Force -ErrorAction SilentlyContinue
        }
    }

    # Kill any viewer/tunnel for this slot's port
    $port = $Script:Devices[$slot.DeviceNum].Port
    if ($slot.Mode -eq "USB") {
        Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    }

    # Reset state
    $slot.SupervisorJobId = $null
    $slot.Status = "Disconnected"
    $slot.ViewerPid = $null
    $slot.TunnelPid = $null

    Write-Success "Stopped connection for $SlotKey"
}

function Stop-AllSupervisedConnections {
    foreach ($slotKey in $Script:ConnectionSlots.Keys) {
        $slot = $Script:ConnectionSlots[$slotKey]
        if ($slot.SupervisorJobId) {
            Stop-SupervisedConnection -SlotKey $slotKey
        }
    }
}
```

---

## Phase 3: UI Integration

### Step 3.1: Add Write-MenuItemWithStatus Function

**Location:** After `Write-MenuItem` function (around line 84)

```powershell
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
}
```

### Step 3.2: Modify Show-MainMenu Function

**Replace the existing `Show-MainMenu` function with:**

```powershell
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

    Write-Header "VNC MANAGER v5.0" "PowerShell Edition + Auto-Reconnect"

    # Status bar
    Write-Host "    Viewer: " -ForegroundColor Gray -NoNewline
    Write-Host $Script:Config.ViewerPref -ForegroundColor Cyan -NoNewline
    Write-Host "   Quality: " -ForegroundColor Gray -NoNewline
    Write-Host $qualityName -ForegroundColor Cyan -NoNewline
    Write-Host "   Tunnels: " -ForegroundColor Gray -NoNewline
    Write-Host $tunnelStr -ForegroundColor $tunnelColor -NoNewline
    Write-Host "   vCam: " -ForegroundColor Gray -NoNewline
    Write-Host $vcamStr -ForegroundColor $vcamColor
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
```

### Step 3.3: Add Auto-Reconnect Toggle Menu

**Location:** After `Show-SettingsMenu` function

```powershell
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
        Write-MenuItem "B" "Back"
        Write-Host ""

        $choice = Read-Host "  Select slot to toggle"

        switch ($choice.ToUpper()) {
            "1" { Toggle-AutoReconnect -SlotKey "USB1" }
            "2" { Toggle-AutoReconnect -SlotKey "USB2" }
            "3" { Toggle-AutoReconnect -SlotKey "WiFi1" }
            "4" { Toggle-AutoReconnect -SlotKey "WiFi2" }
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
            "B" { return }
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

    Start-Sleep -Seconds 1
}
```

### Step 3.4: Modify Main Menu Loop

**Replace the main loop switch statement in the `Main` function (around line 676):**

```powershell
function Main {
    Import-Config

    # Cleanup orphan jobs on startup
    Get-Job | Where-Object { $_.Name -like "vnc_*" } | Remove-Job -Force -ErrorAction SilentlyContinue

    # Register cleanup on exit
    Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        Stop-AllSupervisedConnections
    } -SupportEvent

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
                Stop-AllSupervisedConnections
                Stop-AllTunnels
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
```

### Step 3.5: Add Connect-Slot and Reconnect Functions

**Location:** Before the `Main` function

```powershell
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
    }
}

function Reconnect-AllWithAR {
    Write-Info "Reconnecting all slots with Auto-Reconnect enabled..."

    foreach ($slotKey in $Script:ConnectionSlots.Keys) {
        $slot = $Script:ConnectionSlots[$slotKey]
        if ($slot.AutoReconnect) {
            Write-Info "Reconnecting $slotKey..."
            Start-SupervisedConnection -SlotKey $slotKey
            Start-Sleep -Milliseconds 500
        }
    }

    Write-Success "Reconnect initiated for all AR-enabled slots"
    Start-Sleep -Seconds 1
}
```

---

## Phase 4: Polish & Edge Cases

### Step 4.1: Add Startup Cleanup

**Add at the beginning of `Main` function:**

```powershell
function Main {
    Import-Config

    # ═══════════════════════════════════════════════════════════
    # STARTUP CLEANUP
    # ═══════════════════════════════════════════════════════════

    # Remove any orphan stop flags
    Get-ChildItem -Path $env:TEMP -Filter "vnc_stop_*.flag" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # Remove orphan background jobs
    Get-Job -ErrorAction SilentlyContinue |
        Where-Object { $_.Command -like "*SupervisorBlock*" } |
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

    # Register cleanup on exit
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        # Stop all supervised connections
        foreach ($slotKey in $Script:ConnectionSlots.Keys) {
            $slot = $Script:ConnectionSlots[$slotKey]
            if ($slot.SupervisorJobId) {
                $stopFlagPath = Join-Path $env:TEMP "vnc_stop_$slotKey.flag"
                Set-Content -Path $stopFlagPath -Value "stop" -Force
                Stop-Job -Id $slot.SupervisorJobId -ErrorAction SilentlyContinue
                Remove-Job -Id $slot.SupervisorJobId -Force -ErrorAction SilentlyContinue
            }
        }
    } -SupportEvent

    # ... rest of Main function
}
```

### Step 4.2: Update Stop-AllTunnels to Coordinate with AR

**Replace the existing `Stop-AllTunnels` function:**

```powershell
function Stop-AllTunnels {
    Write-Info "Stopping all tunnels and connections..."

    # First stop all supervised connections (gracefully)
    Stop-AllSupervisedConnections

    # Then force-kill any remaining processes
    Stop-Tunnel 5901
    Stop-Tunnel 5902
    Stop-Process -Name tvnviewer -Force -ErrorAction SilentlyContinue
    Stop-Process -Name vncviewer -Force -ErrorAction SilentlyContinue

    # Don't kill ALL iproxy - only ones on our ports (handled by Stop-Tunnel)

    Write-Success "All tunnels stopped"
}
```

---

## Testing Checklist

### Basic Functionality

- [ ] Status indicators show correctly for each slot
- [ ] [AR] badge appears when auto-reconnect is enabled
- [ ] Toggle menu (A) enables/disables AR per slot
- [ ] Settings persist in INI file after restart

### Auto-Reconnect Behavior

- [ ] With AR ON: VNC reconnects after closing viewer window
- [ ] With AR OFF: VNC does not reconnect after closing
- [ ] USB: Reconnects after device unplug/replug
- [ ] WiFi: Reconnects after network disruption
- [ ] Exponential backoff works (delays increase after failures)
- [ ] Stable connection (>30s) resets retry counter

### Edge Cases

- [ ] Kill All (K) stops all supervised connections
- [ ] Exit (X) cleans up all jobs
- [ ] Force-closing PowerShell window cleans up (exit handler)
- [ ] Orphan cleanup works on restart
- [ ] Mixed mode works (USB1 + WiFi2 simultaneously)

---

## Troubleshooting

### Job Not Starting

```powershell
# Check for existing jobs
Get-Job | Format-Table Id, State, Command

# Check stop flags
Get-ChildItem $env:TEMP -Filter "vnc_stop_*.flag"
```

### Connection Not Reconnecting

```powershell
# Get job output for debugging
$slot = $Script:ConnectionSlots["USB1"]
if ($slot.SupervisorJobId) {
    Receive-Job -Id $slot.SupervisorJobId -Keep
}
```

### Orphan Processes

```powershell
# Find orphan iproxy
Get-Process -Name iproxy -ErrorAction SilentlyContinue

# Find what's using the port
Get-NetTCPConnection -LocalPort 5901 -State Listen
```

---

## Summary of Changes

| File | Changes |
|------|---------|
| `VNC_Manager.ps1` | Add ~400 lines of new code |
| `device_config.ini` | Add 4 new config keys |

### New Functions Added

1. `Get-SlotStatusIndicator` - Renders status symbol/color
2. `Update-SlotStatus` - Refreshes slot state from job
3. `Update-AllSlotStatuses` - Refreshes all slots
4. `Write-MenuItemWithStatus` - Renders menu item with status
5. `Start-SupervisedConnection` - Starts supervised connection
6. `Stop-SupervisedConnection` - Stops supervised connection
7. `Stop-AllSupervisedConnections` - Stops all supervised connections
8. `Show-AutoReconnectMenu` - AR toggle menu
9. `Toggle-AutoReconnect` - Toggles AR for a slot
10. `Connect-Slot` - Smart connect (supervised if AR on)
11. `Reconnect-AllWithAR` - Reconnects all AR-enabled slots

### New Data Structures

1. `$Script:ConnectionSlots` - Per-slot state tracking
2. `$Script:SlotKeyMap` - Menu key to slot key mapping
3. `$Script:SupervisorBlock` - Background job script block

---

*Implementation plan created January 2026*
*Based on analysis from Gemini CLI and OpenAI Codex CLI*
