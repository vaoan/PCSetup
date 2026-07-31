# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Starts the web console (SSHwifty + launcher proxy + cloudflared tunnel).
#
# Architecture:
#   Cloudflare tunnel -> proxy (127.0.0.1:7681) -> SSHwifty (127.0.0.1:7682)
#   proxy injects quick-connect panel into SSHwifty HTML.
#   SSHwifty connects through the local portproxy (127.0.0.1:2222) to WSL SSH.
#   The portproxy is refreshed at launch to the current WSL IP.
#   SSH authorized_keys map each key to a specific tmux session/directory.

$distro        = "Ubuntu-24.04"
$cloudflareDir = "$env:USERPROFILE\Documents\Cloudflare"
$sshwiftyDir   = "$cloudflareDir\sshwifty"
$launcherDir   = "$cloudflareDir\launcher"
$cfDir         = "$env:USERPROFILE\.cloudflared"
$cfExe         = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$devConfigPath = "$cfDir\dev-config.yml"
$sshwiftyExe   = "$sshwiftyDir\sshwifty_windows_amd64.exe"
$sshwiftyConf  = "$sshwiftyDir\sshwifty.conf.json"
$sshwiftyLog   = "$sshwiftyDir\sshwifty.log"
$proxyScript   = "$launcherDir\console-proxy.js"
$proxyLog      = "$launcherDir\proxy.log"
$proxyPidFile  = "$launcherDir\proxy.pid"
$sshProxyScript = "$PSScriptRoot\ssh-proxy.js"
$sshProxyLog   = "$launcherDir\ssh-proxy.log"
$sshProxyPidFile = "$launcherDir\ssh-proxy.pid"
$tcpRelayScript = "$PSScriptRoot\tcp-relay.js"
$wslKeepalivePidFile = "$launcherDir\wsl-keepalive.pid"
$cfLog         = "$cfDir\cloudflared-dev.log"
$cfPidFile     = "$cfDir\cloudflared-dev.pid"
$cfSupervisor       = "$PSScriptRoot\tunnel-supervisor.ps1"
$cfSupervisorPidFile = "$cfDir\cloudflared-dev-supervisor.pid"
$cfSupervisorLog    = "$cfDir\cloudflared-dev-supervisor.log"
$nodeCmd       = Get-Command node -ErrorAction SilentlyContinue
$nodeExe       = if ($nodeCmd) { $nodeCmd.Source } else { $null }

function Write-Log { param([string]$msg) Write-Host "[start-console] $msg" }
function Fail { param([string]$msg) Write-Host "[start-console] ERROR: $msg" -ForegroundColor Red; exit 1 }
function Get-CodeServerUser {
    $user = (& wsl -d $distro --user root -- bash -lc "getent passwd 1000 | cut -d: -f1" | Out-String).Trim()
    if (-not $user) { return 'root' }
    return $user
}
function Stop-ListenerOnPort {
    param([int]$Port)

    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $Port }
    foreach ($listener in @($listeners)) {
        if ($listener.OwningProcess -gt 0) {
            $proc = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -ne 'svchost') {
                Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
                Write-Log "Stopped stale listener on 127.0.0.1:$Port (PID $($listener.OwningProcess))"
            }
        }
    }
}

# -- 0. Detect WSL networking mode --------------------------------------------
# In MIRRORED mode WSL shares the Windows network stack, so:
#   * Windows reaches WSL services directly on 127.0.0.1 (hostAddressLoopback) —
#     the Windows tcp-relay.js / ssh-proxy.js relays are NOT used (they would
#     squat the very ports the WSL services need to bind).
#   * WSL sshd cannot use port 22 (Windows OpenSSH owns it) — it runs on 2222,
#     which sshwifty already targets (127.0.0.1:2222).
$netMode = (wsl -d $distro --user root -- wslinfo --networking-mode 2>$null | Out-String).Trim()
$mirrored = ($netMode -eq 'mirrored')
Write-Log "WSL networking mode: $netMode$(if ($mirrored) { ' (relays disabled)' })"

