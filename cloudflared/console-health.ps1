<#
.SYNOPSIS
    Health check + self-healing watchdog for the web console ORIGIN services.

.DESCRIPTION
    cloudflared has been supervised since tunnel-supervisor.ps1 landed, so the
    tunnel survives a network drop. The origin side never was: start-console.ps1
    fires console-proxy.js, sshwifty and the TCP relays with Start-Process and
    then exits. When one of those dies it stays dead until somebody manually
    runs start-console.bat -- cloudflared keeps happily reconnecting to the edge
    while every request 502s on "connection refused".

    That is exactly how console.ffxiv.be went down. The tunnel was healthy the
    whole time (it lost the edge at 05:24:59 and re-registered 13s later), but
    console-proxy.js on 127.0.0.1:7681 had already died hours earlier and
    nothing was watching it. The SSH relay on 2222 was down with it, which is
    what produced sshwifty's "dial tcp 127.0.0.1:2222 ... actively refused".

    This script closes that gap: it checks every origin component and restarts
    ONLY the ones that are actually dead.

.PARAMETER ReportOnly
    List healing opportunities without changing anything. Nothing is started,
    stopped or written. Use this to see what a real run would repair.

.PARAMETER Install
    Register the 'ConsoleHealth' scheduled task (at logon + startup, repeating
    every -IntervalMinutes) so the console heals itself unattended.

.PARAMETER Uninstall
    Remove the 'ConsoleHealth' scheduled task.

.EXAMPLE
    .\console-health.ps1 -ReportOnly     # what would it fix?
    .\console-health.ps1                 # fix it now
    .\console-health.ps1 -Install        # never think about it again

.NOTES
    SAFETY CONTRACT -- this script must never disturb live work.

      * It NEVER kills a tmux session. start-console.ps1 runs
        `tmux kill-session -t console`; this script does not, and must not.
      * It NEVER restarts a process that is alive. sshwifty in particular holds
        live SSH sessions, so it is only ever started when genuinely down.
      * It only ever uses `systemctl start` in WSL, never `restart`, so running
        units and whatever is attached to them are left alone.

    A repair here is always "start something that is missing", never "recycle
    something that is working". That is what makes it safe to run every 5
    minutes on a machine with long-lived work in tmux.
#>
param(
    [switch]$ReportOnly,
    [switch]$Install,
    [switch]$Uninstall,
    [int]$IntervalMinutes = 5,
    [string]$Distro = 'Ubuntu-24.04'
)

