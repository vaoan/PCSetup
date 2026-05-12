# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Fully removes the web console:
#   - Kills sshwifty, proxy, cloudflared dev tunnel
#   - Removes scheduled tasks and portproxy rule
#   - Deletes deployed files
#   - Stops WSL wetty
#   - Deletes Cloudflare DNS records and tunnel via API
#
# To reinstall: run scripts\setup-console-windows.ps1

$cfDir         = "$env:USERPROFILE\.cloudflared"
$certPem       = "$cfDir\cert.pem"
$devConfigPath = "$cfDir\dev-config.yml"
$cloudflareDir = "$env:USERPROFILE\Documents\Cloudflare"
$distro        = 'Ubuntu-24.04'

function Write-Log { param([string]$msg) Write-Host "[uninstall-console] $msg" }

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

$proxyPidFile = "$cloudflareDir\launcher\proxy.pid"
if (Test-Path $proxyPidFile) {
    $proxyPidVal = (Get-Content $proxyPidFile -ErrorAction SilentlyContinue).Trim()
    if ($proxyPidVal -match '^\d+$') { Stop-Process -Id ([int]$proxyPidVal) -Force -ErrorAction SilentlyContinue }
    Remove-Item $proxyPidFile -Force -ErrorAction SilentlyContinue
}
Write-Log "proxy: stopped"

Get-Process cloudflared -ErrorAction SilentlyContinue | ForEach-Object {
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($_.Id)").CommandLine
    if ($cmd -like "*dev-config*") { Stop-Process -Id $_.Id -Force }
}
Write-Log "cloudflared dev tunnel: stopped"

# -- 3. Remove scheduled tasks ------------------------------------------------
Unregister-ScheduledTask -TaskName "CloudflaredDevTunnel" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "UpdateWSLPortProxy"   -Confirm:$false -ErrorAction SilentlyContinue
Write-Log "scheduled tasks: removed"

# -- 4. Remove portproxy rules -------------------------------------------------
netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=2222 2>$null | Out-Null
netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=8080 2>$null | Out-Null
netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=7683 2>$null | Out-Null
netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=7686 2>$null | Out-Null
netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=7687 2>$null | Out-Null
Write-Log "portproxy: removed"

# -- 5. Remove deployed files --------------------------------------------------
Remove-Item "$cloudflareDir\sshwifty"          -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$cloudflareDir\launcher"          -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$cloudflareDir\start-console.ps1" -Force   -ErrorAction SilentlyContinue
Remove-Item "$cfDir\update-wsl-portproxy.ps1"  -Force   -ErrorAction SilentlyContinue
Remove-Item $devConfigPath                     -Force   -ErrorAction SilentlyContinue
Write-Log "deployed files: removed"

# -- 6. Stop and disable WSL services (wetty, code-server) -------------------
wsl -d $distro --user root -- bash -c "systemctl stop wetty code-server@root ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit 2>/dev/null; systemctl disable wetty code-server@root ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit 2>/dev/null; true"
Write-Log "WSL wetty: stopped and disabled"

# -- 7. Clean up Cloudflare DNS + tunnel via API ------------------------------
if ($tunnelId -and (Test-Path $certPem)) {
    $pem  = Get-Content $certPem -Raw
    $b64  = $pem -replace '-----BEGIN ARGO TUNNEL TOKEN-----\s*',''-replace '\s*-----END ARGO TUNNEL TOKEN-----.*',''-replace '\s',''
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

    $del = Invoke-RestMethod -Method DELETE `
        -Uri "https://api.cloudflare.com/client/v4/accounts/$($tok.accountID)/cfd_tunnel/$tunnelId" `
        -Headers $hdrs -ErrorAction SilentlyContinue
    if ($del -and $del.success) { Write-Log "Cloudflare tunnel deleted" }
    else { Write-Log "Tunnel $tunnelId cleanup attempted (may already be deleted)" }

    Remove-Item "$cfDir\$tunnelId.json" -Force -ErrorAction SilentlyContinue
    Write-Log "Tunnel credentials: removed"
} elseif (-not $tunnelId) {
    Write-Log "No tunnel ID found in dev-config.yml - skipping Cloudflare API cleanup"
} else {
    Write-Log "cert.pem not found - skipping Cloudflare API cleanup (delete tunnel manually)"
}

Write-Host ""
Write-Host "[uninstall-console] Uninstall complete." -ForegroundColor Green
Write-Host "  To reinstall: scripts\setup-console-windows.ps1"
