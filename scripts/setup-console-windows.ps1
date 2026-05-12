# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# First-time setup for the web console on Windows.
# Run AFTER: sync-secrets.bat (to populate .secrets), and 2-setup-windows.bat (for cloudflared + node).
#
# What this does:
#   1. Creates %USERPROFILE%\Documents\Cloudflare\{sshwifty,launcher} dirs
#   2. Writes sshwifty.conf.json from .secrets (SSHWIFTY_CONF_B64)
#   3. Writes cloudflared tunnel credentials JSON from .secrets (CLOUDFLARE_DEV_CREDENTIALS_B64)
#   4. Writes ~/.cloudflared/dev-config.yml
#   5. Copies launcher scripts (console-proxy.js, console-launcher.js) from repo
#   6. Creates CloudflaredDevTunnel scheduled task
#   7. Creates UpdateWSLPortProxy scheduled task (runs at logon)

$ErrorActionPreference = 'Stop'

$repoRoot      = Split-Path -Parent $PSScriptRoot
$secretsFile   = Join-Path $repoRoot '.secrets'
$cloudflareDir = "$env:USERPROFILE\Documents\Cloudflare"
$sshwiftyDir   = "$cloudflareDir\sshwifty"
$launcherDir   = "$cloudflareDir\launcher"
$cfDir         = "$env:USERPROFILE\.cloudflared"
$cfExe         = 'C:\ProgramData\chocolatey\lib\cloudflared\tools\cloudflared.exe'
$devConfigPath = "$cfDir\dev-config.yml"
$tunnelId      = 'c28375cb-0b8f-433b-aed6-48fb1d0090e9'
$credPath      = "$cfDir\$tunnelId.json"
$distro        = 'Ubuntu-24.04'

function Write-Log { param([string]$msg) Write-Host "[setup-console] $msg" }
function Fail { param([string]$msg) Write-Host "[setup-console] ERROR: $msg" -ForegroundColor Red; exit 1 }

function Read-Secret {
    param([string]$key)
    if (-not (Test-Path $secretsFile)) { Fail ".secrets not found at $secretsFile. Run sync-secrets.bat first." }
    $line = Get-Content $secretsFile | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
    if (-not $line) { Fail "Secret '$key' not found in .secrets. Add it to GitHub Secrets and re-run sync-secrets.bat." }
    return ($line -replace "^$key=", '').Trim()
}

# -- 1. Create directories ----------------------------------------------------
Write-Log "Creating directories..."
New-Item -ItemType Directory -Path $sshwiftyDir  -Force | Out-Null
New-Item -ItemType Directory -Path $launcherDir  -Force | Out-Null
New-Item -ItemType Directory -Path $cfDir        -Force | Out-Null

# -- 2. Write sshwifty.conf.json from .secrets --------------------------------
Write-Log "Writing sshwifty.conf.json..."
$sshwiftyConfB64 = Read-Secret 'SSHWIFTY_CONF_B64'
$sshwiftyConfJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($sshwiftyConfB64))
[IO.File]::WriteAllText("$sshwiftyDir\sshwifty.conf.json", $sshwiftyConfJson, [Text.Encoding]::UTF8)

# -- 3. Write tunnel credentials JSON from .secrets ---------------------------
Write-Log "Writing tunnel credentials..."
$credB64 = Read-Secret 'CLOUDFLARE_DEV_CREDENTIALS_B64'
$credJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($credB64))
[IO.File]::WriteAllText($credPath, $credJson, [Text.Encoding]::UTF8)

# -- 4. Write dev-config.yml --------------------------------------------------
Write-Log "Writing cloudflared dev-config.yml..."
$devConfig = @"
tunnel: $tunnelId
credentials-file: $($credPath -replace '\\', '\\')
protocol: http2

