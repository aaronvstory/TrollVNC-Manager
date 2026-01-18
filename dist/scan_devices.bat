@echo off
setlocal enabledelayedexpansion
cd /d %~dp0

echo.
echo  ============================================
echo       iOS DEVICE SCANNER
echo  ============================================
echo.

set "count=0"
for /f "tokens=*" %%u in ('lib\idevice_id.exe -l 2^>nul') do (
    set /a count+=1
    set "udid=%%u"

    REM Get device name
    for /f "tokens=*" %%n in ('lib\ideviceinfo.exe -u %%u -k DeviceName 2^>nul') do set "name=%%n"

    REM Get product type
    for /f "tokens=*" %%p in ('lib\ideviceinfo.exe -u %%u -k ProductType 2^>nul') do set "product=%%p"

    REM Get iOS version
    for /f "tokens=*" %%v in ('lib\ideviceinfo.exe -u %%u -k ProductVersion 2^>nul') do set "version=%%v"

    echo   Device !count!:
    echo   Name:    !name!
    echo   Model:   !product!
    echo   iOS:     !version!
    echo   UDID:    !udid!
    echo.
)

if %count%==0 (
    echo   [!] No devices found. Check USB connections.
) else (
    echo  --------------------------------------------
    echo   Total: %count% device(s) connected
)
echo.
echo  ============================================
pause
