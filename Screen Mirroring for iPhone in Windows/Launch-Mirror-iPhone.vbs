' Launch-Mirror-iPhone.vbs
' Zero-flash double-click launcher for iPhone Mirror for Windows (GUI)
Option Explicit
Dim sh, fso, env, cmd, scriptDir, uiScript

Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
uiScript = fso.GetParentFolderName(scriptDir) & "\airplay-ui.ps1"

If Not fso.FileExists(uiScript) Then
    uiScript = scriptDir & "\Mirror-iPhone.ps1"
End If

Set env = sh.Environment("PROCESS")
env("PCAIRPLAY_UI") = uiScript

cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command " & _
      """$ErrorActionPreference='Continue'; try { Add-Type -AssemblyName PresentationFramework; & $env:PCAIRPLAY_UI; if ($LASTEXITCODE) { throw ('UI exited with code ' + $LASTEXITCODE + '.') } } catch { $m = 'iPhone Mirror failed to start.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message; try { Set-Content -LiteralPath ($env:TEMP + '\pcairplay-crash.log') -Value ($m + [Environment]::NewLine + $_.ScriptStackTrace) } catch { }; try { [void][System.Windows.MessageBox]::Show($m, 'iPhone Mirror for Windows', 'OK', 'Error') } catch { }; exit 1 }"""

sh.Run cmd, 0, False