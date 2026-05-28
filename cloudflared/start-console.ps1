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
$cfExe         = 'C:\ProgramData\chocolatey\lib\cloudflared\tools\cloudflared.exe'
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
$cfLog         = "$cfDir\cloudflared-dev.log"
$cfPidFile     = "$cfDir\cloudflared-dev.pid"
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

# -- 1. Resolve WSL IP and normalize local origin targets ---------------------
Write-Log "Resolving WSL2 IP..."
$wslIp = (wsl -d $distro --user root -- bash -c "hostname -I | cut -d ' ' -f1").Trim()
if (-not $wslIp) { Fail "Could not determine WSL2 IP. Is $distro running?" }
Write-Log "WSL2 IP: $wslIp"
$codeUser = Get-CodeServerUser
Write-Log "code-server user: $codeUser"

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
        -ArgumentList $ScriptPath, "--listen-port=$Port", "--target-port=$Port" `
        -RedirectStandardError $logFile `
        -WindowStyle Hidden `
        -PassThru
    $proc.Id | Out-File -FilePath $pidFile -Encoding utf8
    Write-Log "TCP relay: started (PID $($proc.Id)) -> 127.0.0.1:$Port"
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
wsl -d $distro --user root -- bash -c "service ssh start 2>/dev/null || true" | Out-Null
Write-Log "WSL SSH: started"

wsl -d $distro --user root -- bash -c "systemctl start code-server@$codeUser ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit git-proxy 2>/dev/null || true" | Out-Null
Write-Log "WSL services: started"

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

# -- 6. Restart cloudflared (detached, hidden, logs to file) ------------------
if (-not (Test-Path $cfExe))        { Fail "cloudflared.exe not found at $cfExe. Run 2-setup-windows.bat first." }
if (-not (Test-Path $devConfigPath)) { Fail "dev-config.yml not found. Run setup-console-windows.ps1 first." }

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

$cfProc = Start-Process -FilePath $cfExe `
    -ArgumentList "tunnel", "--config", $devConfigPath, "run" `
    -WindowStyle Hidden `
    -RedirectStandardError $cfLog `
    -PassThru
$cfProc.Id | Out-File -FilePath $cfPidFile -Encoding utf8
Write-Log "cloudflared: started (PID $($cfProc.Id))"
Write-Log "  log: $cfLog"

# -- 7. Verify -----------------------------------------------------------------
Start-Sleep -Seconds 5

$sshwiftyOk = [bool](Get-Process -Name "sshwifty_windows_amd64" -ErrorAction SilentlyContinue)
$proxyOk    = (Test-Path $proxyPidFile)
$tunnelOk   = (Test-Path $cfPidFile) -and [bool](Get-Process -Id ([int](Get-Content $cfPidFile -ErrorAction SilentlyContinue).Trim()) -ErrorAction SilentlyContinue)

Write-Host ""
if ($sshwiftyOk -and $proxyOk -and $tunnelOk) {
    Write-Host "[start-console] Console ready:" -ForegroundColor Green
    Write-Host "  https://console.ffxivbe.org"
    Write-Host "  Click the SSHwifty logo top-left to open the quick-connect panel."
} else {
    if (-not $sshwiftyOk) { Write-Host "[start-console] WARNING: SSHwifty is not running" -ForegroundColor Yellow }
    if (-not $proxyOk)    { Write-Host "[start-console] WARNING: Launcher proxy is not running" -ForegroundColor Yellow }
    if (-not $tunnelOk)   { Write-Host "[start-console] WARNING: cloudflared is not running" -ForegroundColor Yellow }
    Write-Host "  SSHwifty log:   $sshwiftyLog"
    Write-Host "  Proxy log:      $proxyLog"
    Write-Host "  Cloudflare log: $cfLog"
}
Write-Host ""
Write-Host "  Live log: Get-Content -Wait '$cfLog'"
