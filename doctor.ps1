<#
.SYNOPSIS
    Diagnoses why the iPhone can't see or connect to this PC's AirPlay receiver.
.DESCRIPTION
    Runs through the failure causes in the order they actually bite, and prints a
    specific fix for each. Safe to run any time - makes no changes.

    Read-only is a hard rule here: this script must never create, enable, disable
    or delete a firewall rule, service, process or network profile. Every fix it
    knows about is printed for the user to run, not executed.
.PARAMETER PhoneIP
    Optional. The iPhone's IPv4 address (Settings -> Wi-Fi -> tap the (i) next to
    the network). Supplying it enables the subnet-match and reachability tests,
    which is the single most useful check for a wired-PC / Wi-Fi-phone setup.
    Must be a plain dotted quad - see check 7.
.PARAMETER ReceiverName
    The name the receiver advertises, used by check 6 to tell this PC's own mDNS
    entry apart from a neighbour's Apple TV. Only needed when the receiver is not
    running: while it is, doctor reads the real name off its command line.
    Defaults to $env:COMPUTERNAME (airplay-ui.ps1's default); start-airplay.ps1
    defaults to "PC", and both are accepted unless you pass this explicitly.
.OUTPUTS
    Exit code 0 = no blocking problems, 1 = at least one [FAIL],
    2 = doctor itself stopped early and the report is incomplete.
.EXAMPLE
    .\doctor.ps1
.EXAMPLE
    .\doctor.ps1 -PhoneIP 192.168.1.42
.EXAMPLE
    .\doctor.ps1 -ReceiverName 'Demo Screen'
#>
[CmdletBinding()]
param(
    [string]$PhoneIP,
    [string]$ReceiverName = $env:COMPUTERNAME
)

# Individual checks guard their own cmdlets, so a non-terminating error stays a
# check result rather than aborting the run. Anything that does throw must not
# leave a half-printed report that reads like a clean bill of health - the trap
# says so out loud and exits non-zero.
$ErrorActionPreference = 'Continue'
trap {
    Write-Host ""
    Write-Host "  [FAIL] doctor.ps1 stopped early: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "         The report above is INCOMPLETE - do not read it as a pass." -ForegroundColor Yellow
    Write-Host ""
    exit 2
}

. (Join-Path $PSScriptRoot 'uxplay-common.ps1')

$script:problems = @()

function Write-Head { param($m) Write-Host "`n== $m" -ForegroundColor Cyan }
function Pass { param($m) Write-Host "  [PASS] $m" -ForegroundColor Green }
function Fail { param($m, $fix)
    Write-Host "  [FAIL] $m" -ForegroundColor Red
    if ($fix) { Write-Host "         FIX: $fix" -ForegroundColor Yellow }
    $script:problems += $m
}
function Info { param($m) Write-Host "  [info] $m" -ForegroundColor Gray }
function Warn { param($m) Write-Host "  [warn] $m" -ForegroundColor Yellow }

function ConvertTo-UInt32 ([string]$ip) {
    # Reject non-IPv4 explicitly. [IPAddress]::Parse happily accepts an IPv6
    # address, whose 16 reversed bytes then give BitConverter a meaningless
    # number instead of throwing - so the subnet check would print a confident,
    # wrong "the phone is on a guest SSID" verdict.
    $a = [System.Net.IPAddress]::Parse($ip)
    if ($a.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "'$ip' is not an IPv4 address."
    }
    $b = $a.GetAddressBytes()
    [Array]::Reverse($b)
    [BitConverter]::ToUInt32($b, 0)
}

function Get-EngineListeningPort {
    # Must re-query the socket table on every call: re-testing a snapshot taken
    # before the process list would produce the same answer twice and defeat the
    # re-sample in check 5.
    param($Process)
    $ids = @($Process | Select-Object -ExpandProperty Id)
    @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
      Where-Object { $ids -contains $_.OwningProcess } |
      Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
}

Write-Host "AirPlayPC - diagnostics" -ForegroundColor White

# --- 1. UxPlay present ----------------------------------------------------
Write-Head "1. UxPlay installed"
$ux = Find-UxPlay
if (-not $ux) {
    Fail "uxplay.exe not found." "Run setup.ps1 as Administrator."
} elseif ($ux.Kind -eq 'GuiOnly') {
    # The 2.x Qt6 rewrite links uxplay in as a library and ships no uxplay.exe,
    # so there is no command line for these scripts to drive. Reporting "engine
    # found" here would send the user hunting for a network fault that isn't one.
    Fail "UxPlay is installed, but it is the 2.x GUI-only build - there is no engine to drive."
    foreach ($line in ((Get-UxPlayIncompatibleMessage -UxPlay $ux) -split "`n")) { Info $line }
} else {
    Pass "Engine found: $($ux.Exe)"
    if ($ux.Version) { Info "Installed version: $($ux.Version)" }

    # The most common "runs but black window" cause: GStreamer plugins not found.
    if ($ux.PluginDir) {
        Pass "GStreamer plugin dir: $($ux.PluginDir)"
        if (Test-Path (Join-Path $ux.PluginDir 'libgstd3d11.dll')) {
            Pass "d3d11 video sink plugin present (hardware-accelerated display)."
        } else {
            Warn "d3d11 plugin missing - video will fall back to a slower sink."
        }
    } else {
        Fail "No gstreamer-1.0 plugin directory found near the engine." `
             "Reinstall UxPlay (setup.ps1). Without plugins the receiver starts but shows no video."
    }
}

# --- 2. mDNS responder ----------------------------------------------------
# The 1.72 engine has NO mDNS responder of its own. Verified on the installed
# build: uxplay.exe resolves DNSServiceRegister out of dnssd.dll at runtime, and
# the install tree ships no dnssd.dll / mDNSResponder.exe - only libmicrodns,
# which is a GStreamer client plugin, not a responder. dnssd.dll and the
# responder behind it both come from Apple Bonjour, so Bonjour is REQUIRED here.
# (Only the 2.x GUI build compiles in its own mDNSResponder.exe.)
Write-Head "2. mDNS responder"
$guiOnly = ($ux -and $ux.Kind -eq 'GuiOnly')
$bonjour = Get-Service -Name 'Bonjour Service' -ErrorAction SilentlyContinue
if ($guiOnly) {
    if ($bonjour -and $bonjour.Status -eq 'Running') {
        Pass "Apple Bonjour is running."
    } else {
        Info "Apple Bonjour is not running, which is fine for the 2.x app - it"
        Info "  bundles its own mDNSResponder.exe. The 1.72 engine these scripts"
        Info "  drive would need Bonjour."
    }
} elseif (-not $bonjour) {
    Fail "Apple Bonjour is not installed, and UxPlay 1.72 has no mDNS responder of its own." `
         "Nothing can advertise this PC without it. Install Apple Devices (or iTunes) from the Microsoft Store, which installs Bonjour, then re-run this script."
} elseif ($bonjour.Status -ne 'Running') {
    Fail "Apple Bonjour is installed but $($bonjour.Status)." `
         "The engine registers its AirPlay service through Bonjour, so the PC will never appear on the iPhone until it runs: Start-Service 'Bonjour Service'   (elevated)"
} else {
    Pass "Apple Bonjour is running."
    # Bonjour puts dnssd.dll in System32; the engine loads it by name at runtime.
    if (-not (Test-Path "$env:SystemRoot\System32\dnssd.dll")) {
        Warn "The service is running but $env:SystemRoot\System32\dnssd.dll is missing."
        Info "  The engine loads that DLL by name to register itself. Repair the"
        Info "  Bonjour install (Apple Devices / iTunes) if discovery fails."
    }
    # "Running" is not "reachable". mDNSResponder needs its own network-facing
    # UDP 5353 sockets, and those binds are first-come: on 2026-07-20 the Apple
    # Devices helpers (installed for the USB tether!) held the LAN one, so the
    # engine registered successfully into a responder that could not hear or
    # answer anything. Every other check passed; Wi-Fi discovery was dead while
    # USB-tether sessions still worked. This check exists for exactly that day.
    $sock = Get-BonjourSocketState
    if ($sock.State -eq 'Deaf') {
        $holders = if ($sock.Holders.Count -gt 0) { $sock.Holders -join ', ' } else { 'unknown' }
        Fail "Bonjour is running but holds NO network mDNS socket - it is deaf, and this PC is invisible over Wi-Fi/LAN. UDP 5353 is held by: $holders" `
             "In an ELEVATED PowerShell, run both in ONE line (the Apple helpers re-grab a freed port within seconds): Stop-Process -Name AMPDevicesAgent,AppleMobileDeviceLauncher -Force -ErrorAction SilentlyContinue; Restart-Service 'Bonjour Service'   - they respawn harmlessly when the iPhone is next plugged in. Note: USB-tether mirroring can still work while this is broken, which disguises it as 'Wi-Fi doesn't work'."
    } elseif ($sock.State -eq 'Listening') {
        Pass "mDNSResponder is listening on the network: $($sock.Endpoints -join ', ')"
        if ($sock.Holders.Count -gt 0) {
            Info "  Also on 5353 (normal coexistence): $($sock.Holders -join ', ')"
        }
    }
}

# --- 3. Network interface -------------------------------------------------
Write-Head "3. Network interface"
$adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue -ErrorVariable adErr |
              Where-Object { $_.Status -eq 'Up' })
