# Connect to / run commands on the RackNerd cloud VPS using credentials read
# from the repo .secrets file (NEVER hardcode them).
#
# Since 2026-09-27 the box accepts key-based SSH only (PasswordAuthentication
# no), so this uses OpenSSH's ssh.exe with the key named in .secrets.
# RACKNERD_VPS_PASSWORD remains the root password for the RackNerd VNC
# console (recovery path); it is no longer accepted over SSH.
#
# Usage:
#   .\vps-ssh.ps1 "systemctl status spotify-discord-bot"     # run a remote command
#   .\vps-ssh.ps1 -Script path\to\local-script.sh            # run a local script remotely
#   .\vps-ssh.ps1 -Tunnel 8898                               # open an SSH -L tunnel (for OAuth login)
#
# Reads RACKNERD_VPS_IP / _USER / _SSH_PORT / _SSH_KEY_PATH from .secrets.
# Populate .secrets via `cloudflared\sync-secrets.bat` first.

param(
    [Parameter(Position = 0)][string]$Command,
    [string]$Script,
    [int]$Tunnel = 0
)

$ErrorActionPreference = 'Stop'
$secretsPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.secrets'

function Get-Secret {
    param([string]$Key, [string]$Default = $null)
    if (-not (Test-Path $secretsPath)) { throw ".secrets not found at $secretsPath. Run cloudflared\sync-secrets.bat first." }
    $line = Select-String -Path $secretsPath -Pattern "^$Key=" | Select-Object -First 1
    if (-not $line) {
        if ($null -ne $Default) { return $Default }
        throw "$Key not found in .secrets"
    }
    return ($line.Line -replace "^$Key=", '').Trim()
}

$ip      = Get-Secret 'RACKNERD_VPS_IP'
$user    = Get-Secret 'RACKNERD_VPS_USER'
$port    = Get-Secret 'RACKNERD_VPS_SSH_PORT' '22'
$keyPath = Get-Secret 'RACKNERD_VPS_SSH_KEY_PATH' (Join-Path $HOME '.ssh\libra_prod_ed25519')
if (-not (Test-Path $keyPath)) { throw "SSH key not found at $keyPath (set RACKNERD_VPS_SSH_KEY_PATH in .secrets)." }

$ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
if (-not $ssh) { throw "ssh.exe not found. Install the Windows OpenSSH client." }

$common = @('-i', $keyPath, '-p', $port, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', "$user@$ip")

if ($Tunnel -gt 0) {
    Write-Host "[vps-ssh] Opening tunnel 127.0.0.1:$Tunnel -> ${ip}:$Tunnel (Ctrl+C to close)"
    & $ssh.Source @common '-L' "${Tunnel}:localhost:$Tunnel" '-N'
} elseif ($Script) {
    if (-not (Test-Path $Script)) { throw "Script not found: $Script" }
    # Stream the script over stdin so it runs as one bash session on the box,
    # like plink -m did.
    Get-Content -Raw $Script | & $ssh.Source @common 'bash -s'
} elseif ($Command) {
    & $ssh.Source @common $Command
} else {
    Write-Host "Usage: .\vps-ssh.ps1 '<remote command>'  |  -Script <file>  |  -Tunnel <port>"
}
