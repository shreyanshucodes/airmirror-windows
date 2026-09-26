@echo off
:: Launch-Mirror-iPhone.cmd
:: Double-click launcher for iPhone Mirror for Windows
:: When double-clicked (no arguments), launches the modern desktop UI with zero console flash.
:: When arguments are passed, runs the command-line Mirror-iPhone.ps1 directly.

set "SCRIPT_DIR=%~dp0"
set "ROOT_DIR=%SCRIPT_DIR%..\"
set "UI_SCRIPT=%ROOT_DIR%airplay-ui.ps1"
set "PS_SCRIPT=%SCRIPT_DIR%Mirror-iPhone.ps1"

if "%~1"=="" (
    if exist "%UI_SCRIPT%" (
        set "PCAIRPLAY_UI=%UI_SCRIPT%"
        start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$ErrorActionPreference='Continue'; try { Add-Type -AssemblyName PresentationFramework; & $env:PCAIRPLAY_UI; if ($LASTEXITCODE) { throw ('airplay-ui.ps1 exited with code ' + $LASTEXITCODE + '.') } } catch { $m = 'iPhone Mirror failed to start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message; try { Set-Content -LiteralPath ($env:TEMP + '\pcairplay-crash.log') -Value ($m + [Environment]::NewLine + $_.ScriptStackTrace) } catch { }; try { [void][System.Windows.MessageBox]::Show($m, 'iPhone Mirror for Windows', 'OK', 'Error') } catch { }; exit 1 }"
        exit /b 0
    )
)

if not exist "%PS_SCRIPT%" (
    echo.
    echo ERROR: Could not find Mirror-iPhone.ps1
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "
try {
    Add-Type -AssemblyName PresentationFramework
    & '%PS_SCRIPT%' %*
    if ($LASTEXITCODE) {
        throw ('Mirror-iPhone.ps1 exited with code ' + $LASTEXITCODE + '.')
    }
} catch {
    $errorMsg = 'Screen Mirroring failed to start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message
    try {
        Set-Content -LiteralPath ('%TEMP%\ScreenMirroringError.log') -Value ($errorMsg + [Environment]::NewLine + $_.ScriptStackTrace)
    } catch {}
    try {
        [void][System.Windows.MessageBox]::Show($errorMsg, 'Screen Mirroring for iPhone', 'OK', 'Error')
    } catch {}
    exit 1
}
"
exit /b %errorlevel%