# -- 1. Resolve WSL IP and normalize local origin targets ---------------------
Write-Log "Resolving WSL2 IP..."
$wslIp = (wsl -d $distro --user root -- bash -c "hostname -I | cut -d ' ' -f1").Trim()
if (-not $wslIp) { Fail "Could not determine WSL2 IP. Is $distro running?" }
Write-Log "WSL2 IP: $wslIp"
$codeUser = Get-CodeServerUser
Write-Log "code-server user: $codeUser"

# Keep the WSL2 VM alive. Without a held-open session WSL shuts the VM down when
# idle, which kills code-server/dashboard/etc. and (on restart) changes the WSL
# IP out from under the TCP relays -> console hostnames (code.ffxiv.be) return
# 502. The durable holder is the 'WSLKeepAlive' scheduled task (a persistent
# `sleep infinity` session); prefer it. Fall back to a hidden session if the task
# isn't registered yet (e.g. start-console run before setup-console-windows.ps1).
if (-not (Test-Path $launcherDir)) { New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null }
$keepaliveTask = Get-ScheduledTask -TaskName 'WSLKeepAlive' -ErrorAction SilentlyContinue
if ($keepaliveTask) {
    if ($keepaliveTask.State -ne 'Running') { Start-ScheduledTask -TaskName 'WSLKeepAlive' }
    Write-Log "WSL keepalive: scheduled task ensured running -> holds $distro VM open"
} else {
    $kaLive = $false
    if (Test-Path $wslKeepalivePidFile) {
        $kaPid = (Get-Content $wslKeepalivePidFile -ErrorAction SilentlyContinue).Trim()
        if ($kaPid -match '^\d+$' -and (Get-Process -Id ([int]$kaPid) -ErrorAction SilentlyContinue)) { $kaLive = $true }
    }
    if ($kaLive) {
        Write-Log "WSL keepalive: fallback session already running (PID $kaPid)"
    } else {
        $kaProc = Start-Process -FilePath "wsl.exe" `
            -ArgumentList "-d", $distro, "--user", "root", "--", "sh", "-c", "exec sleep infinity" `
            -WindowStyle Hidden -PassThru
        $kaProc.Id | Out-File -FilePath $wslKeepalivePidFile -Encoding utf8
        Write-Log "WSL keepalive: fallback session started (PID $($kaProc.Id)); run setup-console-windows.ps1 to install the task"
    }
}

function Set-SshwiftyWslHost {
    param(
        [string]$ConfigPath,
        [string]$TargetHost
    )

    if (-not (Test-Path $ConfigPath)) { return }
    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($preset in @($cfg.Presets)) {
            if ($preset.Type -eq 'SSH') {
                $preset.Host = $TargetHost
            }
        }
        [IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))
        Write-Log "SSHwifty SSH presets pointed at $TargetHost"
    } catch {
        Write-Log "WARNING: Could not update SSHwifty hosts in ${ConfigPath}: $($_.Exception.Message)"
    }
}

function Set-DevTunnelLocalOrigins {
    param([string]$ConfigPath)

    if (-not (Test-Path $ConfigPath)) { return }
    try {
        $raw = Get-Content $ConfigPath -Raw
        $raw = [regex]::Replace($raw, '(?m)^(\s+service:\s+)http://.+:7686$', '${1}http://127.0.0.1:7686')
        $raw = [regex]::Replace($raw, '(?m)^(\s+service:\s+)http://.+:7687$', '${1}http://127.0.0.1:7687')
        $raw = [regex]::Replace($raw, '(?m)^(\s+service:\s+)http://.+:8080$', '${1}http://127.0.0.1:8080')
        $raw = [regex]::Replace($raw, '(?m)^(\s+service:\s+)http://.+:7683$', '${1}http://127.0.0.1:7683')
        [IO.File]::WriteAllText($ConfigPath, $raw, (New-Object System.Text.UTF8Encoding $false))
        Write-Log "Dev tunnel origins pointed at local relays"
    } catch {
        Write-Log "WARNING: Could not update dev tunnel origins in ${ConfigPath}: $($_.Exception.Message)"
    }
}

