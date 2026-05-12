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
#   SSHwifty connects via SSH -> portproxy (127.0.0.1:2222) -> WSL:22
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
$cfLog         = "$cfDir\cloudflared-dev.log"
$cfPidFile     = "$cfDir\cloudflared-dev.pid"

function Write-Log { param([string]$msg) Write-Host "[start-console] $msg" }
function Fail { param([string]$msg) Write-Host "[start-console] ERROR: $msg" -ForegroundColor Red; exit 1 }

# -- 1. Update portproxy: 127.0.0.1:2222 -> WSL2 IP:22 -----------------------
Write-Log "Resolving WSL2 IP..."
$wslIp = (wsl -d $distro --user root -- bash -c "hostname -I | awk '{print `$1}'").Trim()
if (-not $wslIp) { Fail "Could not determine WSL2 IP. Is $distro running?" }
Write-Log "WSL2 IP: $wslIp"

netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=2222 2>$null | Out-Null
netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=2222 connectaddress=$wslIp connectport=22
Write-Log "portproxy: 127.0.0.1:2222 -> ${wslIp}:22"

netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=8080 2>$null | Out-Null
netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=8080 connectaddress=$wslIp connectport=8080
Write-Log "portproxy: 127.0.0.1:8080 -> ${wslIp}:8080"

# -- 2. Ensure SSH and code-server are running inside WSL ---------------------
wsl -d $distro --user root -- bash -c "service ssh start 2>/dev/null || true" | Out-Null
Write-Log "WSL SSH: started"

wsl -d $distro --user root -- bash -c "systemctl start code-server@root 2>/dev/null || true" | Out-Null
Write-Log "WSL code-server: started"

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
Start-Sleep -Milliseconds 300

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
$nodeExe = if ($nodeCmd) { $nodeCmd.Source } else { $null }
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
