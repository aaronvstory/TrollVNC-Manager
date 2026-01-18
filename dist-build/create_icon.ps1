# Create a simple VNC Manager icon
Add-Type -AssemblyName System.Drawing

# Create a 256x256 bitmap
$bitmap = New-Object System.Drawing.Bitmap 256, 256
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)

# Set background to dark blue gradient
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    [System.Drawing.Point]::new(0, 0),
    [System.Drawing.Point]::new(256, 256),
    [System.Drawing.Color]::FromArgb(20, 50, 120),
    [System.Drawing.Color]::FromArgb(40, 100, 200)
)
$graphics.FillRectangle($brush, 0, 0, 256, 256)

# Draw "VNC" text in white
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$font = New-Object System.Drawing.Font("Arial", 72, [System.Drawing.FontStyle]::Bold)
$textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
$format = New-Object System.Drawing.StringFormat
$format.Alignment = [System.Drawing.StringAlignment]::Center
$format.LineAlignment = [System.Drawing.StringAlignment]::Center
$graphics.DrawString("VNC", $font, $textBrush, 128, 100, $format)

# Draw "iOS" in smaller text
$smallFont = New-Object System.Drawing.Font("Arial", 32, [System.Drawing.FontStyle]::Regular)
$graphics.DrawString("iOS Manager", $smallFont, $textBrush, 128, 180, $format)

# Add a simple monitor icon outline
$pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 4)
$graphics.DrawRectangle($pen, 70, 40, 116, 80)  # Screen
$graphics.DrawLine($pen, 128, 120, 128, 140)     # Stand
$graphics.DrawLine($pen, 108, 140, 148, 140)     # Base

# Save as PNG first
$pngPath = Join-Path $PSScriptRoot "vnc_icon.png"
$bitmap.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)

# Convert to ICO format
$icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
$iconPath = Join-Path $PSScriptRoot "vnc_icon.ico"
$iconStream = [System.IO.FileStream]::new($iconPath, [System.IO.FileMode]::Create)
$icon.Save($iconStream)
$iconStream.Close()

# Cleanup
$graphics.Dispose()
$bitmap.Dispose()
$icon.Dispose()

Write-Host "Icon created: $iconPath" -ForegroundColor Green