# Auto-elevate to Administrator.
# param() must be the first statement in a PowerShell file, so the
# elevate-first form used by the parameterless .ps1 files in this repo is a
# parse error here. The block sits after param() and forwards $PSBoundParameters
# so the elevated copy runs the same command (same rule as tests\vm\run-vm-test.ps1).
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($kv.Value.IsPresent) { $fwd += "-$($kv.Key)" }
        } else {
            $fwd += @("-$($kv.Key)", "`"$($kv.Value)`"")
        }
    }
    Start-Process PowerShell -ArgumentList $fwd -Verb RunAs
    exit
}

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$cloudflareDir = "$env:USERPROFILE\Documents\Cloudflare"
$launcherDir   = "$cloudflareDir\launcher"
$sshwiftyDir   = "$cloudflareDir\sshwifty"
$cfDir         = "$env:USERPROFILE\.cloudflared"
$repoCfDir     = 'Z:\Users\Heiner\Documents\PCSetup\cloudflared'

$sshwiftyExe   = "$sshwiftyDir\sshwifty_windows_amd64.exe"
$sshwiftyConf  = "$sshwiftyDir\sshwifty.conf.json"
$sshwiftyLog   = "$sshwiftyDir\sshwifty.log"
$proxyScript   = "$launcherDir\console-proxy.js"
$proxyLog      = "$launcherDir\proxy.log"
$proxyPidFile  = "$launcherDir\proxy.pid"
$healthLog     = "$cfDir\console-health.log"

$devConfigPath       = "$cfDir\dev-config.yml"
$cfLog               = "$cfDir\cloudflared-dev.log"
$cfPidFile           = "$cfDir\cloudflared-dev.pid"
$cfSupervisorPidFile = "$cfDir\cloudflared-dev-supervisor.pid"
$cfSupervisorLog     = "$cfDir\cloudflared-dev-supervisor.log"

# Helper scripts sit next to this file when it runs from the repo, and in
# Documents\Cloudflare in the deployed copy. Resolve rather than hardcode.
function Resolve-Helper {
    param([string]$Name)
    foreach ($dir in $PSScriptRoot, $cloudflareDir, $repoCfDir) {
        if ($dir) {
            $candidate = Join-Path $dir $Name
            if (Test-Path $candidate) { return $candidate }
        }
    }
    return $null
}
$tcpRelayScript = Resolve-Helper 'tcp-relay.js'
$sshProxyScript = Resolve-Helper 'ssh-proxy.js'
$cfSupervisor   = Resolve-Helper 'tunnel-supervisor.ps1'

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$nodeExe = if ($nodeCmd) { $nodeCmd.Source } else { $null }
if (-not $nodeExe) {
    $guess = "$env:USERPROFILE\scoop\apps\nvm\current\nodejs\nodejs\node.exe"
    if (Test-Path $guess) { $nodeExe = $guess }
}

# ---------------------------------------------------------------------------
# Logging / bookkeeping
# ---------------------------------------------------------------------------
$script:Findings = @()   # what is wrong
$script:Repairs  = @()   # what we fixed
$script:Failures = @()   # what we could not fix

function Write-HealthLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'HEAL', 'FAIL', 'OK')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    $line  = "$stamp [$Level] $Message"
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'HEAL'  { 'Cyan' }
        'WARN'  { 'Yellow' }
        'FAIL'  { 'Red' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    try {
        if (-not (Test-Path $cfDir)) { New-Item -ItemType Directory -Path $cfDir -Force | Out-Null }
        Add-Content -Path $healthLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Add-Finding { param([string]$What) $script:Findings += $What }
function Add-Repair  { param([string]$What) $script:Repairs  += $What; Write-HealthLog $What 'HEAL' }
function Add-Failure { param([string]$What) $script:Failures += $What; Write-HealthLog $What 'FAIL' }

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------
function Test-PortListening {
    param([int]$Port)
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Get-PortOwnerPid {
    param([int]$Port)
    $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($conn) { return [int]$conn.OwningProcess }
    return 0
}

function Get-ProcessCommandLine {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return '' }
    try {
        return (Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue).CommandLine
    } catch { return '' }
}

# A listening socket is not the same as a working service: a wedged Node process
# still holds the port while answering nothing, and cloudflared would still 502.
# Probe HTTP where we can. sshwifty 403s any Host it does not recognise, so the
# console probe has to send the real hostname.
# Returns $true / $false, or $null when it cannot tell (no curl.exe).
function Test-HttpOk {
    param([int]$Port, [string]$HostHeader, [int]$TimeoutSec = 5)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) { return $null }
    # NOTE: not $args - that is an automatic variable inside a function.
    $curlArgs = @('-s', '-o', 'NUL', '-w', '%{http_code}', '--max-time', "$TimeoutSec")
    if ($HostHeader) { $curlArgs += @('-H', "Host: $HostHeader") }
    $curlArgs += "http://127.0.0.1:$Port/"
    try {
        $code = (& $curl.Source @curlArgs 2>$null | Out-String).Trim()
        # Any real HTTP response means the origin is answering. 3xx is healthy
        # here: code-server redirects to its login page, which is a live origin.
        if ($code -match '^\d{3}$' -and [int]$code -lt 500) { return $true }
        return $false
    } catch { return $false }
}

function Get-WslIp {
    $ip = (& wsl.exe -d $Distro --user root -- bash -c "hostname -I | cut -d ' ' -f1" 2>$null | Out-String).Trim()
    $ip = $ip -replace '[^\d\.]', ''
    if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
    return $null
}

# ---------------------------------------------------------------------------
# Relay repair
# ---------------------------------------------------------------------------
function Repair-Relay {
    param(
        [int]$Port,
        [string]$ScriptPath,
        [string[]]$RelayArgs,
        [string]$Label,
        [string]$PidFile,
        [string]$LogFile,
        [string]$WslIp
    )

    $needStart = $false

    if (-not (Test-PortListening -Port $Port)) {
        Add-Finding "$Label (127.0.0.1:$Port) is down"
        $needStart = $true
    } else {
        # Listening, but is it pointed at the CURRENT WSL IP? WSL takes a new IP
        # whenever the VM restarts, and a relay left aiming at the old one keeps
        # listening happily while every connection times out. That is the
        # documented "code.ffxiv.be returns 502 after WSL restarted" failure, and
        # a port check alone will never catch it.
        $ownerPid = Get-PortOwnerPid -Port $Port
        $cmdline  = Get-ProcessCommandLine -ProcessId $ownerPid
        if ($cmdline -match 'tcp-relay\.js|ssh-proxy\.js') {
            if ($cmdline -notmatch [regex]::Escape($WslIp)) {
                Add-Finding "$Label is relaying to a stale WSL IP (current: $WslIp)"
                $needStart = $true
                if (-not $ReportOnly) {
                    Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 300
                    Add-Repair "Stopped $Label that pointed at a stale WSL IP"
                }
            }
        }
    }

    if (-not $needStart -or $ReportOnly) { return }

    if (-not $ScriptPath -or -not (Test-Path $ScriptPath)) {
        Add-Failure "$Label cannot be started - helper script not found"
        return
    }
    if (-not $nodeExe) {
        Add-Failure "$Label cannot be started - node.exe not found (run 3-setup-node.bat)"
        return
    }

    # Redirect BOTH streams so relay output lands in a file rather than on
    # whatever console happened to launch this.
    #
    # Caveat, measured: this does NOT stop a *piped* shell from appearing to
    # hang. The script itself finishes in ~5s (check the tail of
    # console-health.log for "check end"), but a long-lived service started here
    # still inherits the console handle, so `.\console-health.ps1 | grep ...`
    # sits there until the relay dies. That is the shell waiting on the pipe,
    # not the watchdog running. Irrelevant to the scheduled task; when running by
    # hand, redirect to a file instead of piping.
    $proc = Start-Process -FilePath $nodeExe -ArgumentList (@($ScriptPath) + $RelayArgs) `
        -RedirectStandardError $LogFile -RedirectStandardOutput "$LogFile.out" `
        -WindowStyle Hidden -PassThru
    $proc.Id | Out-File -FilePath $PidFile -Encoding utf8
    Start-Sleep -Milliseconds 700
    if (Test-PortListening -Port $Port) {
        Add-Repair "Started $Label (PID $($proc.Id)) -> ${WslIp}:$Port"
    } else {
        Add-Failure "$Label was started (PID $($proc.Id)) but $Port is still not listening - see $LogFile"
    }
}

# ---------------------------------------------------------------------------
# Install / uninstall the scheduled task
# ---------------------------------------------------------------------------
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName 'ConsoleHealth' -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName 'ConsoleHealth' -Confirm:$false
        Write-HealthLog "Scheduled task 'ConsoleHealth' removed" 'OK'
    } else {
        Write-HealthLog "Scheduled task 'ConsoleHealth' was not registered" 'INFO'
    }
    exit 0
}

if ($Install) {
    $self = $PSCommandPath
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`""

    # At logon AND at startup, then every $IntervalMinutes forever. The repetition
    # is grafted on from a -Once trigger because New-ScheduledTaskTrigger will not
    # accept -RepetitionInterval together with -AtLogOn / -AtStartup.
    $repeat = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
        -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition

    $tLogon   = New-ScheduledTaskTrigger -AtLogOn
    $tStartup = New-ScheduledTaskTrigger -AtStartup
    $tLogon.Repetition   = $repeat
    $tStartup.Repetition = $repeat

    # Run COMPLETELY invisibly. `-WindowStyle Hidden` on the powershell action is
    # not sufficient on its own: with LogonType InteractiveToken the task runs in
    # the user's desktop session and Task Scheduler still flashes a console window
    # for a fraction of a second on every fire. Every 5 minutes, forever, that is
    # very noticeable.
    #
    # S4U ("run whether the user is logged on or not", no stored password) runs the
    # task in session 0, where nothing is ever rendered - so no flash at all. It
    # keeps the user identity, so $env:USERPROFILE still resolves to this profile
    # and the launcher/sshwifty paths stay correct. The relays it starts bind
    # loopback, which is machine-wide rather than per-session, so cloudflared (in
    # the user session) still reaches them.
    #
    # S4U needs the "Log on as a batch job" right; fall back to InteractiveToken if
    # registration is refused rather than leaving no watchdog at all.
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType S4U -RunLevel Highest

    # MultipleInstances IgnoreNew: a slow run must never stack copies of itself,
    # each racing to start the same proxy on the same port.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    $desc = 'Checks the web console origin services and restarts only the ones that are down. Never touches tmux or a live process.'
    $registered = $false
    try {
        Register-ScheduledTask -TaskName 'ConsoleHealth' -Action $action `
            -Trigger @($tLogon, $tStartup) -Principal $principal -Settings $settings `
            -Description $desc -Force -ErrorAction Stop | Out-Null
        $registered = $true
        Write-HealthLog "Principal: S4U (session 0) - no console window is ever drawn" 'OK'
    } catch {
        Write-HealthLog "S4U registration refused ($($_.Exception.Message.Trim())); falling back to InteractiveToken" 'WARN'
        Write-HealthLog "NOTE: the fallback may briefly flash a console window on each run" 'WARN'
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType InteractiveToken -RunLevel Highest
        Register-ScheduledTask -TaskName 'ConsoleHealth' -Action $action `
            -Trigger @($tLogon, $tStartup) -Principal $principal -Settings $settings `
            -Description $desc -Force | Out-Null
        $registered = $true
    }
    if (-not $registered) { Add-Failure 'Could not register the ConsoleHealth task'; exit 1 }

    Write-HealthLog "Scheduled task 'ConsoleHealth' registered (logon + startup, every $IntervalMinutes min)" 'OK'
    Write-HealthLog "Log: $healthLog" 'INFO'
    exit 0
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
$mode = if ($ReportOnly) { 'REPORT-ONLY (nothing will be changed)' } else { 'HEAL' }
Write-HealthLog "=== console health check start - mode: $mode ===" 'INFO'

# -- 1. WSL VM ---------------------------------------------------------------
# Everything except sshwifty and console-proxy lives inside WSL. If the VM is
# down the relays have nothing to relay to.
$running = (& wsl.exe --list --running 2>$null | Out-String) -replace "`0", ''
if ($running -notmatch [regex]::Escape($Distro)) {
    Add-Finding "WSL distro $Distro is not running"
    if (-not $ReportOnly) {
        $keepalive = Get-ScheduledTask -TaskName 'WSLKeepAlive' -ErrorAction SilentlyContinue
        if ($keepalive) {
            if ($keepalive.State -ne 'Running') { Start-ScheduledTask -TaskName 'WSLKeepAlive' }
            Start-Sleep -Seconds 8
            Add-Repair "Started WSLKeepAlive to bring $Distro back up"
        } else {
            Add-Failure "WSL is down and the WSLKeepAlive task is not registered (run setup-console-windows.ps1)"
        }
    }
} else {
    Write-HealthLog "WSL $Distro is running" 'OK'
}

# The keepalive task holds the VM open; without it WSL idles out and takes
# code-server and the other services with it.
$keepalive = Get-ScheduledTask -TaskName 'WSLKeepAlive' -ErrorAction SilentlyContinue
if ($keepalive -and $keepalive.State -ne 'Running') {
    Add-Finding "WSLKeepAlive task is $($keepalive.State), not Running - WSL will idle out"
    if (-not $ReportOnly) {
        Start-ScheduledTask -TaskName 'WSLKeepAlive'
        Add-Repair "Started the WSLKeepAlive scheduled task"
    }
}

# -- 2. WSL services ---------------------------------------------------------
# `systemctl start` only, never `restart`: a restart would drop whatever is
# attached to a running unit.
$wslUnits = [ordered]@{
    22   = 'ssh'
    7683 = 'ttyd-proxy'
    7684 = 'ttyd-persistent'
    7685 = 'ttyd-fresh'
    7686 = 'dashboard'
    7687 = 'git-proxy'
    7688 = 'ungit'
}
$wslPortsRaw = (& wsl.exe -d $Distro --user root -- bash -c "ss -tln 2>/dev/null | awk '{print `$4}'" 2>$null | Out-String) -replace "`0", ''
foreach ($port in $wslUnits.Keys) {
    $unit = $wslUnits[$port]
    if ($wslPortsRaw -notmatch ":$port(\s|$)") {
        Add-Finding "WSL service $unit (port $port) is not listening"
        if (-not $ReportOnly) {
            & wsl.exe -d $Distro --user root -- systemctl start $unit 2>$null | Out-Null
            Add-Repair "Started WSL service $unit (port $port)"
        }
    }
}
# code-server's unit is instanced on the uid-1000 user, so resolve the name.
if ($wslPortsRaw -notmatch ':8080(\s|$)') {
    $codeUser = (& wsl.exe -d $Distro --user root -- bash -lc "getent passwd 1000 | cut -d: -f1" 2>$null | Out-String).Trim()
    if (-not $codeUser) { $codeUser = 'root' }
    Add-Finding "WSL service code-server@$codeUser (port 8080) is not listening"
    if (-not $ReportOnly) {
        & wsl.exe -d $Distro --user root -- systemctl start "code-server@$codeUser" 2>$null | Out-Null
        Add-Repair "Started WSL service code-server@$codeUser (port 8080)"
    }
}

# -- 3. Windows relays (NAT mode only) ---------------------------------------
# In mirrored mode WSL shares the Windows stack and cloudflared reaches the
# services directly on 127.0.0.1 - relays there would squat the very ports the
# WSL services need to bind. Detect the mode, never assume it.
$netMode  = (& wsl.exe -d $Distro --user root -- wslinfo --networking-mode 2>$null | Out-String).Trim()
$mirrored = ($netMode -eq 'mirrored')
Write-HealthLog "WSL networking mode: $netMode$(if ($mirrored) { ' (relays not used)' })" 'INFO'

if (-not $mirrored) {
    $wslIp = Get-WslIp
    if (-not $wslIp) {
        Add-Failure "Could not resolve the WSL IP - relays cannot be verified"
    } else {
        Write-HealthLog "WSL IP: $wslIp" 'INFO'

        # SSH relay: sshwifty dials 127.0.0.1:2222, which is how every
        # quick-connect preset reaches WSL sshd. When this is down sshwifty
        # reports "dial tcp 127.0.0.1:2222 ... actively refused".
        Repair-Relay -Port 2222 -ScriptPath $sshProxyScript `
            -RelayArgs @("--target=${wslIp}:22") -Label 'SSH relay' `
            -PidFile "$launcherDir\ssh-proxy.pid" -LogFile "$launcherDir\ssh-proxy.log" `
            -WslIp $wslIp

        foreach ($port in 8080, 7683, 7686, 7687) {
            Repair-Relay -Port $port -ScriptPath $tcpRelayScript `
                -RelayArgs @("--listen-port=$port", "--target-host=$wslIp", "--target-port=$port") `
                -Label "TCP relay $port" `
                -PidFile "$launcherDir\relay-$port.pid" -LogFile "$launcherDir\relay-$port.log" `
                -WslIp $wslIp
        }
    }
}

# -- 4. sshwifty (127.0.0.1:7682) --------------------------------------------
# Only started when genuinely dead: it holds live SSH sessions, and recycling a
# healthy one would disconnect whoever is using the console right now.
$sshwiftyProc = Get-Process -Name 'sshwifty_windows_amd64' -ErrorAction SilentlyContinue
if (-not $sshwiftyProc -or -not (Test-PortListening -Port 7682)) {
    Add-Finding "sshwifty (127.0.0.1:7682) is down"
    if (-not $ReportOnly) {
        if (-not (Test-Path $sshwiftyExe)) {
            Add-Failure "sshwifty binary not found: $sshwiftyExe"
        } elseif (-not (Test-Path $sshwiftyConf)) {
            Add-Failure "sshwifty config not found: $sshwiftyConf (run sync-secrets.bat)"
        } else {
            Start-Process -FilePath $sshwiftyExe -ArgumentList '-config', $sshwiftyConf `
                -RedirectStandardError $sshwiftyLog -RedirectStandardOutput "$sshwiftyLog.out" `
                -WindowStyle Hidden
            Start-Sleep -Seconds 2
            if (Test-PortListening -Port 7682) {
                Add-Repair "Started sshwifty -> 127.0.0.1:7682"
            } else {
                Add-Failure "sshwifty was started but 7682 is still not listening - see $sshwiftyLog"
            }
        }
    }
} else {
    Write-HealthLog "sshwifty is up (PID $($sshwiftyProc.Id))" 'OK'
}

# -- 5. console-proxy.js (127.0.0.1:7681) ------------------------------------
# The one that actually took console.ffxiv.be down.
$proxyDown = $false
if (-not (Test-PortListening -Port 7681)) {
    Add-Finding "console-proxy (127.0.0.1:7681) is down - console.ffxiv.be will 502"
    $proxyDown = $true
} else {
    $http = Test-HttpOk -Port 7681 -HostHeader 'console.ffxiv.be'
    if ($http -eq $false) {
        Add-Finding "console-proxy holds 7681 but is not answering HTTP - console.ffxiv.be will 502"
        $proxyDown = $true
        if (-not $ReportOnly) {
            $ownerPid = Get-PortOwnerPid -Port 7681
            if ($ownerPid -gt 0) {
                Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 400
                Add-Repair "Stopped wedged console-proxy (PID $ownerPid)"
            }
        }
    } else {
        Write-HealthLog "console-proxy is up and answering on 7681" 'OK'
    }
}

if ($proxyDown -and -not $ReportOnly) {
    if (-not (Test-Path $proxyScript)) {
        Add-Failure "console-proxy.js not found: $proxyScript (run setup-console-windows.ps1)"
    } elseif (-not $nodeExe) {
        Add-Failure "node.exe not found - run 3-setup-node.bat"
    } else {
        $proc = Start-Process -FilePath $nodeExe -ArgumentList $proxyScript `
            -RedirectStandardError $proxyLog -RedirectStandardOutput "$proxyLog.out" `
            -WindowStyle Hidden -PassThru
        $proc.Id | Out-File -FilePath $proxyPidFile -Encoding utf8
        Start-Sleep -Seconds 2
        if (Test-PortListening -Port 7681) {
            Add-Repair "Started console-proxy (PID $($proc.Id)) -> 127.0.0.1:7681"
        } else {
            Add-Failure "console-proxy was started (PID $($proc.Id)) but 7681 is still not listening - see $proxyLog"
        }
    }
}

# -- 6. cloudflared tunnel + supervisor ---------------------------------------
# The supervisor is what makes the tunnel survive a network drop. cloudflared
# itself can be alive while the supervisor that would restart it is gone, so
# check both independently.
$cfAlive = $false
Get-Process cloudflared -ErrorAction SilentlyContinue | ForEach-Object {
    if ((Get-ProcessCommandLine -ProcessId $_.Id) -like '*dev-config*') { $cfAlive = $true }
}

$supAlive = $false
if (Test-Path $cfSupervisorPidFile) {
    $supPid = (Get-Content $cfSupervisorPidFile -ErrorAction SilentlyContinue | Out-String).Trim()
    if ($supPid -match '^\d+$' -and (Get-Process -Id ([int]$supPid) -ErrorAction SilentlyContinue)) { $supAlive = $true }
}

if ($cfAlive) { Write-HealthLog "cloudflared (dev-console) is running" 'OK' }

if ($supAlive) {
    Write-HealthLog "cloudflared supervisor is running" 'OK'
} elseif ($cfAlive) {
    # Do NOT tear down a working tunnel just to regain supervision - that would
    # drop every live session to fix a problem nobody is feeling yet.
    Add-Finding "cloudflared is running UNSUPERVISED (restart via start-console.bat when convenient)"
    Write-HealthLog "Leaving the live tunnel untouched rather than restarting it to attach a supervisor" 'WARN'
} else {
    Add-Finding "cloudflared and its supervisor are both down - the tunnel is offline"
    if (-not $ReportOnly) {
        if (-not $cfSupervisor -or -not (Test-Path $cfSupervisor)) {
            Add-Failure "tunnel-supervisor.ps1 not found - cannot restore the tunnel"
        } elseif (-not (Test-Path $devConfigPath)) {
            Add-Failure "dev-config.yml not found: $devConfigPath"
        } else {
            $sup = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $cfSupervisor,
                '-ConfigPath', $devConfigPath, '-CfLog', $cfLog, '-LogPath', $cfSupervisorLog,
                '-CfPidFile', $cfPidFile, '-Label', 'dev-console'
            ) -WindowStyle Hidden -PassThru
            $sup.Id | Out-File -FilePath $cfSupervisorPidFile -Encoding utf8
            Add-Repair "Started the cloudflared supervisor (PID $($sup.Id))"
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
if ($script:Findings.Count -eq 0) {
    Write-HealthLog "All console origin services healthy - no healing needed" 'OK'
} else {
    Write-HealthLog "Healing opportunities found: $($script:Findings.Count)" 'WARN'
    foreach ($finding in $script:Findings) { Write-Host "    - $finding" -ForegroundColor Yellow }
}
if ($script:Repairs.Count -gt 0) {
    Write-HealthLog "Repairs applied: $($script:Repairs.Count)" 'HEAL'
    foreach ($repair in $script:Repairs) { Write-Host "    + $repair" -ForegroundColor Cyan }
}
if ($script:Failures.Count -gt 0) {
    Write-HealthLog "Could not repair: $($script:Failures.Count)" 'FAIL'
    foreach ($failure in $script:Failures) { Write-Host "    ! $failure" -ForegroundColor Red }
}
if ($ReportOnly -and $script:Findings.Count -gt 0) {
    Write-Host ''
    Write-Host 'Run without -ReportOnly to apply these repairs.' -ForegroundColor Yellow
}
Write-HealthLog "=== console health check end ===" 'INFO'

if ($script:Failures.Count -gt 0) { exit 1 }
exit 0
