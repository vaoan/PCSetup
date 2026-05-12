# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# First-time setup for the web console on Windows.
# Run AFTER: sync-secrets.bat (to populate .secrets), 2-setup-windows.bat (for cloudflared + node),
#            and `cloudflared tunnel login` (creates cert.pem for API auth — one-time browser login).
#
# What this does:
#   1. Creates %USERPROFILE%\Documents\Cloudflare\{sshwifty,launcher} dirs
#   2. Writes sshwifty.conf.json from .secrets (SSHWIFTY_CONF_B64)
#   3. Provisions Cloudflare tunnel 'dev-console' (creates if missing) + DNS records
#   4. Writes ~/.cloudflared/dev-config.yml with the live tunnel ID
#   5. Copies launcher scripts (console-proxy.js, console-launcher.js) from repo
#   6. Creates CloudflaredDevTunnel scheduled task
#   7. Creates UpdateWSLPortProxy scheduled task (runs at logon)

$ErrorActionPreference = 'Stop'

$repoRoot         = Split-Path -Parent $PSScriptRoot
$secretsFile      = Join-Path $repoRoot '.secrets'
$cloudflareDir    = "$env:USERPROFILE\Documents\Cloudflare"
$sshwiftyDir      = "$cloudflareDir\sshwifty"
$launcherDir      = "$cloudflareDir\launcher"
$cfDir            = "$env:USERPROFILE\.cloudflared"
$cfExe            = 'C:\ProgramData\chocolatey\lib\cloudflared\tools\cloudflared.exe'
$certPem          = "$cfDir\cert.pem"
$devConfigPath    = "$cfDir\dev-config.yml"
$tunnelName       = 'dev-console'
$distro           = 'Ubuntu-24.04'
$consoleHostnames = @('console.ffxivbe.org','dev.ffxivbe.org','code.ffxivbe.org','zellij.ffxivbe.org')

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
$sshwiftyConfB64  = Read-Secret 'SSHWIFTY_CONF_B64'
$sshwiftyConfJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($sshwiftyConfB64))
[IO.File]::WriteAllText("$sshwiftyDir\sshwifty.conf.json", $sshwiftyConfJson, (New-Object System.Text.UTF8Encoding $false))

# -- 3. Provision Cloudflare tunnel + DNS records -----------------------------
Write-Log "Provisioning Cloudflare dev tunnel..."
if (-not (Test-Path $cfExe))   { Fail "cloudflared.exe not found at $cfExe. Run 2-setup-windows.bat first." }
if (-not (Test-Path $certPem)) { Fail "cloudflared not authenticated. Run: cloudflared tunnel login" }

$tunnelId = $null

