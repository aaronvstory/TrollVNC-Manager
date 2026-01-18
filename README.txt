================================================================================
                         VNC MANAGER v5.0 - PowerShell Edition
              iOS VNC Connection Manager for TightVNC & RealVNC
================================================================================

REQUIREMENTS
------------
- Windows 10/11 with PowerShell 5.1 or PowerShell 7 (pwsh)
- TightVNC Viewer (https://www.tightvnc.com/download.php)
  OR RealVNC Viewer (https://www.realvnc.com/en/connect/download/viewer/)
- iOS device(s) with VNC server running (e.g., Veency on jailbroken device)
- USB cable for USB mode, or WiFi for wireless mode

QUICK START
-----------
1. Double-click "Launch_VNC_Manager.bat"
2. Press [S] to open Settings
3. Press [S] again to Scan Devices (devices must be connected via USB)
4. Press [A] to Auto-assign detected devices to slots
5. Press [B] to return to main menu
6. Press [1] or [2] to connect via USB

PowerShell 7 users:
  pwsh -NoProfile -ExecutionPolicy Bypass -File VNC_Manager.ps1

MAIN MENU OPTIONS
-----------------
USB Connections:
  [1] Connect to Device 1 via USB tunnel (port 5901)
  [2] Connect to Device 2 via USB tunnel (port 5902)
  [B] Connect to both devices via USB

WiFi Connections:
  [3] Connect to Device 1 via WiFi
  [4] Connect to Device 2 via WiFi
  [W] Connect to both devices via WiFi

Actions:
  [A] Toggle Auto-Reconnect (per slot)
  [R] Reconnect all slots with Auto-Reconnect enabled
  [S] Settings - configure devices, quality, WiFi IPs
  [V] Switch between TightVNC and RealVNC
  [K] Kill all active tunnels
  [X] Exit

SETTINGS MENU
-------------
Device Configuration:
  [1] Set WiFi IP for Device 1
  [2] Set WiFi IP for Device 2
  [3] Rename Device 1
  [4] Rename Device 2

Tools & Preferences:
  [S] Scan Devices - detect connected iOS devices
  [Q] Quality Preset (Ultra/High/Balanced/Stable/Minimal)
  [C] vCam Mode - preserve existing tunnels when connecting
  [V] Switch VNC Viewer
  [P] Change VNC password
  [L] Verbose Logs - show supervisor log lines

AUTO-RECONNECT
--------------
- Enable per slot in the Auto-Reconnect menu (A)
- The supervisor restarts viewer/tunnel on unexpected disconnects
- Auto-start on launch only for slots that were previously active
- Use Auto-Reconnect menu (C) to clear remembered auto-start slots
- Stop flags are used to end auto-reconnect cleanly
- Verbose Logs (L) shows supervisor log lines (saved under %TEMP%\VNC_Manager_Logs)

QUALITY PRESETS
---------------
  1. Ultra    - Best quality, highest bandwidth
  2. High     - Great quality, moderate bandwidth
  3. Balanced - Good quality/performance trade-off (default)
  4. Stable   - Lower quality, very stable
  5. Minimal  - Lowest quality, minimal bandwidth

FIRST-TIME SETUP
----------------
1. Connect your iOS device via USB
2. Launch the app and go to Settings > Scan Devices
3. If device shows "Not Paired", select [P] to pair
4. Tap "Trust" on your iOS device when prompted
5. Auto-assign the device to a slot
6. For WiFi mode, enter the device's WiFi IP address

TROUBLESHOOTING
---------------
"No devices found":
  - Ensure device is connected via USB
  - Ensure iTunes/Apple Devices is installed (provides drivers)
  - Try a different USB cable or port

"Device shows as Not Paired":
  - Use the Pair option in Scan Devices
  - Tap "Trust" on your iOS device
  - Re-scan after pairing

"Connection refused":
  - Ensure VNC server is running on the iOS device
  - Check the VNC password matches
  - For WiFi, ensure device is on the same network

"Tunnel timeout":
  - Kill existing tunnels and try again
  - Re-pair the device if needed
  - Check USB connection

FILES
-----
VNC_Manager.ps1       - Main PowerShell script
Launch_VNC_Manager.bat - Launcher (double-click this)
device_config.ini     - Your device configuration (auto-created)
scan_devices.bat      - Standalone device scanner
lib/                  - Required iOS communication tools

CREDITS
-------
libimobiledevice tools: https://github.com/libimobiledevice
TightVNC: https://www.tightvnc.com
RealVNC: https://www.realvnc.com

================================================================================
