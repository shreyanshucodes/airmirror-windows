' Zero-flash double-click launcher for iPhone Mirror for Windows
Option Explicit
Dim sh, fso, env, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
Set env = sh.Environment("PROCESS")
env("PCAIRPLAY_UI") = fso.GetParentFolderName(WScript.ScriptFullName) & "\airplay-ui.ps1"
cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & _
      """$ErrorActionPreference='Continue'; try { Add-Type -AssemblyName PresentationFramework; & $env:PCAIRPLAY_UI; if ($LASTEXITCODE) { throw ('airplay-ui.ps1 exited with code ' + $LASTEXITCODE + '.') } } catch { $m = 'iPhone Mirror failed to start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message; try { Set-Content -LiteralPath ($env:TEMP + '\pcairplay-crash.log') -Value ($m + [Environment]::NewLine + $_.ScriptStackTrace) } catch { }; try { [void][System.Windows.MessageBox]::Show($m, 'iPhone Mirror for Windows', 'OK', 'Error') } catch { }; exit 1 }"""
sh.Run cmd, 0, False
