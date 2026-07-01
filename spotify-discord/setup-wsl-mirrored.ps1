# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Put WSL2 into MIRRORED networking mode. This is a prerequisite for the
# Spotify->Discord bridge AND it simplifies the web console.
#
# Why mirrored:
#   * WSL shares the Windows network stack, so the go-librespot OAuth callback
#     (127.0.0.1:8898) is reachable from the Windows browser without fragile
#     localhost forwarding.
#   * hostAddressLoopback lets Windows (cloudflared) reach WSL services on
#     127.0.0.1 directly, so the console no longer needs Windows TCP relays.
#
# IMPORTANT CONSEQUENCES (handled by start-console.ps1's mirrored branch):
#   * WSL and Windows now share ports. WSL sshd must move OFF 22 (Windows OpenSSH
#     owns it) to 2222. The old Windows tcp-relay.js/ssh-proxy.js relays are no
#     longer used (they would squat the ports the WSL services need).
#
# Idempotent: only restarts WSL if the config actually changed.

$ErrorActionPreference = 'Stop'
$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
$desired = @"
[wsl2]
# Mirrored networking: WSL shares the Windows network stack so outbound UDP
# (Discord voice) and localhost forwarding work reliably.
networkingMode=mirrored

[experimental]
# Let Windows reach WSL services over 127.0.0.1 (cloudflared -> WSL console
# services directly; no TCP relays needed).
hostAddressLoopback=true
"@ -replace "`r`n", "`n"

function Write-Log { param([string]$m) Write-Host "[setup-wsl-mirrored] $m" }

$current = ''
if (Test-Path $wslConfig) { $current = ([IO.File]::ReadAllText($wslConfig) -replace "`r`n", "`n") }

if ($current.Trim() -eq $desired.Trim()) {
    Write-Log ".wslconfig already set to mirrored networking. Nothing to do."
} else {
    Write-Log "Writing mirrored networking config to $wslConfig"
    [IO.File]::WriteAllText($wslConfig, $desired, (New-Object System.Text.UTF8Encoding $false))
    Write-Log "Shutting down WSL to apply (services will restart)..."
    wsl --shutdown
    Start-Sleep -Seconds 6
    wsl -d Ubuntu-24.04 --user root -- echo "WSL rebooted" | Out-Null
    try { Start-ScheduledTask -TaskName WSLKeepAlive -ErrorAction Stop } catch { Write-Log "WSLKeepAlive task not found (run console setup first)" }
    Start-Sleep -Seconds 3
}

$mode = (wsl -d Ubuntu-24.04 --user root -- wslinfo --networking-mode 2>$null)
Write-Log "WSL networking mode: $mode"
if ("$mode".Trim() -ne 'mirrored') {
    Write-Log "WARNING: expected 'mirrored'. Check Windows/WSL versions (needs Win11 22H2+ / WSL 2.0+)."
}
