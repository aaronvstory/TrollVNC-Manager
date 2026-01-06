#Requires -Version 5.1
<#
.SYNOPSIS
    VNC Manager v5.0 - PowerShell Edition
.DESCRIPTION
    Modern iOS VNC connection manager with smart device detection,
    TightVNC/RealVNC support, and beautiful CLI interface.
#>

# ============================================================
#  CONFIGURATION
# ============================================================
$Script:Config = @{
    ConfigFile    = Join-Path $PSScriptRoot "device_config.ini"
    LibDir        = Join-Path $PSScriptRoot "lib"
    VncPassword   = "test1234"
    QualityPreset = 3
    VcamMode      = $false
    ViewerPref    = "TightVNC"  # TightVNC or RealVNC
}

$Script:Devices = @{
    1 = @{ UDID = ""; Name = "Device 1"; IP = "0.0.0.0"; Port = 5901 }
    2 = @{ UDID = ""; Name = "Device 2"; IP = "0.0.0.0"; Port = 5902 }
}

$Script:QualityPresets = @{
    1 = @{ Name = "Ultra";    TightFlags = "-encoding=tight -jpegimagequality=9 -compressionlevel=1"; RealFlags = "-Quality High -ColorLevel full -AutoReconnect" }
    2 = @{ Name = "High";     TightFlags = "-encoding=tight -jpegimagequality=7 -compressionlevel=3"; RealFlags = "-Quality High -AutoReconnect" }
    3 = @{ Name = "Balanced"; TightFlags = "-encoding=tight -jpegimagequality=5 -compressionlevel=5"; RealFlags = "-Quality Medium -AutoReconnect" }
    4 = @{ Name = "Stable";   TightFlags = "-encoding=tight -jpegimagequality=3 -compressionlevel=7"; RealFlags = "-Quality Low -ColorLevel rgb222 -AutoReconnect" }
    5 = @{ Name = "Minimal";  TightFlags = "-encoding=tight -jpegimagequality=1 -compressionlevel=9"; RealFlags = "-Quality Low -ColorLevel rgb111 -AutoReconnect" }
}

# ============================================================
#  UI HELPERS
# ============================================================
function Write-Header {
    param([string]$Title, [string]$Subtitle = "")
    Clear-Host
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

function Write-Success { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Error { param([string]$Msg) Write-Host "  ✗ $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "  → $Msg" -ForegroundColor Cyan }
function Write-Warning { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }

# ============================================================
#  DEVICE MANAGEMENT
# ============================================================
function Get-ConnectedDevices {
    $ideviceId = Join-Path $Script:Config.LibDir "idevice_id.exe"
    $ideviceInfo = Join-Path $Script:Config.LibDir "ideviceinfo.exe"

    if (-not (Test-Path $ideviceId)) {
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

    $idevicePair = Join-Path $Script:Config.LibDir "idevicepair.exe"
    if (-not (Test-Path $idevicePair)) { return $false }

    $result = & $idevicePair -u $UDID validate 2>&1
    return $result -match "SUCCESS"
}

# ============================================================
#  CONFIG MANAGEMENT
# ============================================================
function Import-Config {
    if (-not (Test-Path $Script:Config.ConfigFile)) { return }

    Get-Content $Script:Config.ConfigFile | ForEach-Object {
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
                "VIEWER_PREF"    { $Script:Config.ViewerPref = if ($value -eq "2") { "RealVNC" } else { "TightVNC" } }
            }
        }
    }
}

function Export-Config {
    $viewerNum = if ($Script:Config.ViewerPref -eq "RealVNC") { "2" } else { "1" }
    $vcamNum = if ($Script:Config.VcamMode) { "1" } else { "0" }

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
"@ | Set-Content $Script:Config.ConfigFile -Encoding UTF8
}

# ============================================================
#  VNC VIEWERS
# ============================================================
function Get-VncViewer {
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

    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
}

function Stop-AllTunnels {
    Write-Info "Stopping all tunnels..."
    Stop-Tunnel 5901
    Stop-Tunnel 5902
    Stop-Process -Name tvnviewer -Force -ErrorAction SilentlyContinue
    Stop-Process -Name vncviewer -Force -ErrorAction SilentlyContinue
    Stop-Process -Name iproxy -Force -ErrorAction SilentlyContinue
    Write-Success "All tunnels stopped"
}

function Start-Tunnel {
    param([string]$UDID, [int]$LocalPort, [int]$RemotePort = 5901)

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
    foreach ($num in 1, 2) {
        if ($Script:Devices[$num].UDID) {
            Connect-USB -DeviceNum $num
            Start-Sleep -Milliseconds 500
        }
    }
}

function Connect-BothWiFi {
    foreach ($num in 1, 2) {
        if ($Script:Devices[$num].IP -ne "0.0.0.0") {
            Connect-WiFi -DeviceNum $num
            Start-Sleep -Milliseconds 500
        }
    }
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
            "B" { return }
        }
    }
}