if ($adErr) {
    # Distinguish "the query failed" from "there is no adapter" - silently
    # treating a broken NetAdapter module as "no adapter is up" is a wrong
    # diagnosis, not a missing one.
    Warn "Could not enumerate network adapters: $($adErr[0].Exception.Message)"
} elseif ($adapters.Count -eq 0) {
    Fail "No network adapter is up." "Check the cable."
} else {
    if ($adapters.Count -gt 1) {
        Warn "$($adapters.Count) adapters are up. Bonjour may advertise the wrong IP."
        foreach ($a in $adapters) { Info "  - $($a.InterfaceAlias): $($a.InterfaceDescription)" }
        Info "  If mirroring fails, disable the unused ones (VPN / Hyper-V / Wi-Fi) and retry."
    }
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue -ErrorVariable ipErr |
             Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })
    if ($ipErr) {
        Warn "Could not read IPv4 addresses: $($ipErr[0].Exception.Message)"
    } elseif ($ips.Count -eq 0) {
        Fail "No usable IPv4 address." "Check DHCP / cable."
    } else {
        foreach ($ip in $ips) { Pass "$($ip.InterfaceAlias) = $($ip.IPAddress)/$($ip.PrefixLength)" }
    }
}

$profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue -ErrorVariable profErr)
if ($profErr -or $profiles.Count -eq 0) {
    # Never let pitfall #1 vanish without a line of its own.
    Warn "Could not read the network connection profile - the Public-profile check was skipped."
} else {
    foreach ($p in $profiles) {
        if ($p.NetworkCategory -eq 'Public') {
            Warn "'$($p.InterfaceAlias)' is on the Public profile."
            Info "  Explicit firewall rules (below) usually cover this. If discovery still"
            Info "  fails, run: setup.ps1 -SetNetworkPrivate"
        } else {
            Pass "'$($p.InterfaceAlias)' profile = $($p.NetworkCategory)"
        }
    }
}

