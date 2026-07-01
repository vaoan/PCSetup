# Connect to / run commands on the RackNerd cloud VPS using credentials read
# from the repo .secrets file (NEVER hardcode them). Requires plink (PuTTY).
#
# Usage:
#   .\vps-ssh.ps1 "systemctl status spotify-discord-bot"     # run a remote command
#   .\vps-ssh.ps1 -Script path\to\local-script.sh            # run a local script remotely
#   .\vps-ssh.ps1 -Tunnel 8898                               # open an SSH -L tunnel (for OAuth login)
#
# Reads RACKNERD_VPS_IP / _USER / _PASSWORD / _HOSTKEY from .secrets.
# Populate .secrets via `cloudflared\sync-secrets.bat` first.

param(
    [Parameter(Position = 0)][string]$Command,
    [string]$Script,
    [int]$Tunnel = 0
)

$ErrorActionPreference = 'Stop'
$secretsPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.secrets'

function Get-Secret {
    param([string]$Key)
    if (-not (Test-Path $secretsPath)) { throw ".secrets not found at $secretsPath. Run cloudflared\sync-secrets.bat first." }
    $line = Select-String -Path $secretsPath -Pattern "^$Key=" | Select-Object -First 1
    if (-not $line) { throw "$Key not found in .secrets" }
    return ($line.Line -replace "^$Key=", '').Trim()
}

function Find-Plink {
    $c = Get-Command plink.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @('C:\ProgramData\chocolatey\bin\PLINK.EXE', 'C:\Program Files\PuTTY\plink.exe')) {
        if (Test-Path $p) { return $p }
    }
    throw "plink not found. Install PuTTY (choco install putty)."
}

$ip       = Get-Secret 'RACKNERD_VPS_IP'
$user     = Get-Secret 'RACKNERD_VPS_USER'
$password = Get-Secret 'RACKNERD_VPS_PASSWORD'
$hostkey  = Get-Secret 'RACKNERD_VPS_HOSTKEY'
$plink    = Find-Plink

# RACKNERD_VPS_HOSTKEY may hold multiple fingerprints (RSA + ed25519), whitespace-
# separated, since plink negotiates whichever host-key algorithm — pin them all.
$common = @('-batch')
foreach ($hk in ($hostkey -split '\s+' | Where-Object { $_ })) { $common += @('-hostkey', $hk) }
$common += @('-ssh', '-pw', $password, "$user@$ip")

if ($Tunnel -gt 0) {
    Write-Host "[vps-ssh] Opening tunnel 127.0.0.1:$Tunnel -> ${ip}:$Tunnel (Ctrl+C to close)"
    & $plink @common '-L' "${Tunnel}:localhost:$Tunnel" '-N'
} elseif ($Script) {
    if (-not (Test-Path $Script)) { throw "Script not found: $Script" }
    & $plink @common '-m' $Script
} elseif ($Command) {
    & $plink @common $Command
} else {
    Write-Host "Usage: .\vps-ssh.ps1 '<remote command>'  |  -Script <file>  |  -Tunnel <port>"
}