# ============================================================
#  MAIN MENU
# ============================================================
function Show-MainMenu {
    $tunnels = Get-TunnelStatus
    $tunnelStr = if ($tunnels.Port5901 -and $tunnels.Port5902) { "Both" }
                 elseif ($tunnels.Port5901) { "5901" }
                 elseif ($tunnels.Port5902) { "5902" }
                 else { "None" }
    $tunnelColor = if ($tunnelStr -eq "None") { "DarkGray" } else { "Green" }

    $qualityName = $Script:QualityPresets[$Script:Config.QualityPreset].Name
    $vcamStr = if ($Script:Config.VcamMode) { "ON" } else { "OFF" }
    $vcamColor = if ($Script:Config.VcamMode) { "Green" } else { "DarkGray" }

    Write-Header "VNC MANAGER v5.0" "PowerShell Edition"

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
    Write-MenuItem "1" "$($Script:Devices[1].Name)" ":$($Script:Devices[1].Port)"
    Write-MenuItem "2" "$($Script:Devices[2].Name)" ":$($Script:Devices[2].Port)"
    Write-MenuItem "B" "Both USB"
    Write-Host ""
    Write-SectionEnd

    # WiFi Connections
    $wifi1Str = if ($Script:Devices[1].IP -eq "0.0.0.0") { "(not set)" } else { "($($Script:Devices[1].IP))" }
    $wifi2Str = if ($Script:Devices[2].IP -eq "0.0.0.0") { "(not set)" } else { "($($Script:Devices[2].IP))" }

    Write-Section "WIFI"
    Write-Host ""
    Write-MenuItem "3" "$($Script:Devices[1].Name)" "$wifi1Str"
    Write-MenuItem "4" "$($Script:Devices[2].Name)" "$wifi2Str"
    Write-MenuItem "W" "Both WiFi"
    Write-Host ""
    Write-SectionEnd

    # Quick Actions
    Write-Section "ACTIONS"
    Write-Host ""
    Write-MenuItem "S" "Settings" "(devices, quality, WiFi IPs)"
    Write-MenuItem "V" "Switch Viewer" "($($Script:Config.ViewerPref))"
    Write-MenuItem "K" "Kill Tunnels"
    Write-MenuItem "X" "Exit"
    Write-Host ""
    Write-SectionEnd
}

# ============================================================
#  MAIN LOOP
# ============================================================
function Main {
    Import-Config

    while ($true) {
        Show-MainMenu
        $choice = Read-Host "  Select"

        switch ($choice.ToUpper()) {
            "1" { Connect-USB 1 }
            "2" { Connect-USB 2 }
            "B" { Connect-BothUSB }
            "3" { Connect-WiFi 1 }
            "4" { Connect-WiFi 2 }
            "W" { Connect-BothWiFi }
            "S" { Show-SettingsMenu }
            "V" { Switch-Viewer; Start-Sleep -Seconds 1 }
            "K" { Stop-AllTunnels; Start-Sleep -Seconds 1 }
            "X" { return }
        }

        Start-Sleep -Milliseconds 500
    }
}

# Run
Main