# Try to create — exit 0 = new, non-zero = already exists (both are fine)
try { & $cfExe tunnel --origincert $certPem create $tunnelName 2>$null | Out-Null } catch { <# tunnel exists #> }

# Always look up the tunnel by name in the list (handles both new and existing)
$listJson = (& $cfExe tunnel --origincert $certPem list --output json 2>&1) -join "`n"
if ($listJson -match '(?s)(\[.*\])') {
    # deleted_at is '0001-01-01T00:00:00Z' (zero time) for active tunnels, a real date if deleted
    $tunnels  = ($Matches[1] | ConvertFrom-Json)
    $existing = @($tunnels | Where-Object { $_.name -eq $tunnelName -and $_.deleted_at -like '0001*' })
    if ($existing.Count -gt 0) {
        $tunnelId = $existing[0].id
        Write-Log "Tunnel ready: $tunnelName ($tunnelId)"
    }
}
if (-not $tunnelId) { Fail "Failed to create or find tunnel '$tunnelName'." }

$credPath = "$cfDir\$tunnelId.json"

# Create DNS routes (idempotent — cloudflared skips if record already exists)
foreach ($h in $consoleHostnames) {
    try { & $cfExe tunnel --origincert $certPem route dns $tunnelId $h 2>$null | Out-Null } catch { <# record exists #> }
    Write-Log "DNS route: $h -> $tunnelId"
}

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

# -- 6. Download sshwifty binary if missing -----------------------------------
$sshwiftyExe = "$sshwiftyDir\sshwifty_windows_amd64.exe"
if (-not (Test-Path $sshwiftyExe)) {
    Write-Log "Downloading sshwifty binary..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $releases  = Invoke-RestMethod -Uri 'https://api.github.com/repos/nirui/sshwifty/releases' -UseBasicParsing
    $asset     = $releases[0].assets | Where-Object { $_.name -like '*windows_amd64*' } | Select-Object -First 1
    if (-not $asset) { Fail "Could not find sshwifty Windows AMD64 asset in latest release." }

    $tarPath   = [IO.Path]::GetTempFileName() + '.tar.gz'
    $extractDir= [IO.Path]::Combine([IO.Path]::GetTempPath(), [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tarPath -UseBasicParsing
        tar -xzf $tarPath -C $extractDir
        $exeFile = Get-ChildItem -Path $extractDir -Filter '*.exe' -Recurse | Select-Object -First 1
        if (-not $exeFile) { Fail "No .exe found in sshwifty archive." }
        Move-Item $exeFile.FullName $sshwiftyExe -Force
        Write-Log "sshwifty $($releases[0].tag_name) downloaded"
    } finally {
        Remove-Item $tarPath    -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Log "sshwifty binary already present"
}

# -- 7. CloudflaredDevTunnel scheduled task -----------------------------------
# At logon: runs cloudflared hidden via a small PS launcher so output is
# captured to cloudflared-dev.log (same approach as start-console.ps1).
Write-Log "Creating CloudflaredDevTunnel scheduled task..."

$cfLog     = "$cfDir\cloudflared-dev.log"
$cfPidFile = "$cfDir\cloudflared-dev.pid"

$cfLauncherScript = @"
`$cfExe     = '$cfExe'
`$config    = '$devConfigPath'
`$logFile   = '$cfLog'
`$pidFile   = '$cfPidFile'

# Kill any existing dev-tunnel process
if (Test-Path `$pidFile) {
    `$oldPid = (Get-Content `$pidFile -ErrorAction SilentlyContinue).Trim()
    if (`$oldPid -match '^\d+`$') { Stop-Process -Id ([int]`$oldPid) -Force -ErrorAction SilentlyContinue }
    Remove-Item `$pidFile -Force -ErrorAction SilentlyContinue
}

`$proc = Start-Process -FilePath `$cfExe ``
    -ArgumentList 'tunnel', '--config', `$config, 'run' ``
    -WindowStyle Hidden ``
    -RedirectStandardError `$logFile ``
    -PassThru
`$proc.Id | Out-File -FilePath `$pidFile -Encoding utf8
"@
$cfLauncherPath = "$cfDir\start-dev-tunnel.ps1"
[IO.File]::WriteAllText($cfLauncherPath, $cfLauncherScript, [Text.Encoding]::UTF8)

$taskName  = "CloudflaredDevTunnel"
$taskArgs  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cfLauncherPath`""
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
Write-Log "Scheduled task '$taskName' created (runs at logon, hidden, logs to $cfLog)"

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

$proxyAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$proxyScriptPath`""
$proxyTrigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$proxySettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$proxyPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

Unregister-ScheduledTask -TaskName $proxyTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $proxyTaskName -Action $proxyAction -Trigger $proxyTrigger `
    -Settings $proxySettings -Principal $proxyPrincipal -Force | Out-Null
Write-Log "Scheduled task '$proxyTaskName' created (runs at logon, elevated)"

# -- Done ----------------------------------------------------------------------
Write-Host ""
Write-Host "[setup-console] Setup complete." -ForegroundColor Green
Write-Host "  Cloudflare tunnel: $tunnelName ($tunnelId)"
Write-Host "  Hostnames: $($consoleHostnames -join ', ')"
Write-Host ""
Write-Host "  Next: run start-console.bat to launch the console."
Write-Host "  Remote: https://console.ffxivbe.org"
Write-Host ""
Write-Host "  Files deployed to:"
Write-Host "    $sshwiftyDir\"
Write-Host "    $launcherDir\"
Write-Host "    $devConfigPath"
