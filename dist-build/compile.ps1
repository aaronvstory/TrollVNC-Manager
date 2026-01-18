# Compile VNC_Manager.ps1 to .exe with icon
$ErrorActionPreference = "Stop"

# Check if ps2exe is available
try {
    Import-Module ps2exe -ErrorAction Stop
} catch {
    Write-Host "Installing ps2exe module..." -ForegroundColor Yellow
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
    Import-Module ps2exe
}

# Compile with icon
$scriptPath = Join-Path $PSScriptRoot "VNC_Manager.ps1"
$exePath = Join-Path $PSScriptRoot "VNC_Manager.exe"
$iconPath = Join-Path $PSScriptRoot "vnc_icon.ico"

Write-Host "Compiling VNC_Manager.ps1 to VNC_Manager.exe..." -ForegroundColor Cyan

Invoke-ps2exe `
    -inputFile $scriptPath `
    -outputFile $exePath `
    -iconFile $iconPath `
    -noConsole:$false `
    -noOutput `
    -noError `
    -requireAdmin:$false `
    -STA `
    -x64

if (Test-Path $exePath) {
    $size = (Get-Item $exePath).Length
    Write-Host "✓ Compilation successful! Size: $([math]::Round($size/1KB, 2)) KB" -ForegroundColor Green
} else {
    Write-Host "✗ Compilation failed!" -ForegroundColor Red
}
