@echo off
rem Double-click launcher for iPhone Mirror for Windows (GUI)
set "PCAIRPLAY_UI=%~dp0airplay-ui.ps1"
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$ErrorActionPreference='Continue'; try { Add-Type -AssemblyName PresentationFramework; & $env:PCAIRPLAY_UI; if ($LASTEXITCODE) { throw ('airplay-ui.ps1 exited with code ' + $LASTEXITCODE + '.') } } catch { $m = 'iPhone Mirror failed to start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message; try { Set-Content -LiteralPath ($env:TEMP + '\pcairplay-crash.log') -Value ($m + [Environment]::NewLine + $_.ScriptStackTrace) } catch { }; try { [void][System.Windows.MessageBox]::Show($m, 'iPhone Mirror for Windows', 'OK', 'Error') } catch { }; exit 1 }"
