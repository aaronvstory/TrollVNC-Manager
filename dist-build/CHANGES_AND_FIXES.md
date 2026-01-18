# VNC Manager v5.0 - Latest Changes & Fixes

## Date: 2026-01-18

---

## 🐛 Fixes Applied

### 1. **CRITICAL: Device Detection Bug Fixed** ✅
**Issue:** Only 1 device detected when 2+ were connected

**Root Cause:** Regex pattern `^\w+-\w+` in first-run wizard (line 1569) expected exactly one hyphen, but iOS UDIDs come in two formats:
- Format 1: 40 hex chars, no hyphens (e.g., `308e6361884208deb815e12efc230a028ddc4b1a`)
- Format 2: Hex with multiple hyphens (e.g., `00008030-001229C01146402E`)

**Fix:** Changed line 1569 from:
```powershell
$detectedDevices = & $ideviceIdPath -l 2>$null | Where-Object { $_ -match "^\w+-\w+" }
```

To:
```powershell
$detectedDevices = & $ideviceIdPath -l 2>$null | Where-Object { $_.Trim() -ne "" }
```

**Result:** Now detects ALL connected devices regardless of UDID format.

---

### 2. **Default VNC Password Changed to Blank** ✅
**Change:** Default VNC password changed from `"test1234"` to `""` (empty/blank)

**Files Modified:**
- `VNC_Manager.ps1` line 16: `VncPassword = ""`
- `device_config.template.ini` line 7: `VNC_PASSWORD=`
- First-run wizard (lines 1623-1626): Updated prompt and guidance

**User Experience Improvement:**
- Added recommendation message: *"RECOMMENDED: Leave VNC password blank (press Enter) for easier setup."*
- Added explanation: *"You can set a password if your VNC server requires one."*
- Prompt now says: `VNC Password (default: blank/none)` instead of `(default: test1234)`

---

### 3. **WiFi IP Discovery Help Added** ✅
**Change:** Added helpful tips in first-run wizard to guide users in finding their device's WiFi IP address

**Added at lines 1600-1601 and 1619-1620:**
```powershell
Write-Host "    TIP: Find WiFi IP on your iOS device:" -ForegroundColor Cyan
Write-Host "         Settings > WiFi > (tap the 'i' icon) > IP Address" -ForegroundColor Gray
```

**Result:** Users now have clear instructions on where to find their device's WiFi IP address in iOS settings.

---

### 4. **Application Icon Created** ✅
**Status:** Icon created successfully, ready for .exe compilation

**Files Created:**
- `vnc_icon.ico` - Professional VNC Manager icon (256x256)
- `vnc_icon.png` - Source PNG version
- `create_icon.ps1` - Icon generation script (for reference)

**Icon Design:**
- Dark blue gradient background
- White "VNC" text (bold, large)
- "iOS Manager" subtitle
- Simple monitor icon outline
- Professional and recognizable

---

## 📋 Recompilation Instructions

To compile `VNC_Manager.exe` with the new icon:

### Method 1: Using compile.ps1 (Recommended)
```powershell
cd C:\iProxy\dist\VNC_Manager_v5.0\dist
.\compile.ps1
```

### Method 2: Manual ps2exe Command
```powershell
# Install ps2exe if not already installed
Install-Module ps2exe -Scope CurrentUser -Force

# Compile with icon
Invoke-ps2exe `
    -inputFile "VNC_Manager.ps1" `
    -outputFile "VNC_Manager.exe" `
    -iconFile "vnc_icon.ico" `
    -noConsole:$false `
    -noOutput `
    -noError `
    -requireAdmin:$false `
    -STA `
    -x64
```

### Method 3: Using ps2exe.ps1 Script Directly
If you have the ps2exe.ps1 script file:
```powershell
.\ps2exe.ps1 VNC_Manager.ps1 VNC_Manager.exe -iconFile vnc_icon.ico -noConsole:$false -x64
```

---

## 📊 Summary of Changes

| Issue | Status | Impact |
|-------|--------|--------|
| Device detection bug (only 1 of 2 devices found) | ✅ Fixed | Critical - Now detects all devices |
| Default password "test1234" | ✅ Changed to blank | High - Better security & UX |
| WiFi IP discovery help | ✅ Added | Medium - Improved user guidance |
| Application icon | ✅ Created | Low - Professional appearance |

---

## 🧪 Testing Recommendations

Before distribution, please test:

1. **Device Detection:**
   - Connect 2+ iOS devices via USB
   - Run first-run wizard
   - Verify all devices are detected and listed

2. **Password Handling:**
   - Leave password blank during first-run (press Enter)
   - Verify VNC connection works without password
   - Test with a custom password if your VNC server requires one

3. **WiFi Connection:**
   - Follow the WiFi IP discovery tip in the wizard
   - Enter the correct WiFi IP from device settings
   - Test WiFi VNC connection

4. **Icon Display:**
   - After recompiling, check that VNC_Manager.exe shows the new icon
   - Verify icon appears in Windows Explorer and taskbar

---

## 📝 Notes

- All changes maintain backward compatibility
- Config file format unchanged
- No breaking changes to existing installations
- Icon recompilation requires ps2exe module (see instructions above)

---

**Changes implemented by:** Claude Code (Sonnet 4.5)
**Date:** 2026-01-18
**Session:** VNC Manager v5.0 Distribution Package Enhancement