# --- 4. Firewall ----------------------------------------------------------
Write-Head "4. Firewall rules"
# Rule names come from uxplay-common.ps1, so setup.ps1 (which creates them) and
# this script (which verifies them) cannot drift. Two copies of a DisplayName
# drift silently and leave setup saying "already present" while doctor says
# "missing, run setup" - forever, with the firewall perfectly correct.
foreach ($rule in @(Get-PCAirPlayPortRule)) {
    $n = $rule.Name
    switch (Get-FirewallRuleState $n) {
        'Missing' {
            # Deliberately NOT a Fail. Without -p the engine binds an ephemeral
            # port, so these fixed-port rules cover nothing in normal use (check
            # 5 says the same); the program-scoped rule below is what actually
            # permits traffic. Failing here sent users into an elevated re-run
            # of setup.ps1 to fix a receiver that already worked.
            Warn "Missing rule: $n (only matters if you start with -Port 7000)"
        }
        'Disabled' {
            Warn "Rule disabled: $n (only matters if you start with -Port 7000)"
            Info "  Enable-NetFirewallRule -DisplayName '$n'   (elevated)"
        }
        default { Pass $n }
    }
}

# Block beats Allow in Windows Firewall, so a single stray block rule defeats
# every Allow rule above and nothing else in this script would notice. The usual
# source is a dismissed "Windows Security Alert" - easy to miss here because
# airplay-ui.ps1 minimises the engine console and "AirPlayPC.cmd" hides its own.
$blockRules = @(Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue)
$blockHits = @()
if ($blockRules.Count -gt 0) {
    $byName = @{}
    foreach ($r in $blockRules) { $byName[$r.Name] = $r.DisplayName }
    foreach ($f in @($blockRules | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)) {
        if ($f.Program -and $f.Program -ne 'Any' -and $f.Program -match 'uxplay') {
            $blockHits += [pscustomobject]@{ Rule = $byName[$f.InstanceID]; Detail = $f.Program }
        }
    }
    foreach ($f in @($blockRules | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)) {
        # Overlap against Get-PCAirPlayPortRule, not a hardcoded list: the old
        # list omitted UDP 7011 and the RTP range, and could not see a block
        # rule written as a range.
        $hitPorts = Test-PCAirPlayPortOverlap -LocalPort $f.LocalPort
        if ($hitPorts) {
            $blockHits += [pscustomobject]@{
                Rule   = $byName[$f.InstanceID]
                Detail = "$($f.Protocol) port $hitPorts"
            }
        }
    }
}
if ($blockHits.Count -eq 0) {
    Pass "No inbound BLOCK rule targets the engine or the AirPlay ports."
} else {
    foreach ($b in $blockHits) {
        Fail "An inbound BLOCK rule matches AirPlay traffic: '$($b.Rule)' -> $($b.Detail)" `
             "Block overrides Allow, so this defeats every rule above. Inspect it, then remove or disable it: Disable-NetFirewallRule -DisplayName '$($b.Rule)'   (elevated)"
    }
}

# --- 4b. Third-party firewall ---------------------------------------------
# A third-party suite can block mDNS with its own rules, so every Windows
# Firewall check passes while the PC still never appears on the iPhone.
Write-Head "4b. Third-party firewall / security suite"
# MsMpEng (Microsoft Defender) is deliberately NOT in this list. It ships with
# Windows and is antimalware, not a separate firewall, so including it made the
# [PASS] branch unreachable on a stock PC and pointed users at "pause your
# firewall" advice that has no such setting to pause.
$suites = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match '^(ekrn|egui|avp|avgui|mbam|nortonsecurity|ns|bdagent|vsserv|McAPExe)$' } |
    Select-Object -ExpandProperty ProcessName -Unique)
if ($suites.Count -eq 0) {
    Pass "No third-party firewall detected."
} else {
    foreach ($s in $suites) {
        switch -Regex ($s) {
            '^(ekrn|egui)$'         { Warn "ESET Security is running." }
            '^avp$'                 { Warn "Kaspersky is running." }
            '^(bdagent|vsserv)$'    { Warn "Bitdefender is running." }
            '^(nortonsecurity|ns)$' { Warn "Norton is running." }
            default                 { Warn "Security suite '$s' is running." }
        }
    }
    Info "  These have their own firewall, independent of Windows Firewall."
    Info "  If the PC never appears on the iPhone but every check here passes,"
    Info "  set the current network to 'Home/Trusted' in the suite, or briefly"
    Info "  pause its firewall to confirm whether it is the cause."
}
if (Get-Process -Name 'MsMpEng' -ErrorAction SilentlyContinue) {
    Info "Microsoft Defender is active. It is antimalware, not a separate firewall -"
    Info "  check 4 above already covers Windows Firewall, so there is nothing extra to pause."
}

# --- 5. Ports -------------------------------------------------------------
Write-Head "5. Port availability"
$conns = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)

# A second AirPlay receiver is worse than a port clash: it also advertises,
# so the iPhone shows two entries and the wrong one gets picked.
$rivals = @(Get-CompetingReceiverProcess)
if ($rivals.Count -gt 0) {
    $names = ($rivals | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
    Fail "Another AirPlay receiver is running: $names" `
         "Close it. It holds port 7000 and shows a second device in the iPhone's mirroring list. Stop-Process -Name $($rivals[0].ProcessName) -Force"
} else {
    Pass "No competing AirPlay receiver app is running."
}

# Get-CompetingReceiverProcess only knows six names, so any other holder of the
# fixed ports (a renamed build, a dev server, an OBS plugin) would otherwise be
# invisible and -Port 7000 would just fail to bind with no explanation.
# The port list comes from Get-PCAirPlayPortRule, not a literal: the hardcoded
# '7000, 7001, 7100' here was the same drift the block-rule scan already had.
$knownIds = @($rivals | Select-Object -ExpandProperty Id)
$fixedTcpPorts = @(@(Get-PCAirPlayPortRule) | Where-Object { $_.Protocol -eq 'TCP' } |
                   ForEach-Object { $_.Port } | Where-Object { $_ -match '^\d+$' } |
                   ForEach-Object { [int]$_ })
foreach ($port in $fixedTcpPorts) {
    # -Unique collapses the 0.0.0.0 / :: pair a dual-stack listener produces.
    foreach ($holder in @($conns | Where-Object { $_.LocalPort -eq $port } |
                          Select-Object -ExpandProperty OwningProcess -Unique)) {
        if ($holder -in $knownIds) { continue }      # already reported just above
        $owner = Get-Process -Id $holder -ErrorAction SilentlyContinue
        if ($owner -and $owner.ProcessName -eq 'uxplay') { continue }   # our own engine on -Port 7000
        if ($owner) {
            Warn "TCP $port is held by '$($owner.ProcessName)' (PID $($owner.Id))."
        } else {
            Warn "TCP $port is held by PID $holder (name hidden - run doctor.ps1 elevated to see it)."
        }
        Info "  Only matters if you start with -Port $port; by default UxPlay uses an ephemeral port."
    }
}

# Where is the engine actually listening? Without -p, UxPlay does NOT use 7000:
# it lets the OS pick an ephemeral port (observed: 49408) and publishes that port
# in the mDNS record, which is how the iPhone finds it. So checking only 7000
# would report "not running" while the receiver is running perfectly.
$engineProcs = @(Get-UxPlayEngineProcess)

# What name is the engine advertising? start-airplay.ps1 defaults to 'PC',
# airplay-ui.ps1 defaults its box to $env:COMPUTERNAME, and both pass -nh, so the
# mDNS instance name is exactly the -n value. Read it off the running process
# rather than guessing - check 6 grades itself against this. Get-Process has no
# CommandLine in PS 5.1, hence Win32_Process.
$advertisedNames = @()
foreach ($c in @(Get-CimInstance Win32_Process -Filter "Name='uxplay.exe'" -ErrorAction SilentlyContinue)) {
    # '-n ' with the space is what distinguishes it from -nc / -nh / -nohold.
    if ($c.CommandLine -match '(?:^|\s)-n\s+(?:"([^"]*)"|(\S+))') {
        if ($matches[1]) { $advertisedNames += $matches[1] } else { $advertisedNames += $matches[2] }
    }
}

if ($engineProcs.Count -eq 0) {
    Info "Receiver not running yet - that's fine, start it when you're ready."
} else {
    $listening = Get-EngineListeningPort -Process $engineProcs
    if ($listening.Count -eq 0) {
        # Re-sample once before calling it stuck. airplay-ui.ps1's Diagnose button
        # can run doctor milliseconds after Start, and an engine that has only just
        # launched has not bound yet - failing on the first empty sample would
        # red-flag a healthy receiver mid-startup.
        Start-Sleep -Seconds 2
        $engineProcs = @(Get-UxPlayEngineProcess)
        if ($engineProcs.Count -gt 0) { $listening = Get-EngineListeningPort -Process $engineProcs }
    }

    if ($engineProcs.Count -eq 0) {
        Info "Receiver exited while checking - start it again when you're ready."
    } elseif ($listening.Count -gt 0) {
        Pass "Receiver is running and listening on TCP $($listening -join ', ')."
        if ($listening -notcontains 7000) {
            Info "  Note: this is an ephemeral port, not 7000. That is normal without -p."
            Info "  The iPhone reads the port from the mDNS record, so this is fine -"
            Info "  but it means the fixed 7000/7001/7100 firewall rules do NOT cover it."
            Info "  The program-scoped rule for uxplay.exe is what actually permits traffic."
        }
    } else {
        # Two fresh samples, two seconds apart, both empty: the engine really is
        # stuck. This is the documented stall - it is a hard blocker, not a Warn.
        Fail "uxplay.exe is running but is not listening on any TCP port." `
             "It never bound its RTSP socket, so it has not registered over mDNS either. The usual cause is launching it without a real console (a PowerShell background job), where it stalls before initialising GStreamer. Close it and start it with .\start-airplay.ps1 or 'AirPlayPC.cmd'."
    }
}

# The program-scoped rule is load-bearing precisely because of the above.
$progRuleName = Get-PCAirPlayProgramRuleName
switch (Get-FirewallRuleState $progRuleName) {
    'Missing' {
        Fail "Missing the program-scoped firewall rule for uxplay.exe." `
             "Run setup.ps1 as Administrator. Without it, an ephemeral port is blocked and the phone can see the PC but never connect."
    }
    'Disabled' {
        Fail "The uxplay.exe firewall rule exists but is DISABLED." `
             "Enable-NetFirewallRule -DisplayName '$progRuleName'   (elevated)"
    }
    default {
        Pass "Program-scoped firewall rule for uxplay.exe is active (covers any port)."
        # A rule pointing at a stale path allows nothing, and the symptom - the
        # phone sees the PC and then fails to connect - looks exactly like a
        # protocol problem. Print the one-liner that repairs it directly: a user
        # hitting this needs a fix that works now, not only after a full re-run.
        $ruleApp = Get-NetFirewallRule -DisplayName $progRuleName -ErrorAction SilentlyContinue |
                   Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
        $ruleProgram = @($ruleApp | Select-Object -ExpandProperty Program -ErrorAction SilentlyContinue)
        if ($ux -and $ux.Exe -and $ruleProgram.Count -gt 0 -and $ruleProgram -notcontains $ux.Exe) {
            Fail "That rule points at '$($ruleProgram -join ', ')' but the engine is at '$($ux.Exe)'." `
                 "The path changed (probably a version upgrade). Fix it now in an elevated PowerShell: Set-NetFirewallRule -DisplayName '$progRuleName' -Program '$($ux.Exe)'   - or re-run setup.ps1 as Administrator, which repoints it."
        }
    }
}

