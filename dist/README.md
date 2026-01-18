# VNC Manager v5.0 - Portable Distribution

**Modern iOS VNC connection manager with smart device detection, auto-reconnect, and beautiful CLI interface.**

---

## 📦 What's Included

This portable package contains everything you need to manage VNC connections to jailbroken iOS devices:

- **VNC_Manager.exe** - Compiled executable (recommended)
- **VNC_Manager.ps1** - PowerShell source code
- **Launch_VNC_Manager.bat** - Quick launcher (double-click to run)
- **scan_devices.bat** - Device detection utility
- **lib/** - libimobiledevice binaries (idevice_id, iproxy, etc.)
- **device_config.template.ini** - Configuration template
- **viewers/** - VNC viewer download instructions

---

## ✅ Requirements

### Essential (Must Have)

1. **Windows 10/11** (64-bit)
2. **PowerShell 5.1+** (included in Windows 10/11)
3. **iTunes or Apple Devices app** (for iOS USB drivers)
   - Download: https://www.apple.com/itunes/download/
   - Or install "Apple Devices" from Microsoft Store (Windows 11)

### VNC Viewer (Choose One)

**TightVNC** (Recommended - Open Source)
- Download: https://www.tightvnc.com/download.php
- File: `tightvnc-2.8.85-gpl-setup-64bit.msi`
- License: GPL (Free)

**RealVNC Viewer** (Alternative)
- Download: https://www.realvnc.com/en/connect/download/viewer/
- License: Free for personal use

---

## 🚀 Quick Start (First Time Setup)

### Step 1: Install Prerequisites

1. Install iTunes or Apple Devices app (for USB drivers)
2. Install TightVNC or RealVNC Viewer
3. Restart your computer (recommended)

### Step 2: Connect Your iOS Device

1. Connect your jailbroken iOS device via USB
2. Unlock the device and tap "Trust This Computer" if prompted
3. Ensure VNC is running on your device (veency or similar)

### Step 3: Launch VNC Manager

**Option A: Use the .exe (Recommended)**
```
Double-click: VNC_Manager.exe
```

**Option B: Use the .bat launcher**
```
Double-click: Launch_VNC_Manager.bat
```

### Step 4: First-Run Wizard

On first launch, the setup wizard will:
1. **Scan for connected iOS devices** (automatic)
2. **Detect device UDIDs** (automatic)
3. **Prompt for device names** (e.g., "My iPhone")
4. **Prompt for WiFi IP addresses** (optional)
5. **Set VNC password** (default: test1234)
6. **Create device_config.ini** (automatic)

**Example wizard session:**
```
╔═══════════════════════════════════════════════════════╗
║          FIRST RUN SETUP WIZARD                       ║
╚═══════════════════════════════════════════════════════╝

  [1/4] Scanning for connected iOS devices...
  Found 1 device(s)!
    - 308e6361884208deb815e12efc230a028ddc4b1a

  [2/4] Device 1 Configuration
    UDID: 308e6361884208deb815e12efc230a028ddc4b1a
    Device Name (default: Device 1): My iPhone
    WiFi IP Address (optional): 192.168.1.100

  [3/4] Device 2 Configuration
    UDID: (not detected - add manually later)
    Device Name (default: Device 2):
    WiFi IP Address (optional):

  [4/4] Default Settings
    VNC Password (default: test1234): test1234

  Creating device_config.ini...
  Configuration saved successfully!

  Setup complete! Starting VNC Manager...
```

---

## 📖 Usage Guide

### Main Menu

```
╔═══════════════════════════════════════════════════════╗
║              VNC MANAGER v5.0                         ║
╠═══════════════════════════════════════════════════════╣
║  [1] USB Device 1  │ My iPhone         │ ●            ║
║  [2] USB Device 2  │ Device 2          │ ○            ║
║  [B] Connect Both USB Devices                         ║
║  [3] WiFi Device 1 │ 192.168.1.100     │ ○            ║
║  [4] WiFi Device 2 │ 192.168.1.101     │ ○            ║
║  [W] Connect Both WiFi Devices                        ║
║                                                        ║
║  [A] Auto-Reconnect Settings                          ║
║  [R] Reconnect All (Auto-Reconnect)                   ║
║  [S] Settings                                         ║
║  [V] Switch Viewer (Current: TightVNC)                ║
║  [K] Kill All Connections                             ║
║  [X] Exit                                             ║
╚═══════════════════════════════════════════════════════╝
```

### Connection Modes

| Mode | Description | When to Use |
|------|-------------|-------------|
| **USB** | Connects via iproxy tunnel over USB | Device is connected via cable |
| **WiFi** | Direct connection to device IP | Device on same network |

### Auto-Reconnect Feature

Auto-reconnect automatically restarts VNC connections if they drop:

1. Press `A` from main menu
2. Toggle auto-reconnect for desired slots (USB1, USB2, WiFi1, WiFi2)
3. Status indicators:
   - ⏸️ = Disconnected (auto-reconnect enabled)
   - ● = Connected (auto-reconnect monitoring)
   - ○ = Disconnected (auto-reconnect disabled)

**Features:**
- Automatic reconnection on disconnect
- Exponential backoff (prevents spam)
- Supervisor job monitoring
- Persists across restarts

### Quality Presets

Press `S` to access settings, then select quality preset:

| Preset | Quality | Use Case |
|--------|---------|----------|
| 1. Ultra | Highest | Strong WiFi/USB, powerful PC |
| 2. High | High | Good WiFi/USB, modern PC |
| 3. Balanced | Medium | Default - good for most users |
| 4. Stable | Low | Weak connection, older PC |
| 5. Minimal | Lowest | Very slow connection |

---

## 🔧 Configuration

### Manual Configuration

Edit `device_config.ini` to customize settings:

```ini
UDID1=308e6361884208deb815e12efc230a028ddc4b1a
NAME1=My iPhone
IP1=192.168.1.100
UDID2=00008030-001229C01146402E
NAME2=My iPad
IP2=192.168.1.101
VNC_PASSWORD=test1234
QUALITY_PRESET=3
VCAM_MODE=0
VERBOSE_MODE=0
VIEWER_PREF=1
AUTORECONNECT_USB1=0
AUTORECONNECT_USB2=0
AUTORECONNECT_WIFI1=0
AUTORECONNECT_WIFI2=0
```

### Configuration Options

| Setting | Values | Description |
|---------|--------|-------------|
| `UDID1/UDID2` | Device UDID | iOS device unique identifier |
| `NAME1/NAME2` | Text | Friendly device name |
| `IP1/IP2` | IP address | WiFi IP address |
| `VNC_PASSWORD` | Text | VNC server password |
| `QUALITY_PRESET` | 1-5 | Quality preset (1=Ultra, 5=Minimal) |
| `VCAM_MODE` | 0 or 1 | Preserve existing iproxy tunnels |
| `VERBOSE_MODE` | 0 or 1 | Show supervisor logs |
| `VIEWER_PREF` | 1 or 2 | 1=TightVNC, 2=RealVNC |
| `AUTORECONNECT_*` | 0 or 1 | Enable auto-reconnect for slot |

---

## 🛠️ Troubleshooting

### Device Not Detected

**Problem:** "No devices detected" in wizard or scan_devices.bat

**Solutions:**
1. Install iTunes or Apple Devices app (provides USB drivers)
2. Unlock device and tap "Trust This Computer"
3. Disconnect and reconnect USB cable
4. Try a different USB port
5. Restart Apple Mobile Device Service:
   ```
   Win+R → services.msc → Find "Apple Mobile Device Service" → Restart
   ```

### VNC Connection Fails

**Problem:** VNC viewer opens but can't connect

**Solutions:**
1. Ensure VNC server (veency) is running on iOS device
2. Check VNC password matches in config
3. For USB: Ensure iproxy tunnel is active (you'll see console output)
4. For WiFi: Verify IP address is correct (try ping)
5. Check firewall isn't blocking VNC ports (5901, 5902)

### Auto-Reconnect Not Working

**Problem:** Connection doesn't automatically reconnect

**Solutions:**
1. Enable auto-reconnect in menu (press `A`)
2. Check `AUTORECONNECT_*` settings in device_config.ini
3. Enable verbose mode to see supervisor logs
4. Ensure stop flags aren't stuck (`%TEMP%\vnc_stop_*.flag`)

### .exe Won't Run

**Problem:** VNC_Manager.exe doesn't launch

**Solutions:**
1. Use `Launch_VNC_Manager.bat` instead (runs PowerShell script)
2. Check PowerShell execution policy:
   ```powershell
   Get-ExecutionPolicy
   # If Restricted, run as admin:
   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
3. Right-click .exe → Properties → Unblock (if file came from download)

### VNC Viewer Not Found

**Problem:** "VNC viewer not installed" error

**Solutions:**
1. Install TightVNC or RealVNC (see Requirements section)
2. Verify installation paths:
   - TightVNC: `C:\Program Files\TightVNC\tvnviewer.exe`
   - RealVNC: `C:\Program Files\RealVNC\VNC Viewer\vncviewer.exe`
3. Press `V` to manually switch viewer

---

## 📁 File Structure

```
VNC_Manager_v5.0/
├── VNC_Manager.exe          # Compiled executable
├── VNC_Manager.ps1          # Source PowerShell script
├── Launch_VNC_Manager.bat   # Quick launcher
├── scan_devices.bat         # Device detection utility
├── device_config.ini        # User configuration (created on first run)
├── device_config.template.ini # Template config
├── README.md                # This file
├── FIRST_RUN.txt            # Quick start guide
├── lib/                     # libimobiledevice binaries
│   ├── idevice_id.exe
│   ├── ideviceinfo.exe
│   ├── idevicepair.exe
│   ├── iproxy.exe
│   └── [DLL dependencies]
└── viewers/
    └── README_VIEWERS.txt   # VNC viewer download links
```

---

## 🔒 Privacy & Security

✅ **No Telemetry** - This application does not collect or send any data
✅ **Local Only** - All configuration stored locally in device_config.ini
✅ **No User Data** - This distribution contains no personal information

**Important Notes:**
- VNC connections are encrypted only if configured on the VNC server
- Default password is "test1234" - change this for security
- UDIDs and device names are stored locally only

---

## 📝 License & Credits

### VNC Manager v5.0
- License: Provided as-is for personal use
- No warranty or support guarantees

### Third-Party Components

**libimobiledevice** (included in lib/)
- License: LGPL 2.1
- Website: https://libimobiledevice.org

**TightVNC** (not included - download separately)
- License: GPL 2.0
- Website: https://www.tightvnc.com

**RealVNC** (not included - download separately)
- License: Proprietary (Free for personal use)
- Website: https://www.realvnc.com

**ps2exe** (used to compile .exe)
- License: MS-PL
- GitHub: https://github.com/MScholtes/PS2EXE

---

## 🆘 Support

For issues or questions:
1. Check the Troubleshooting section above
2. Review device_config.ini for correct settings
3. Try running with `VERBOSE_MODE=1` to see detailed logs
4. Use scan_devices.bat to verify device detection

---

## 🎯 Tips & Tricks

**Tip 1: Fast WiFi Switching**
- Set WiFi IPs in config, then use `3`, `4`, or `W` to connect without USB

**Tip 2: Quality Optimization**
- Start with "Balanced" preset
- If laggy → lower to "Stable" or "Minimal"
- If smooth → try "High" or "Ultra"

**Tip 3: Auto-Reconnect for Development**
- Enable auto-reconnect for your primary device
- VNC stays connected even if device sleeps/wakes

**Tip 4: Multiple Devices**
- Connect USB1 + USB2 simultaneously with `B`
- Connect WiFi1 + WiFi2 simultaneously with `W`
- Mix USB and WiFi connections as needed

**Tip 5: Portable Usage**
- Copy entire folder to USB drive
- Works from any location (no installation required)
- Config travels with the folder

---

## 📜 Version History

**v5.0 - Current Release**
- First-run wizard with automatic device detection
- Auto-reconnect with supervisor pattern
- TightVNC and RealVNC support
- Quality presets
- Beautiful CLI interface
- Portable distribution

---

**Last Updated:** 2026-01-18
**Distribution Type:** Portable (no installation required)
**PowerShell Version Required:** 5.1+

---

*Made with ❤️ for the iOS jailbreak community*
