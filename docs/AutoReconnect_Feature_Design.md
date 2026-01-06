# Auto-Reconnect Feature Design

**Project:** VNC Manager v5.0
**Date:** January 2026
**Status:** Design Complete (Ready for Implementation)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Requirements](#requirements)
3. [Architecture Overview](#architecture-overview)
4. [AI Analysis Summary](#ai-analysis-summary)
5. [Data Structures](#data-structures)
6. [UI Design](#ui-design)
7. [Supervisor Job Design](#supervisor-job-design)
8. [State Machine](#state-machine)
9. [Implementation Plan](#implementation-plan)
10. [Edge Cases & Mitigations](#edge-cases--mitigations)

---

## Executive Summary

This document describes the design for an intelligent auto-reconnect feature for VNC Manager. The feature will:

- Track active VNC connections per slot (USB1, USB2, WiFi1, WiFi2)
- Automatically reconnect when VNC viewer closes unexpectedly
- Provide visual indicators in the menu showing connection status
- Allow per-slot enable/disable of auto-reconnect
- Handle mixed configurations (USB + WiFi, TightVNC + RealVNC)
- Use exponential backoff to prevent rapid-fire retry loops

**Key Design Decision:** Use PowerShell Background Jobs with the "Supervisor Pattern" - each watched connection runs in an isolated job that owns the lifecycle of both the tunnel and viewer.

---

## Requirements

### Functional Requirements

| ID | Requirement |
|----|-------------|
| FR1 | Track which connections are currently active (device, mode, viewer) |
| FR2 | Auto-reconnect when VNC viewer process terminates unexpectedly |
| FR3 | Per-slot auto-reconnect toggle (4 slots: USB1, USB2, WiFi1, WiFi2) |
| FR4 | Visual indicator next to each menu option showing status |
| FR5 | Handle USB tunnel (iproxy) death separately from viewer death |
| FR6 | Support mixed configurations (e.g., Device 1 USB + Device 2 WiFi) |
| FR7 | Persist auto-reconnect settings across sessions |
| FR8 | Clean up background jobs on script exit |

### Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR1 | Reconnection delay with exponential backoff (2s → 60s max) |
| NFR2 | Menu should refresh status on each display |
| NFR3 | No orphan processes when script exits |
| NFR4 | Distinguish intentional close from crash |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        VNC MANAGER                              │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    MAIN MENU LOOP                         │  │
│  │  - Renders status indicators                              │  │
│  │  - Handles user input                                     │  │
│  │  - Starts/stops supervisor jobs                           │  │
│  └──────────────────────────────────────────────────────────┘  │
│                            │                                    │
│         ┌──────────────────┼──────────────────┐                │
│         ▼                  ▼                  ▼                │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐        │
│  │ SUPERVISOR  │    │ SUPERVISOR  │    │ SUPERVISOR  │        │
│  │ JOB: USB1   │    │ JOB: USB2   │    │ JOB: WiFi1  │  ...   │
│  │             │    │             │    │             │        │
│  │ ┌─────────┐ │    │ ┌─────────┐ │    │ ┌─────────┐ │        │
│  │ │ iproxy  │ │    │ │ iproxy  │ │    │ │  (n/a)  │ │        │
│  │ └─────────┘ │    │ └─────────┘ │    │ └─────────┘ │        │
│  │ ┌─────────┐ │    │ ┌─────────┐ │    │ ┌─────────┐ │        │
│  │ │VNC View │ │    │ │VNC View │ │    │ │VNC View │ │        │
│  │ └─────────┘ │    │ └─────────┘ │    │ └─────────┘ │        │
│  └─────────────┘    └─────────────┘    └─────────────┘        │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              $Script:ConnectionSlots                      │  │
│  │  - Tracks state per slot                                  │  │
│  │  - Persisted to device_config.ini                         │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

**Why Background Jobs?**

| Approach | Pros | Cons |
|----------|------|------|
| **Background Jobs** ✓ | Process isolation, survives menu errors, clean IPC | Slightly more memory |
| Runspaces | Lower overhead | Complex thread safety, harder to debug |
| Polling in main loop | Simple | Blocks menu, poor UX |
| Scheduled Tasks | Persistent | Requires admin, complex setup |

---

## AI Analysis Summary

### Gemini Recommendations

1. **Supervisor Pattern** - Each connection runs in an isolated background job
2. **Global State Table** - `$Global:VNC_State` for cross-scope access
3. **Dependency Chain** - iproxy is a dependency of VNC viewer; kill iproxy when viewer exits
4. **Stop Flag Mechanism** - File-based IPC for intentional close detection
5. **Orphan Cleanup** - Kill orphaned iproxy on script startup

### Codex Recommendations

1. **Start-Process -PassThru** - Track process objects for monitoring
2. **Register-ObjectEvent** - For exit event handling (optional enhancement)
3. **State Machine** - Clear states: Disconnected → TunnelStarting → Connected → ReconnectWait
4. **ManualCloseRequested Flag** - Distinguish intentional vs crash
5. **Exponential Backoff** - `delay = min(2^retry * base, max)` with jitter
6. **DeviceMissing State** - Don't burn retries when USB device unplugged

### Merged Design Decisions

| Aspect | Decision | Source |
|--------|----------|--------|
| Architecture | Background Jobs (Supervisor Pattern) | Gemini |
| State Storage | Script-scoped hashtable + INI persistence | Both |
| Exit Detection | Polling + Job status (simpler than events) | Pragmatic |
| Intentional Close | File-based stop flag + AR toggle | Both |
| Cooldown | Exponential backoff 2s→60s with jitter | Codex |
| Device Detection | idevice_id check before USB retry | Codex |

---

## Data Structures

### Connection Slots

```powershell
# Slot-based tracking (4 slots for 4 menu options)
$Script:ConnectionSlots = @{
    "USB1" = @{
        # Configuration
        DeviceNum       = 1
        Mode            = "USB"
        AutoReconnect   = $false

        # Runtime State
        Status          = "Disconnected"  # See State Machine
        ManualStopFlag  = $false

        # Process Tracking
        ViewerPid       = $null
        TunnelPid       = $null
        SupervisorJobId = $null

        # Retry Logic
        RetryCount      = 0
        LastAttemptTime = $null
        NextRetryTime   = $null
        LastError       = ""
    }
    "USB2" = @{ DeviceNum = 2; Mode = "USB"; ... }
    "WiFi1" = @{ DeviceNum = 1; Mode = "WiFi"; ... }
    "WiFi2" = @{ DeviceNum = 2; Mode = "WiFi"; ... }
}
```

### Slot Key Mapping

| Menu Key | Slot Key | Description |
|----------|----------|-------------|
| 1 | USB1 | Device 1 via USB tunnel |
| 2 | USB2 | Device 2 via USB tunnel |
| 3 | WiFi1 | Device 1 via WiFi direct |
| 4 | WiFi2 | Device 2 via WiFi direct |

### INI Persistence

Add to `device_config.ini`:

```ini
# Existing entries...

# Auto-Reconnect Settings (new)
AUTORECONNECT_USB1=0
AUTORECONNECT_USB2=0
AUTORECONNECT_WIFI1=0
AUTORECONNECT_WIFI2=0
```

---

## UI Design

### Main Menu with Status Indicators

```
  ╔══════════════════════════════════════════════════════════╗
  ║  VNC MANAGER v5.0                                        ║
  ║  PowerShell Edition                                      ║
  ╚══════════════════════════════════════════════════════════╝

    Viewer: TightVNC   Quality: Balanced   Tunnels: 5901   vCam: OFF

  ┌─ USB ─────────────────────────────────────────────────┐
    [1] Device 1     :5901  ● Connected      [AR]
    [2] Device 2     :5902  ○ Disconnected
    [B] Both USB
  └───────────────────────────────────────────────────────┘

  ┌─ WIFI ────────────────────────────────────────────────┐
    [3] Device 1     (192.168.1.100)  ○ Disconnected
    [4] Device 2     (192.168.1.101)  ◐ Reconnecting  [AR]
    [W] Both WiFi
  └───────────────────────────────────────────────────────┘

  ┌─ AUTO-RECONNECT ──────────────────────────────────────┐
    [A] Toggle Auto-Reconnect...
    [R] Reconnect All (with AR enabled)
  └───────────────────────────────────────────────────────┘

  ┌─ ACTIONS ─────────────────────────────────────────────┐
    [S] Settings      [V] Switch Viewer
    [K] Kill All      [X] Exit
  └───────────────────────────────────────────────────────┘

  Select: _
```

### Status Indicators

| Symbol | Color | Status |
|--------|-------|--------|
| ● | Green | Connected |
| ◐ | Yellow | Reconnecting (waiting for retry) |
| ○ | Gray | Disconnected |
| ✗ | Red | Error (device missing, max retries) |

| Badge | Color | Meaning |
|-------|-------|---------|
| [AR] | Cyan | Auto-Reconnect is enabled for this slot |

### Auto-Reconnect Toggle Submenu (Option A)

```
  ┌─ TOGGLE AUTO-RECONNECT ───────────────────────────────┐
    Select slot to toggle:

    [1] USB Device 1   - Currently: OFF
    [2] USB Device 2   - Currently: ON  ✓
    [3] WiFi Device 1  - Currently: OFF
    [4] WiFi Device 2  - Currently: OFF

    [A] Toggle ALL
    [B] Back
  └───────────────────────────────────────────────────────┘
```

### PowerShell Rendering Functions

```powershell
function Get-SlotStatusIndicator {
    param([string]$SlotKey)

    $slot = $Script:ConnectionSlots[$SlotKey]

    $symbol = switch ($slot.Status) {
        "Connected"      { "●" }
        "ReconnectWait"  { "◐" }
        "TunnelStarting" { "◐" }
        "ViewerStarting" { "◐" }
        "DeviceMissing"  { "✗" }
        "Error"          { "✗" }
        default          { "○" }
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
        "DeviceMissing"  { "Device Missing" }
        "Error"          { "Error" }
        default          { "Disconnected" }
    }

    $arBadge = if ($slot.AutoReconnect) { " [AR]" } else { "" }
    $arColor = "Cyan"

    return @{
        Symbol = $symbol
        Color = $color
        StatusText = $statusText
        ARBadge = $arBadge
        ARColor = $arColor
    }
}
```

---

## Supervisor Job Design

### Supervisor Script Block

```powershell
$Script:SupervisorBlock = {
    param(
        [string]$SlotKey,      # "USB1", "USB2", "WiFi1", "WiFi2"
        [int]$DeviceNum,       # 1 or 2
        [string]$Mode,         # "USB" or "WiFi"
        [string]$UDID,         # Device UDID (for USB)
        [string]$IP,           # Device IP (for WiFi)
        [int]$LocalPort,       # 5901 or 5902
        [string]$VncExe,       # Path to VNC viewer
        [string]$VncArgs,      # VNC viewer arguments
        [string]$IproxyExe,    # Path to iproxy
        [string]$IdeviceIdExe, # Path to idevice_id (for USB device check)
        [int]$BaseDelay,       # Initial retry delay (2)
        [int]$MaxDelay,        # Maximum retry delay (60)
        [string]$StopFlagPath  # Path to stop flag file
    )

    $retryCount = 0
    $tunnelProc = $null

    while ($true) {
        # ═══════════════════════════════════════════════════════════
        # 1. CHECK STOP FLAG
        # ═══════════════════════════════════════════════════════════
        if (Test-Path $StopFlagPath) {
            Remove-Item $StopFlagPath -Force -ErrorAction SilentlyContinue
            Write-Output "STOPPED: User requested stop"
            break
        }

        # ═══════════════════════════════════════════════════════════
        # 2. CHECK DEVICE AVAILABILITY (USB only)
        # ═══════════════════════════════════════════════════════════
        if ($Mode -eq "USB") {
            $devices = & $IdeviceIdExe -l 2>$null
            if ($devices -notcontains $UDID) {
                Write-Output "WAITING: Device $UDID not connected"
                Start-Sleep -Seconds 5
                continue  # Don't burn retries, just wait
            }
        }

        # ═══════════════════════════════════════════════════════════
        # 3. START TUNNEL (USB only)
        # ═══════════════════════════════════════════════════════════
        if ($Mode -eq "USB") {
            Write-Output "TUNNEL: Starting iproxy on port $LocalPort"
            $tunnelProc = Start-Process -FilePath $IproxyExe `
                -ArgumentList "-u $UDID $LocalPort 5901" `
                -WindowStyle Hidden -PassThru

            # Wait for tunnel to establish
            $tunnelReady = $false
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Seconds 1
                $listener = Get-NetTCPConnection -LocalPort $LocalPort `
                    -State Listen -ErrorAction SilentlyContinue
                if ($listener) {
                    $tunnelReady = $true
                    break
                }
            }

            if (-not $tunnelReady) {
                Write-Output "ERROR: Tunnel failed to start"
                if ($tunnelProc -and -not $tunnelProc.HasExited) {
                    Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
                }
                $retryCount++
                $delay = [Math]::Min($BaseDelay * [Math]::Pow(2, $retryCount - 1), $MaxDelay)
                Start-Sleep -Seconds $delay
                continue
            }

            Write-Output "TUNNEL: Ready on port $LocalPort"
        }

        # ═══════════════════════════════════════════════════════════
        # 4. START VNC VIEWER (blocking wait)
        # ═══════════════════════════════════════════════════════════
        $server = if ($Mode -eq "USB") { "localhost:$LocalPort" } else { "${IP}:5901" }
        Write-Output "VIEWER: Connecting to $server"

        $viewerStartTime = Get-Date
        $viewerProc = Start-Process -FilePath $VncExe `
            -ArgumentList "$VncArgs $server" `
            -PassThru -Wait  # BLOCKS until viewer closes

        $viewerDuration = (Get-Date) - $viewerStartTime
        Write-Output "VIEWER: Exited after $($viewerDuration.TotalSeconds) seconds (code: $($viewerProc.ExitCode))"

        # ═══════════════════════════════════════════════════════════
        # 5. CHECK STOP FLAG AGAIN (might have been set while viewer was running)
        # ═══════════════════════════════════════════════════════════
        if (Test-Path $StopFlagPath) {
            Remove-Item $StopFlagPath -Force -ErrorAction SilentlyContinue
            Write-Output "STOPPED: User requested stop"
            if ($tunnelProc -and -not $tunnelProc.HasExited) {
                Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
            }
            break
        }

        # ═══════════════════════════════════════════════════════════
        # 6. CLEANUP TUNNEL
        # ═══════════════════════════════════════════════════════════
        if ($tunnelProc -and -not $tunnelProc.HasExited) {
            Write-Output "TUNNEL: Stopping iproxy"
            Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
            $tunnelProc = $null
        }

        # ═══════════════════════════════════════════════════════════
        # 7. CALCULATE RETRY DELAY
        # ═══════════════════════════════════════════════════════════
        # Reset retry count if connection lasted > 30 seconds (was stable)
        if ($viewerDuration.TotalSeconds -gt 30) {
            Write-Output "RETRY: Connection was stable, resetting retry count"
            $retryCount = 0
        } else {
            $retryCount++
        }

        # Exponential backoff with jitter
        $delay = [Math]::Min($BaseDelay * [Math]::Pow(2, $retryCount - 1), $MaxDelay)
        $jitter = Get-Random -Minimum (-$delay * 0.2) -Maximum ($delay * 0.2)
        $actualDelay = [Math]::Max(1, $delay + $jitter)

        Write-Output "RETRY: Waiting $([Math]::Round($actualDelay, 1)) seconds (attempt $retryCount)"
        Start-Sleep -Seconds $actualDelay
    }

    # ═══════════════════════════════════════════════════════════
    # CLEANUP ON EXIT
    # ═══════════════════════════════════════════════════════════
    if ($tunnelProc -and -not $tunnelProc.HasExited) {
        Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
    }

    Write-Output "SUPERVISOR: Exiting for slot $SlotKey"
}
```

### Starting a Supervised Connection

```powershell
function Start-SupervisedConnection {
    param(
        [string]$SlotKey  # "USB1", "USB2", "WiFi1", "WiFi2"
    )

    $slot = $Script:ConnectionSlots[$SlotKey]
    $device = $Script:Devices[$slot.DeviceNum]
    $viewer = Get-VncViewer

    # Create stop flag path
    $stopFlagPath = Join-Path $env:TEMP "vnc_stop_$SlotKey.flag"

    # Remove any existing stop flag
    if (Test-Path $stopFlagPath) {
        Remove-Item $stopFlagPath -Force
    }

    # Build arguments
    $args = @(
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
    $job = Start-Job -ScriptBlock $Script:SupervisorBlock -ArgumentList $args

    # Update state
    $slot.SupervisorJobId = $job.Id
    $slot.Status = "TunnelStarting"
    $slot.ManualStopFlag = $false
    $slot.RetryCount = 0

    Write-Success "Started supervised connection for $SlotKey (Job $($job.Id))"
}
```

### Stopping a Supervised Connection

```powershell
function Stop-SupervisedConnection {
    param(
        [string]$SlotKey
    )

    $slot = $Script:ConnectionSlots[$SlotKey]

    # Set stop flag
    $stopFlagPath = Join-Path $env:TEMP "vnc_stop_$SlotKey.flag"
    Set-Content -Path $stopFlagPath -Value "stop" -Force
    $slot.ManualStopFlag = $true

    # Give job a moment to see the flag
    Start-Sleep -Milliseconds 500

    # Force-stop job if still running
    if ($slot.SupervisorJobId) {
        $job = Get-Job -Id $slot.SupervisorJobId -ErrorAction SilentlyContinue
        if ($job -and $job.State -eq "Running") {
            Stop-Job -Id $slot.SupervisorJobId -ErrorAction SilentlyContinue
        }
        Remove-Job -Id $slot.SupervisorJobId -Force -ErrorAction SilentlyContinue
    }

    # Reset state
    $slot.SupervisorJobId = $null
    $slot.Status = "Disconnected"
    $slot.ViewerPid = $null
    $slot.TunnelPid = $null

    Write-Success "Stopped supervised connection for $SlotKey"
}
```

---

## State Machine

```
                                    ┌────────────────────┐
                                    │                    │
                 ┌──────────────────│   Disconnected     │◄───────────┐
                 │                  │                    │            │
                 │                  └────────────────────┘            │
                 │                           │                        │
                 │                           │ Start                  │
                 │                           ▼                        │
                 │                  ┌────────────────────┐            │
                 │  (USB)           │                    │            │
                 │  Device missing  │   TunnelStarting   │            │
                 │                  │                    │            │
                 │                  └────────────────────┘            │
                 │                           │                        │
                 │                           │ Tunnel ready           │
                 │                           ▼                        │
                 │                  ┌────────────────────┐            │
                 │                  │                    │            │
                 │                  │   ViewerStarting   │            │
                 │                  │                    │            │
                 │                  └────────────────────┘            │
                 │                           │                        │
                 │                           │ Viewer connected       │
                 │                           ▼                        │
                 │                  ┌────────────────────┐            │
                 │                  │                    │            │
    ┌────────────┼──────────────────│     Connected      │────────────┤
    │            │                  │                    │            │
    │            │                  └────────────────────┘            │
    │            │                           │                        │
    │            │                           │ Viewer/Tunnel          │
    │            │                           │ exit (unexpected)      │
    │            │                           ▼                        │
    │            │                  ┌────────────────────┐            │
    │            │                  │                    │            │
    │            └──────────────────│   ReconnectWait    │────────────┘
    │                               │   (backoff timer)  │   Timer
    │                               │                    │   expired
    │                               └────────────────────┘
    │                                        │
    │   Manual Stop                          │ Device
    │   (at any state)                       │ unplugged
    │                                        ▼
    │                               ┌────────────────────┐
    │                               │                    │
    └──────────────────────────────►│   DeviceMissing    │
                                    │   (USB only)       │
                                    │                    │
                                    └────────────────────┘
                                             │
                                             │ Device
                                             │ reconnected
                                             │
                                             ▼
                                    (back to TunnelStarting)
```

### State Descriptions

| State | Description | Next States |
|-------|-------------|-------------|
| **Disconnected** | No connection attempt | TunnelStarting (on Start) |
| **TunnelStarting** | Starting iproxy tunnel (USB) | ViewerStarting, ReconnectWait, DeviceMissing |
| **ViewerStarting** | Launching VNC viewer | Connected, ReconnectWait |
| **Connected** | VNC session active | ReconnectWait (exit), Disconnected (manual stop) |
| **ReconnectWait** | Waiting for retry timer | TunnelStarting, Disconnected (manual stop) |
| **DeviceMissing** | USB device not detected | TunnelStarting (device returns), Disconnected |

---

## Implementation Plan

### Phase 1: State Infrastructure (Foundation)

**Files to modify:** `VNC_Manager.ps1`

1. Add `$Script:ConnectionSlots` data structure
2. Add `$Script:SupervisorBlock` script block (empty stub)
3. Modify `Import-Config` to load auto-reconnect settings
4. Modify `Export-Config` to save auto-reconnect settings
5. Add `Update-SlotStatus` function to refresh status from jobs
6. Add `Get-SlotStatusIndicator` function for rendering

**Estimated effort:** 1-2 hours

### Phase 2: UI Integration

**Files to modify:** `VNC_Manager.ps1`

1. Modify `Show-MainMenu` to render status indicators
2. Add new section for Auto-Reconnect controls
3. Add `Show-AutoReconnectMenu` submenu function
4. Modify menu choice handling for new options (A, R)
5. Add status refresh call on each menu display

**Estimated effort:** 2-3 hours

### Phase 3: Supervisor Job Implementation

**Files to modify:** `VNC_Manager.ps1`

1. Complete `$Script:SupervisorBlock` implementation
2. Add `Start-SupervisedConnection` function
3. Add `Stop-SupervisedConnection` function
4. Modify existing `Connect-USB` and `Connect-WiFi` to use supervised mode when AR enabled
5. Add job cleanup on script exit (`Register-EngineEvent`)

**Estimated effort:** 3-4 hours

### Phase 4: Polish & Edge Cases

**Files to modify:** `VNC_Manager.ps1`

1. Add orphan job/process cleanup on startup
2. Add device missing detection (USB)
3. Add network reachability check (WiFi)
4. Add job output logging to file (optional)
5. Testing and bug fixes

**Estimated effort:** 2-3 hours

### Total Estimated Effort: 8-12 hours

---

## Edge Cases & Mitigations

| Edge Case | Mitigation |
|-----------|------------|
| User closes VNC window intentionally | Auto-reconnect toggle is authoritative; if ON, reconnect |
| iproxy dies but viewer stays open | Viewer will hang; supervisor detects viewer exit on next action |
| Device unplugged during session | DeviceMissing state; pause retries until device returns |
| Script crashes/closes unexpectedly | `Register-EngineEvent -SourceIdentifier PowerShell.Exiting` for cleanup |
| Orphan iproxy from previous run | Startup cleanup: kill iproxy processes for managed ports |
| Rapid connect/disconnect cycles | Exponential backoff prevents CPU thrashing |
| Wrong VNC password | Viewer exits immediately; backoff kicks in |
| Both USB and WiFi enabled for same device | Allowed - treated as independent slots |
| User changes viewer preference mid-session | New viewer used on next reconnect |

---

## Summary

This design provides a robust auto-reconnect system that:

- Uses **isolated background jobs** for reliability
- Tracks **4 independent connection slots** (USB1, USB2, WiFi1, WiFi2)
- Displays **visual status indicators** in the menu
- Uses **exponential backoff** to prevent rapid-fire retries
- Detects **device disconnection** (USB) to pause retries
- Cleans up **orphan processes** on startup and exit
- Persists settings in the **existing INI format**

The implementation is structured in 4 phases, with the core functionality achievable in approximately 8-12 hours of development time.

---

*Design created with analysis from Gemini CLI and OpenAI Codex CLI.*