function Start-TcpRelay {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$NodePath,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$LauncherPath
    )

    $pidFile = Join-Path $LauncherPath "relay-$Port.pid"
    $logFile = Join-Path $LauncherPath "relay-$Port.log"

    if (Test-Path $pidFile) {
        $oldPid = (Get-Content $pidFile -ErrorAction SilentlyContinue).Trim()
        if ($oldPid -match '^\d+$') {
            Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }

    Stop-ListenerOnPort -Port $Port
    Start-Sleep -Milliseconds 200

    $proc = Start-Process -FilePath $NodePath `
        -ArgumentList $ScriptPath, "--listen-port=$Port", "--target-host=$wslIp", "--target-port=$Port" `
        -RedirectStandardError $logFile `
        -WindowStyle Hidden `
        -PassThru
    $proc.Id | Out-File -FilePath $pidFile -Encoding utf8
    Write-Log "TCP relay: started (PID $($proc.Id)) -> ${wslIp}:$Port"
}

Set-SshwiftyWslHost -ConfigPath $sshwiftyConf -TargetHost '127.0.0.1:2222'
Write-Log "SSHwifty SSH target: 127.0.0.1:2222"
Set-DevTunnelLocalOrigins -ConfigPath $devConfigPath

netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=2222 2>$null | Out-Null
Write-Log "portproxy: 127.0.0.1:2222 removed (replaced by local TCP relay)"
foreach ($port in 8080, 7683, 7686, 7687) {
    netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$port 2>$null | Out-Null
}
Write-Log "portproxy: removed for dev origins (replaced by local TCP relays)"

# -- 2. Ensure SSH and WSL services are running -------------------------------
if ($mirrored) {
    # Windows OpenSSH owns port 22 on the shared stack, so WSL sshd must listen
    # on 2222 (socket activation on :22 would fail). sshwifty targets :2222.
    wsl -d $distro --user root -- bash -c "grep -qE '^Port 2222' /etc/ssh/sshd_config || sed -i -E 's/^\s*#?\s*Port\s+.*/Port 2222/' /etc/ssh/sshd_config; grep -qE '^Port 2222' /etc/ssh/sshd_config || echo 'Port 2222' >> /etc/ssh/sshd_config; systemctl disable --now ssh.socket 2>/dev/null; systemctl mask ssh.socket 2>/dev/null; systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || true" | Out-Null
    Write-Log "WSL SSH: listening on 2222 (mirrored)"
} else {
    wsl -d $distro --user root -- bash -c "service ssh start 2>/dev/null || true" | Out-Null
    Write-Log "WSL SSH: started"
}

# The Node proxies run from COPIES at /usr/local/bin, made once by
# setup-console-wsl.sh. Restarting the services does not refresh them, so an
# edit to dashboard.js/git-proxy.js/ttyd-proxy.js in this repo silently has no
# effect until the copy is replaced. Re-deploy them on every start so the repo
# is the source of truth. (This is how the tools dashboard kept serving dead
# *.ffxivbe.org links for days after the hostname migration.)
# NOTE: loop in PowerShell and call `wsl -- cp` directly. Wrapping this in
# `bash -c "for f in ...; do cp ... `$f ...; done"` looks right but the loop
# variable does not survive wsl.exe argument passing, so the copy silently
# no-ops and the stale file keeps serving.
$repoWslPath = '/mnt/z/Users/Heiner/Documents/PCSetup/cloudflared'
foreach ($proxy in 'dashboard.js', 'git-proxy.js', 'ttyd-proxy.js') {
    wsl -d $distro --user root -- cp -f "$repoWslPath/$proxy" "/usr/local/bin/$proxy" 2>$null
}
Write-Log "WSL proxies: redeployed from repo"

wsl -d $distro --user root -- bash -c "systemctl start code-server@$codeUser ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit git-proxy 2>/dev/null || true" | Out-Null
wsl -d $distro --user root -- bash -c "systemctl restart ttyd-proxy dashboard git-proxy 2>/dev/null || true" | Out-Null
Write-Log "WSL services: started"

