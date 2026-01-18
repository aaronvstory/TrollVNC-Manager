# AGENTS.md

This file provides instructions for coding agents working in this repo.

## Repo summary
- VNC Manager v5.0 is a PowerShell 5.1 script that manages VNC connections
  to jailbroken iOS devices over USB (iproxy tunnel) or WiFi.
- It supports TightVNC and RealVNC viewers and includes an auto-reconnect
  supervisor for each connection slot.

## Entry points
- Launch_VNC_Manager.bat
- powershell -NoProfile -ExecutionPolicy Bypass -File VNC_Manager.ps1
- scan_devices.bat

## Key files
- VNC_Manager.ps1 (single-file application)
- device_config.ini (user config; keep sample values, avoid real UDIDs)
- lib/ (libimobiledevice binaries and iproxy.exe; do not edit)
- docs/AutoReconnect_Feature_Design.md
- docs/AutoReconnect_Implementation_Plan.md
- docs/VNC_Disconnection_Analysis.md
- README.txt

## Architecture notes
- $Script:Config, $Script:Devices, $Script:QualityPresets define defaults.
- Auto-reconnect uses $Script:ConnectionSlots and $Script:SupervisorBlock
- Supervisor jobs are named VNC-Supervisor-<slot> and use stop flag files
  in %TEMP% (vnc_stop_<slot>.flag).
- Connect-USB/Connect-WiFi call Start-SupervisedConnection when auto-reconnect
  is enabled; otherwise they launch the viewer directly.

## Configuration keys (device_config.ini)
- UDID1/UDID2, NAME1/NAME2, IP1/IP2
- VNC_PASSWORD, QUALITY_PRESET (1-5), VCAM_MODE (0/1), VIEWER_PREF (1/2)
- VERBOSE_MODE (0/1) controls supervisor log display
- AUTORECONNECT_USB1/USB2/WIFI1/WIFI2 (0/1)
- LAST_ACTIVE_USB1/USB2/WIFI1/WIFI2 (0/1) auto-start memory

## Modification guidance
- Add a viewer: update Get-VncViewer and add quality flags as needed.
- Add a quality preset: update $Script:QualityPresets and README/CLAUDE.
- Add device slots: update $Script:Devices, ConnectionSlots, menus,
  and Import-Config/Export-Config plus new INI keys.

## Verification
- Manual only: run the app, scan devices, connect via USB/WiFi,
  toggle auto-reconnect, and confirm tunnels are cleaned up.
- scan_devices.bat is a quick device detection check.

## Notes
- Windows only; keep PowerShell 5.1+ compatibility.
- Avoid Unicode unless necessary.
