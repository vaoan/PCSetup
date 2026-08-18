# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# One-time Spotify OAuth login for the WSL go-librespot "Discord" device.
#
# Why this is a Windows script (not the WSL .sh): go-librespot's OAuth callback
# server listens INSIDE WSL on 127.0.0.1:8898, but the browser runs on Windows.
# WSL2's automatic localhost forwarding is unreliable on long-running VMs, so we
# bridge Windows 127.0.0.1:8898 -> WSL:8898 with a netsh portproxy for the
# duration of the login. config.yml pins credentials.interactive.callback_port
# to 8898 so this port is stable.
#
# It also temporarily disables the service's auto-restart so the PKCE challenge
# can't rotate mid-login, then restores normal operation once credentials persist.

$ErrorActionPreference = 'Stop'
$Distro = 'Ubuntu-24.04'
$Port   = 8898
$Cfg    = '/root/.config/go-librespot'

function Wsl { param([Parameter(ValueFromRemainingArguments)] $a) & wsl -d $Distro --user root -- @a }

Write-Host "[login-spotify] Checking for existing credentials..."
$state = (Wsl cat "$Cfg/state.json" 2>$null) -join ''
if ($state -match '"data":"[^"]+"') {
    Write-Host "[login-spotify] Already logged in (credentials present). Nothing to do."
    Write-Host "[login-spotify] To force a fresh login, delete $Cfg/state.json in WSL first."
    exit 0
}

Write-Host "[login-spotify] Pinning a stable process for login (restart off)..."
Wsl bash -c "mkdir -p /etc/systemd/system/go-librespot.service.d; printf '[Service]\nRestart=no\n' > /etc/systemd/system/go-librespot.service.d/nologin-restart.conf; systemctl daemon-reload; systemctl reset-failed go-librespot 2>/dev/null; systemctl restart go-librespot" | Out-Null
Start-Sleep -Seconds 4

# In mirrored networking mode Windows reaches WSL on 127.0.0.1 directly
# (hostAddressLoopback), so no portproxy is needed. Only bridge in NAT mode.
$netMode = (Wsl wslinfo --networking-mode 2>$null | Out-String).Trim()
if ($netMode -eq 'mirrored') {
    Write-Host "[login-spotify] Mirrored networking: callback reachable on 127.0.0.1:$Port directly."
} else {
    Write-Host "[login-spotify] Bridging Windows 127.0.0.1:$Port -> WSL:$Port ..."
    $wslIp = ((Wsl hostname -I) -join ' ').Trim().Split(' ')[0]
    netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$Port 2>$null | Out-Null
    netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=$Port connectaddress=$wslIp connectport=$Port | Out-Null
}

$log = (Wsl bash -c "journalctl -u go-librespot -n 8 --no-pager | sed -E 's/\x1b\[[0-9;]*m//g'") -join "`n"
$url = ([regex]::Match($log, 'https://accounts\.spotify\.com/authorize\S+')).Value
if (-not $url) { Write-Host "[login-spotify] Could not find auth URL in journal. Check: wsl -d $Distro --user root journalctl -u go-librespot"; exit 1 }

Write-Host ""
Write-Host "==================================================================="
Write-Host " Opening Spotify authorization in your browser. Log in + click Agree."
Write-Host " If the page shows a connection error after Agree, that's fine —"
Write-Host " the login still completes. Waiting for credentials to save..."
Write-Host "==================================================================="
Write-Host ""
Start-Process $url

# Wait up to 5 minutes for credentials to persist
$saved = $false
for ($i = 0; $i -lt 150; $i++) {
    Start-Sleep -Seconds 2
    $s = (Wsl cat "$Cfg/state.json" 2>$null) -join ''
    if ($s -match '"data":"[^"]+"') { $saved = $true; break }
}

Write-Host "[login-spotify] Removing login bridge..."
netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$Port 2>$null | Out-Null

Write-Host "[login-spotify] Restoring normal service (auto-restart on, enabled at boot)..."
Wsl bash -c "rm -f /etc/systemd/system/go-librespot.service.d/nologin-restart.conf; systemctl daemon-reload; systemctl enable go-librespot 2>/dev/null; systemctl restart go-librespot; systemctl restart spotify-discord-bot 2>/dev/null" | Out-Null

if ($saved) {
    $user = ([regex]::Match(((Wsl cat "$Cfg/state.json") -join ''), '"username":"([^"]*)"')).Groups[1].Value
    Write-Host ""
    Write-Host "[login-spotify] SUCCESS — logged in as $user."
    Write-Host "[login-spotify] The 'Discord' device is now in your Spotify Connect menu."
} else {
    Write-Host ""
    Write-Host "[login-spotify] Timed out waiting for credentials. Re-run this script to retry."
    exit 1
}