if ($mirrored) {
    # No Windows relays in mirrored mode — cloudflared reaches WSL on 127.0.0.1
    # directly. Kill any stale relays that would squat the WSL service ports.
    if (Test-Path $sshProxyPidFile) {
        $oldSshProxyPid = (Get-Content $sshProxyPidFile -ErrorAction SilentlyContinue).Trim()
        if ($oldSshProxyPid -match '^\d+$') { Stop-Process -Id ([int]$oldSshProxyPid) -Force -ErrorAction SilentlyContinue }
        Remove-Item $sshProxyPidFile -Force -ErrorAction SilentlyContinue
    }
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'tcp-relay\.js|ssh-proxy\.js' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Log "Windows relays: not needed in mirrored mode (skipped)"
} else {
    if (Test-Path $sshProxyPidFile) {
        $oldSshProxyPid = (Get-Content $sshProxyPidFile -ErrorAction SilentlyContinue).Trim()
        if ($oldSshProxyPid -match '^\d+$') {
            Stop-Process -Id ([int]$oldSshProxyPid) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $sshProxyPidFile -Force -ErrorAction SilentlyContinue
    }
    Stop-ListenerOnPort -Port 2222
    Start-Sleep -Milliseconds 300

    $sshProxyProc = Start-Process -FilePath $nodeExe `
        -ArgumentList $sshProxyScript, "--target=${wslIp}:22" `
        -RedirectStandardError $sshProxyLog `
        -WindowStyle Hidden `
        -PassThru
    $sshProxyProc.Id | Out-File -FilePath $sshProxyPidFile -Encoding utf8
    Write-Log "SSH relay: started (PID $($sshProxyProc.Id)) -> 127.0.0.1:2222"

    if (-not (Test-Path $tcpRelayScript)) { Fail "TCP relay script not found: $tcpRelayScript" }
    foreach ($port in 8080, 7683, 7686, 7687) {
        Start-TcpRelay -Port $port -NodePath $nodeExe -ScriptPath $tcpRelayScript -LauncherPath $launcherDir
    }
}

# -- 3. Kill stale tmux console session so drives remount on next connect -----
wsl -d $distro --user root -- bash -c "tmux kill-session -t console 2>/dev/null || true" | Out-Null
Write-Log "tmux console session: cleared"

# -- 4. Restart SSHwifty on port 7682 -----------------------------------------
if (-not (Test-Path $sshwiftyExe)) { Fail "SSHwifty binary not found: $sshwiftyExe`nRun setup-console-windows.ps1 first." }
if (-not (Test-Path $sshwiftyConf)) { Fail "SSHwifty config not found: $sshwiftyConf`nRun sync-secrets.bat then setup-console-windows.ps1." }

Get-Process -Name "sshwifty_windows_amd64" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

Start-Process -FilePath $sshwiftyExe `
    -ArgumentList "-config", $sshwiftyConf `
    -RedirectStandardError $sshwiftyLog `
    -WindowStyle Hidden
Write-Log "SSHwifty: started -> 127.0.0.1:7682"

# -- 5. Restart launcher proxy on port 7681 -----------------------------------
if (-not (Test-Path $proxyScript)) { Fail "Proxy script not found: $proxyScript`nRun setup-console-windows.ps1 first." }

if (Test-Path $proxyPidFile) {
    $oldPid = (Get-Content $proxyPidFile -ErrorAction SilentlyContinue).Trim()
    if ($oldPid -match '^\d+$') {
        Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $proxyPidFile -Force -ErrorAction SilentlyContinue
}
Stop-ListenerOnPort -Port 7681
Start-Sleep -Milliseconds 300

if (-not $nodeExe) { Fail "node.exe not found. Run 3-setup-node.bat first." }

$proxyProc = Start-Process -FilePath $nodeExe `
    -ArgumentList $proxyScript `
    -RedirectStandardError $proxyLog `
    -WindowStyle Hidden `
    -PassThru
$proxyProc.Id | Out-File -FilePath $proxyPidFile -Encoding utf8
Write-Log "Launcher proxy: started (PID $($proxyProc.Id)) -> 127.0.0.1:7681"

# -- 6. Restart cloudflared via the self-healing supervisor -------------------
# The supervisor waits for the Cloudflare edge to be reachable before launching
# cloudflared and relaunches it if it ever exits - this is what makes the console
# survive a reboot where the network/ProtonVPN isn't ready yet at logon.
if (-not (Test-Path $cfExe))         { Fail "cloudflared.exe not found at $cfExe. Run cloudflared\install-all.ps1 first." }
if (-not (Test-Path $devConfigPath)) { Fail "dev-config.yml not found. Run setup-console-windows.ps1 first." }
if (-not (Test-Path $cfSupervisor))  { Fail "tunnel-supervisor.ps1 not found: $cfSupervisor. Run setup-console-windows.ps1 first." }

# Stop the previous supervisor (if any) so we don't stack duplicates.
if (Test-Path $cfSupervisorPidFile) {
    $oldSup = (Get-Content $cfSupervisorPidFile -ErrorAction SilentlyContinue).Trim()
    if ($oldSup -match '^\d+$') { Stop-Process -Id ([int]$oldSup) -Force -ErrorAction SilentlyContinue }
    Remove-Item $cfSupervisorPidFile -Force -ErrorAction SilentlyContinue
}
# Stop any cloudflared bound to the dev-console config.
if (Test-Path $cfPidFile) {
    $oldCfPidVal = (Get-Content $cfPidFile -ErrorAction SilentlyContinue).Trim()
    if ($oldCfPidVal -match '^\d+$') { Stop-Process -Id ([int]$oldCfPidVal) -Force -ErrorAction SilentlyContinue }
    Remove-Item $cfPidFile -Force -ErrorAction SilentlyContinue
}
Get-Process cloudflared -ErrorAction SilentlyContinue | ForEach-Object {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
    if ($cmd -like "*dev-config*") { Stop-Process -Id $_.Id -Force }
}
Start-Sleep -Milliseconds 500

$supProc = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $cfSupervisor,
        '-ConfigPath', $devConfigPath, '-CfLog', $cfLog, '-LogPath', $cfSupervisorLog, '-CfPidFile', $cfPidFile, '-Label', 'dev-console' `
    -WindowStyle Hidden `
    -PassThru
$supProc.Id | Out-File -FilePath $cfSupervisorPidFile -Encoding utf8
Write-Log "cloudflared supervisor: started (PID $($supProc.Id)) - waits for edge, self-heals"
Write-Log "  cloudflared log: $cfLog"
Write-Log "  supervisor log:  $cfSupervisorLog"

# -- 7. Verify -----------------------------------------------------------------
Start-Sleep -Seconds 5

$sshwiftyOk = [bool](Get-Process -Name "sshwifty_windows_amd64" -ErrorAction SilentlyContinue)
$proxyOk    = (Test-Path $proxyPidFile)
# Tunnel is "ok" when the supervisor is alive. If the edge is up (interactive run)
# cloudflared is already connected; at boot it connects as soon as the net is ready.
$tunnelOk   = (Test-Path $cfSupervisorPidFile) -and [bool](Get-Process -Id ([int](Get-Content $cfSupervisorPidFile -ErrorAction SilentlyContinue).Trim()) -ErrorAction SilentlyContinue)

Write-Host ""
if ($sshwiftyOk -and $proxyOk -and $tunnelOk) {
    Write-Host "[start-console] Console ready:" -ForegroundColor Green
    Write-Host "  https://console.ffxiv.be"
    Write-Host "  Click the SSHwifty logo top-left to open the quick-connect panel."
} else {
    if (-not $sshwiftyOk) { Write-Host "[start-console] WARNING: SSHwifty is not running" -ForegroundColor Yellow }
    if (-not $proxyOk)    { Write-Host "[start-console] WARNING: Launcher proxy is not running" -ForegroundColor Yellow }
    if (-not $tunnelOk)   { Write-Host "[start-console] WARNING: cloudflared supervisor is not running" -ForegroundColor Yellow }
    Write-Host "  SSHwifty log:   $sshwiftyLog"
    Write-Host "  Proxy log:      $proxyLog"
    Write-Host "  Cloudflare log: $cfLog"
}
Write-Host ""
Write-Host "  Live log: Get-Content -Wait '$cfLog'"