ingress:
  - hostname: console.ffxivbe.org
    service: http://localhost:7681
  - hostname: dev.ffxivbe.org
    service: ssh://localhost:22
  - hostname: code.ffxivbe.org
    service: http://localhost:8080
  - hostname: zellij.ffxivbe.org
    service: http://localhost:7683
  - service: http_status:404
"@
[IO.File]::WriteAllText($devConfigPath, $devConfig, [Text.Encoding]::UTF8)

# -- 5. Copy launcher scripts from repo ---------------------------------------
Write-Log "Copying launcher scripts..."
Copy-Item "$PSScriptRoot\console-proxy.js"    "$launcherDir\console-proxy.js"    -Force
Copy-Item "$PSScriptRoot\console-launcher.js" "$launcherDir\console-launcher.js" -Force
Copy-Item "$PSScriptRoot\start-console.ps1"   "$cloudflareDir\start-console.ps1" -Force

# -- 6. Check sshwifty binary -------------------------------------------------
$sshwiftyExe = "$sshwiftyDir\sshwifty_windows_amd64.exe"
if (-not (Test-Path $sshwiftyExe)) {
    Write-Host ""
    Write-Host "[setup-console] ACTION REQUIRED: SSHwifty binary not found." -ForegroundColor Yellow
    Write-Host "  Download sshwifty_windows_amd64.exe from:"
    Write-Host "  https://github.com/nirui/sshwifty/releases/tag/0.4.6-beta-release"
    Write-Host "  Place it at: $sshwiftyExe"
    Write-Host ""
    Write-Host "  After placing the binary, run start-console.ps1 to launch everything."
    Write-Host ""
}

# -- 7. CloudflaredDevTunnel scheduled task -----------------------------------
Write-Log "Creating CloudflaredDevTunnel scheduled task..."
if (-not (Test-Path $cfExe)) {
    Write-Host "[setup-console] WARNING: cloudflared.exe not found at $cfExe — task created but may fail until cloudflared is installed." -ForegroundColor Yellow
}

$taskName  = "CloudflaredDevTunnel"
$taskArgs  = "tunnel --config `"$devConfigPath`" run"
$action    = New-ScheduledTaskAction -Execute $cfExe -Argument $taskArgs
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
Write-Log "Scheduled task '$taskName' created (runs at logon, elevated)"

# -- 8. UpdateWSLPortProxy scheduled task -------------------------------------
Write-Log "Creating UpdateWSLPortProxy scheduled task..."
$proxyTaskName = "UpdateWSLPortProxy"
$proxyScript = @"
`$distro = 'Ubuntu-24.04'
`$wslIp = (wsl -d `$distro --user root -- bash -c "hostname -I | awk '{print \`$1}'").Trim()
if (`$wslIp) {
    netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=2222 2>`$null | Out-Null
    netsh interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=2222 connectaddress=`$wslIp connectport=22
}
"@
$proxyScriptPath = "$cfDir\update-wsl-portproxy.ps1"
[IO.File]::WriteAllText($proxyScriptPath, $proxyScript, [Text.Encoding]::UTF8)

$proxyAction   = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$proxyScriptPath`""
$proxyTrigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$proxySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$proxyPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

Unregister-ScheduledTask -TaskName $proxyTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $proxyTaskName -Action $proxyAction -Trigger $proxyTrigger `
    -Settings $proxySettings -Principal $proxyPrincipal -Force | Out-Null
Write-Log "Scheduled task '$proxyTaskName' created (runs at logon, elevated)"

# -- Done ----------------------------------------------------------------------
Write-Host ""
Write-Host "[setup-console] Setup complete." -ForegroundColor Green
Write-Host "  Next: run start-console.ps1 (or start-console.bat) to launch the console."
Write-Host "  Remote: https://console.ffxivbe.org"
Write-Host ""
Write-Host "  Files deployed to:"
Write-Host "    $sshwiftyDir\"
Write-Host "    $launcherDir\"
Write-Host "    $devConfigPath"
