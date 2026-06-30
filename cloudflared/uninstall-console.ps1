# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"

# Fully removes the web console:
#   - Kills sshwifty, console proxy, cloudflared dev tunnel
#   - Removes scheduled tasks and portproxy rules
#   - Deletes deployed files and local config artifacts
#   - Stops WSL wetty/services used by the console stack
#   - Deletes Cloudflare DNS records and tunnel via API when possible
#
# To reinstall: run cloudflared\setup-console-windows.ps1

$cfDir         = "$env:USERPROFILE\.cloudflared"
$certPem       = Join-Path $cfDir "cert.pem"
$devConfigPath = Join-Path $cfDir "dev-config.yml"
$devIdPath     = Join-Path $cfDir "dev-tunnel-id.txt"
$cloudflareDir = "$env:USERPROFILE\Documents\Cloudflare"
$distro        = 'Ubuntu-24.04'

function Write-Log { param([string]$msg) Write-Host "[uninstall-console] $msg" }
function Get-CodeServerUser {
    $user = (& wsl -d $distro --user root -- bash -lc "getent passwd 1000 | cut -d: -f1" | Out-String).Trim()
    if (-not $user) { return 'root' }
    return $user
}

function Remove-FileIfExists {
    param([string]$Path)
    if (Test-Path $Path) {
        Remove-Item $Path -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Stop-ListenerOnPort {
    param([int]$Port)

    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $Port }
    foreach ($listener in @($listeners)) {
        if ($listener.OwningProcess -gt 0) {
            $proc = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -ne 'svchost') {
                Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# -- 1. Read tunnel ID from dev-config.yml before deleting it -----------------
$tunnelId = $null
if (Test-Path $devConfigPath) {
    $configContent = Get-Content $devConfigPath -Raw
    if ($configContent -match 'tunnel:\s*([a-f0-9-]{36})') {
        $tunnelId = $Matches[1]
        Write-Log "Found tunnel ID: $tunnelId"
    }
}

# -- 2. Kill running processes ------------------------------------------------
Get-Process -Name "sshwifty_windows_amd64" -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Log "sshwifty: stopped"

Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match 'node|cloudflared|wsl|wscript'
} | ForEach-Object {
    $cmd = $_.CommandLine
    if (-not $cmd) { $cmd = "" }
    if ($cmd -match 'console-proxy|console-launcher|ssh-proxy|start-console|dev-config|web-console|UpdateWSLPortProxy|dev-tunnel') {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
Write-Log "console-related processes: stopped"

# Stop the WSL keepalive. Kill the self-healing loop host FIRST, otherwise it
# would just respawn the session we kill next.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'wsl-keepalive' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object { $_.CommandLine -match 'sleep infinity' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$wslKeepalivePidFile = "$cloudflareDir\launcher\wsl-keepalive.pid"
if (Test-Path $wslKeepalivePidFile) {
    $kaPid = (Get-Content $wslKeepalivePidFile -ErrorAction SilentlyContinue).Trim()
    if ($kaPid -match '^\d+$') { Stop-Process -Id ([int]$kaPid) -Force -ErrorAction SilentlyContinue }
    Remove-Item $wslKeepalivePidFile -Force -ErrorAction SilentlyContinue
}
Remove-FileIfExists "$cfDir\wsl-keepalive.ps1"
Write-Log "WSL keepalive: stopped"

Stop-ListenerOnPort -Port 2222
Stop-ListenerOnPort -Port 7681
Stop-ListenerOnPort -Port 8080
Stop-ListenerOnPort -Port 7683
Stop-ListenerOnPort -Port 7686
Stop-ListenerOnPort -Port 7687
Write-Log "stale localhost listeners: cleared"

# -- 3. Remove scheduled tasks ------------------------------------------------
foreach ($taskName in @("web-console", "UpdateWSLPortProxy", "WSLKeepAlive", "CloudflaredDevTunnel", "dev-tunnel")) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
}
Write-Log "scheduled tasks: removed"

# -- 4. Remove portproxy rules -------------------------------------------------
foreach ($port in 2222, 8080, 7683, 7686, 7687) {
    netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$port 2>$null | Out-Null
}
Write-Log "portproxy: removed"

# -- 5. Remove deployed files --------------------------------------------------
Remove-Item "$cloudflareDir\sshwifty"            -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$cloudflareDir\launcher"            -Recurse -Force -ErrorAction SilentlyContinue
Remove-FileIfExists "$cloudflareDir\ssh-proxy.js"
Remove-FileIfExists "$cloudflareDir\tcp-relay.js"
Remove-FileIfExists "$cloudflareDir\start-console.ps1"
Remove-FileIfExists "$cloudflareDir\start-dev-tunnel.ps1"
Remove-FileIfExists "$cfDir\update-wsl-portproxy.ps1"
Remove-FileIfExists $devConfigPath
Remove-FileIfExists $devIdPath
Remove-FileIfExists "$cfDir\cloudflared-dev.log"
Remove-FileIfExists "$cfDir\cloudflared-dev.pid"
if ($tunnelId) {
    Remove-FileIfExists "$cfDir\$tunnelId.json"
}
Write-Log "deployed files: removed"

# -- 6. Stop and disable WSL services (ssh, code-server, dashboard) -----------
$codeUser = Get-CodeServerUser
wsl -d $distro --user root -- bash -c "systemctl stop ssh sshd wetty code-server@$codeUser code-server@root ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit git-proxy 2>/dev/null; systemctl disable ssh sshd wetty code-server@$codeUser code-server@root ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit git-proxy 2>/dev/null; true"
Write-Log "WSL services: stopped and disabled"

# -- 7. Clean up Cloudflare DNS + tunnel via API ------------------------------
if ($tunnelId -and (Test-Path $certPem)) {
    $pem  = Get-Content $certPem -Raw
    $b64  = $pem -replace '-----BEGIN ARGO TUNNEL TOKEN-----\s*','' -replace '\s*-----END ARGO TUNNEL TOKEN-----.*','' -replace '\s',''
    $tok  = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
    $hdrs = @{ Authorization = "Bearer $($tok.apiToken)"; 'Content-Type' = 'application/json' }

    $resp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$($tok.zoneID)/dns_records?per_page=100" `
                              -Headers $hdrs -ErrorAction SilentlyContinue
    if ($resp -and $resp.result) {
        foreach ($rec in ($resp.result | Where-Object { $_.content -like "*$tunnelId*" })) {
            $del = Invoke-RestMethod -Method DELETE `
                -Uri "https://api.cloudflare.com/client/v4/zones/$($tok.zoneID)/dns_records/$($rec.id)" `
                -Headers $hdrs -ErrorAction SilentlyContinue
            if ($del -and $del.success) { Write-Log "Deleted DNS: $($rec.name)" }
        }
    }

    try {
        $del = Invoke-RestMethod -Method DELETE `
            -Uri "https://api.cloudflare.com/client/v4/accounts/$($tok.accountID)/cfd_tunnel/$tunnelId" `
            -Headers $hdrs -ErrorAction Stop
        if ($del -and $del.success) {
            Write-Log "Cloudflare tunnel deleted"
        } else {
            Write-Log "Tunnel $tunnelId cleanup attempted (may already be deleted)"
        }
    } catch {
        Write-Log "Tunnel $tunnelId cleanup attempted but Cloudflare returned an error; continuing"
    }
} elseif (-not $tunnelId) {
    Write-Log "No tunnel ID found in dev-config.yml - skipping Cloudflare API cleanup"
} else {
    Write-Log "cert.pem not found - skipping Cloudflare API cleanup (delete tunnel manually)"
}

Write-Host ""
Write-Host "[uninstall-console] Uninstall complete." -ForegroundColor Green
Write-Host "  To reinstall: cloudflared\setup-console-windows.ps1"