# --- 6. mDNS advertisement ------------------------------------------------
Write-Head "6. mDNS - is this PC advertising AirPlay?"
$dnssd = Get-Command dns-sd -ErrorAction SilentlyContinue
if (-not $dnssd) {
    # Bonjour installs dns-sd.exe into System32, not its own Program Files dir.
    $dnssd = @(
        "$env:SystemRoot\System32\dns-sd.exe"
        "$env:ProgramFiles\Bonjour\dns-sd.exe"
        "${env:ProgramFiles(x86)}\Bonjour\dns-sd.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
} else { $dnssd = $dnssd.Source }

if (-not $dnssd) {
    Warn "dns-sd.exe not found - skipping the live mDNS browse."
} else {
    Info "Browsing for _airplay._tcp for 5 seconds..."
    # dns-sd -B never exits and has no working -timeout in this build, so it has
    # to be a job that gets stopped explicitly or it hangs the shell. Stop-Job
    # does terminate the native child (verified: zero dns-sd.exe left behind) and
    # Receive-Job still returns the buffered output afterwards, so this stays
    # side-effect-free. Do not "simplify" it to a direct call.
    $job = Start-Job -ScriptBlock { param($exe) & $exe -B _airplay._tcp } -ArgumentList $dnssd
    Start-Sleep -Seconds 5
    Stop-Job $job -ErrorAction SilentlyContinue
    $out = Receive-Job $job -ErrorAction SilentlyContinue | Out-String
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    # Which name should be OURS? The running engine is authoritative, and so is a
    # name the user typed. Anything else is a guess, and a guess must never be
    # graded as a failure below - the engine's command line is unreadable when it
    # runs elevated and doctor does not, and an engine started by hand without -n
    # advertises UxPlay's own default instead.
    $nameKnown = $true
    if ($advertisedNames.Count -gt 0) {
        $expected = $advertisedNames
    } elseif ($PSBoundParameters.ContainsKey('ReceiverName')) {
        $expected = @($ReceiverName)
    } else {
        $expected = @($ReceiverName, 'PC')      # airplay-ui.ps1 default, then start-airplay.ps1's
        $nameKnown = $false
    }
    $expected = @($expected | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique)
    $expectedText = "'" + ($expected -join "' / '") + "'"

    $addLines = @($out -split "`n" | Where-Object { $_ -match 'Add\s' })
    # Compare against the WHOLE Instance Name column, never the tail of the line.
    # dns-sd prints "..._airplay._tcp.<spaces><instance name>" to end of line, so
    # the column is everything after the service type. Anchoring on '\s<name>$'
    # is NOT enough: '\sPC$' is equally satisfied by a neighbour's "Living Room
    # PC", which reinstates the exact false PASS this check exists to catch -
    # 'PC' is start-airplay.ps1's default and so is always in the guess list.
    # The fallback keeps a differently-ordered dns-sd build working, but demands
    # a column gap: one space is what lets a name's last word pose as the name.
    $mineNames = @()
    foreach ($line in $addLines) {
        $l = $line.TrimEnd()
        if ($l -match '_airplay\._tcp\.\s+(\S.*)$') {
            $instance = $matches[1]
            if (@($expected | Where-Object { $_ -eq $instance }).Count -gt 0) { $mineNames += $instance }
        } else {
            foreach ($e in $expected) {
                if ($l -match ('\s{2,}' + [regex]::Escape($e) + '$')) { $mineNames += $e }
            }
        }
    }
    $mineNames = @($mineNames | Select-Object -Unique)
    foreach ($line in $addLines) { Info "  $($line.Trim())" }

    if ($mineNames.Count -gt 0) {
        # Report the name actually seen, not the guess list - "advertising as
        # 'DESKTOP-X' / 'PC'" reads as if both were live.
        Pass "This PC is advertising as '$($mineNames -join "' / '")'."
        Info "  Note: a local browse proves the service registered on this PC, not"
        Info "  that the advertisement reached the phone's side of the network."
    } elseif ($engineProcs.Count -gt 0 -and $nameKnown) {
        # The engine is running under a name we actually know, so its absence from
        # the browse is a real fault - other devices being visible does not mean
        # this PC is.
        Fail "The receiver is running but this PC ($expectedText) is NOT in the mDNS browse." `
             "mDNS from this PC is being blocked or never registered. Check 2 (Bonjour), check 4 (a BLOCK rule) and check 4b (ESET or another suite). If the receiver was started with a different name, re-run: .\doctor.ps1 -ReceiverName '<that name>'"
    } elseif ($engineProcs.Count -gt 0) {
        Warn "The receiver is running, but doctor could not read the name it advertises."
        Info "  Neither $expectedText appears above, and the engine's command line was"
        Info "  unreadable (it happens when the engine runs elevated and doctor does not)."
        Info "  Check the list above by hand, or re-run: .\doctor.ps1 -ReceiverName '<that name>'"
    } elseif ($addLines.Count -gt 0) {
        Warn "Other AirPlay devices are visible, but this PC is not advertising."
        Info "  Expected - the receiver isn't running. Start it, then re-run."
    } else {
        Warn "No AirPlay services seen at all."
        Info "  Expected if the receiver isn't running yet. Start it, then re-run."
        Info "  If it IS running and still nothing appears, mDNS is being blocked locally."
    }
}

# --- 7. Phone reachability ------------------------------------------------
Write-Head "7. PC <-> iPhone path (wired PC / Wi-Fi phone)"
# Validate the shape before any of the maths. [IPAddress]::Parse is far too
# permissive to trust with a typo: '10' parses to 0.0.0.10, '0x0A000001' to
# 10.0.0.1 and '192.168.010.042' to 192.168.42.34 - none of them throw, so a
# mistyped address used to come back as a confident "the phone is on a GUEST
# SSID" FAIL. Reject it here instead, and only degrade section 7.
$ipv4Re = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
if ($PhoneIP -and $PhoneIP -notmatch $ipv4Re) {
    Warn "'$PhoneIP' is not a plain IPv4 address (a.b.c.d) - skipping the subnet and ping tests."
    Info "  On the iPhone: Settings -> Wi-Fi -> tap (i) -> IP Address."
    Info "  Use the IPv4 one (e.g. 192.168.1.42), not the IPv6 address, and no"
    Info "  leading zeros - both silently parse into a different address."
    $PhoneIP = $null
}

if (-not $PhoneIP) {
    Info "No -PhoneIP given, skipping the most valuable test."
    Info "  On the iPhone: Settings -> Wi-Fi -> tap (i) next to your network -> IP Address"
    Info "  Then re-run:  .\doctor.ps1 -PhoneIP <that address>"
} else {
    # Compare against EVERY usable IPv4 on this PC, not just the routing one. With
    # the USB tether of check 8 the phone sits on 172.20.10.x while the LAN address
    # is still 192.168.x.x, and testing only the LAN address would report a guest
    # SSID that isn't there. The phone only has to share a subnet with one of them.
    $pcIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })

    if ($pcIps.Count -gt 0) {
        try {
            $phoneVal = ConvertTo-UInt32 $PhoneIP
            $match = $null
            foreach ($p in $pcIps) {
                # Use the DECIMAL literal, not 0xFFFFFFFF: PowerShell parses that
                # hex literal as [int] -1, so any unsigned cast of it throws. That
                # left $maskInt null, making every comparison 0 -eq 0 -- so this
                # check used to report "same subnet" for every address, including a
                # guest network. Verified correct for every prefix 0..32.
                $prefix  = [int]$p.PrefixLength
                $maskInt = [uint32](([uint64]4294967295 -shl (32 - $prefix)) -band 4294967295)
                if (((ConvertTo-UInt32 $p.IPAddress) -band $maskInt) -eq ($phoneVal -band $maskInt)) {
                    $match = $p
                    break
                }
            }
            if ($match) {
                Pass "Same subnet: PC $($match.IPAddress)/$($match.PrefixLength) on '$($match.InterfaceAlias)', phone $PhoneIP"
            } else {
                $list = ($pcIps | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', '
                Fail "DIFFERENT subnets: PC $list vs phone $PhoneIP" `
                     "mDNS cannot cross subnets. The phone is probably on a GUEST SSID or a separate VLAN. Join it to the same network the PC's cable is on, or use the USB tether in check 8."
            }
        } catch {
            # Unreachable via the regex above, so if this fires it is a doctor bug.
            # Fail rather than Warn: a check that could not run must never leave
            # the summary reading clean.
            Fail "Could not compare subnets: $($_.Exception.Message)" `
                 "Re-run with the address from iPhone Settings -> Wi-Fi -> (i) -> IP Address."
        }
    } else {
        # This branch must never be silent. Printing nothing between the header
        # and the ping is indistinguishable from a pass, and this is the one check
        # that tells a guest SSID apart from a real fault.
        Fail "The subnet check could NOT run - this PC has no usable IPv4 address." `
             "See check 3 above. Fix the network first; the phone can only reach this PC over a working interface with an address on it."
    }

    Info "Pinging the phone (iOS answers ping when awake and unlocked)..."
    if (Test-Connection -ComputerName $PhoneIP -Count 3 -Quiet -ErrorAction SilentlyContinue) {
        Pass "Phone is reachable at $PhoneIP - no client/AP isolation on this path."
    } else {
        Warn "No ping reply from $PhoneIP."
        Info "  This is NOT conclusive - iOS ignores ping while the screen is locked."
        Info "  Unlock the phone and re-run. If it still fails, the likely cause is"
        Info "  'AP isolation' / 'client isolation' / 'guest mode' on the router,"
        Info "  which blocks Wi-Fi clients from reaching wired devices. Turn it off"
        Info "  in the router admin page, or put the phone on the main SSID."
        Info "  No router access? Plug the iPhone in via USB, enable Personal Hotspot"
        Info "  (Settings -> Personal Hotspot), and install the 'Apple Devices' app from"
        Info "  the Microsoft Store for the USB driver. That gives the PC a direct"
        Info "  network link to the phone - AirPlay then works with no router at all."
    }
}

