@echo off
:: Create Desktop Shortcut for AirMirror
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "TARGET=%SCRIPT_DIR%Launch-iPhone-Mirror.vbs"
set "ICON=%SCRIPT_DIR%pcairplay.ico"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$wsh = New-Object -ComObject WScript.Shell; " ^
    "$desktop = [Environment]::GetFolderPath('Desktop'); " ^
    "$sc = $wsh.CreateShortcut(\"$desktop\AirMirror for Windows.lnk\"); " ^
    "$sc.TargetPath = 'wscript.exe'; " ^
    "$sc.Arguments = '\"%TARGET%\"'; " ^
    "$sc.WorkingDirectory = '%SCRIPT_DIR%'; " ^
    "$sc.IconLocation = '%ICON%, 0'; " ^
    "$sc.Description = 'AirMirror: Wireless AirPlay Receiver for Windows 10 & 11'; " ^
    "$sc.Save(); " ^
    "Write-Host '✅ Desktop shortcut created: AirMirror for Windows.lnk' -ForegroundColor Green"

echo.
pause
