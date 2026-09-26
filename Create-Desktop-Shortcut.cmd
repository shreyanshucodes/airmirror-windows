@echo off
:: Create Desktop Shortcut for iPhone Mirror for Windows
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "TARGET=%SCRIPT_DIR%Launch-iPhone-Mirror.vbs"
set "ICON=%SCRIPT_DIR%pcairplay.ico"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$wsh = New-Object -ComObject WScript.Shell; " ^
    "$desktop = [Environment]::GetFolderPath('Desktop'); " ^
    "$sc = $wsh.CreateShortcut(\"$desktop\iPhone Mirror for Windows.lnk\"); " ^
    "$sc.TargetPath = 'wscript.exe'; " ^
    "$sc.Arguments = '\"%TARGET%\"'; " ^
    "$sc.WorkingDirectory = '%SCRIPT_DIR%'; " ^
    "$sc.IconLocation = '%ICON%, 0'; " ^
    "$sc.Description = 'Mirror your iPhone screen to Windows wirelessly via AirPlay'; " ^
    "$sc.Save(); " ^
    "Write-Host '✅ Desktop shortcut created: iPhone Mirror for Windows.lnk' -ForegroundColor Green"

echo.
pause