# --- 8. Fallback path: USB tether -----------------------------------------
# When the phone is stuck on a guest SSID (isolated, separate subnet) and the
# PC is wired, nothing on the PC can bridge that. USB Personal Hotspot sidesteps
# the router completely: it puts the PC and the phone on one direct link, and
# mDNS works over it.
Write-Head "8. USB tether fallback (for guest Wi-Fi / isolated networks)"
$appleNet = @(Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceDescription -match 'Apple (Mobile Device )?(Ethernet|USB|NDIS)' })
if ($appleNet.Count -gt 0) {
    foreach ($a in $appleNet) {
        if ($a.Status -eq 'Up') {
            Pass "USB tether link is UP: $($a.InterfaceAlias) - AirPlay can run over this."
        } else {
            Info "Apple USB network adapter present but $($a.Status)."
            Info "  Plug the iPhone in, unlock it, tap 'Trust', and turn on"
            Info "  Settings -> Personal Hotspot -> Allow Others to Join."
        }
    }
} else {
    Info "No Apple USB network adapter installed."
    Info "  You only need this if the iPhone cannot join the same network as this PC"
    Info "  (guest SSID, client isolation, or a Wi-Fi-only phone on a wired PC)."
    Info "  To enable it:"
    Info "    1. Install 'Apple Devices' from the Microsoft Store (supplies the driver)."
    Info "    2. Connect the iPhone by USB, unlock it, tap 'Trust This Computer'."
    Info "    3. iPhone: Settings -> Personal Hotspot -> Allow Others to Join = ON."
    Info "    4. Re-run this script - the adapter should show as Up."
    Info "  The PC and phone then share one direct link and the router is bypassed."
}

# --- Summary --------------------------------------------------------------
Write-Head "Summary"
if ($script:problems.Count -eq 0) {
    Write-Host "  No blocking problems found." -ForegroundColor Green
    Write-Host "  Start the receiver with:  .\start-airplay.ps1" -ForegroundColor Gray
} else {
    Write-Host "  $($script:problems.Count) problem(s) need attention:" -ForegroundColor Red
    foreach ($p in $script:problems) { Write-Host "    - $p" -ForegroundColor Red }
}
Write-Host ""

# Exit code so this can gate a script: 0 clean, 1 problems, 2 stopped early (see
# the trap). Guarded so that dot-sourcing doctor.ps1 cannot kill the caller's
# session. A plain interactive run is unaffected.
if ($MyInvocation.InvocationName -ne '.') {
    if ($script:problems.Count -gt 0) { exit 1 } else { exit 0 }
}
