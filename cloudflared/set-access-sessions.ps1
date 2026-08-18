# Sets Cloudflare Zero Trust Access app session_duration for every app on the account,
# and sets the global (org-level) session timeout to the same value.
# Defaults to 8760h (~1 year). Run after a fresh install to keep logins long-lived.
#
# Requires CLOUDFLARE_ACCOUNT_API_TOKEN in .secrets (token needs Access: Apps and Policies → Edit).
# Run cloudflared\sync-secrets.bat first if the token isn't synced.

[CmdletBinding()]
param(
    [string]$Duration  = '8760h',
    [string]$AccountId = 'd34896e6a0f8b2fba5e03dec659eac50'
)

# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'

$rootDir     = Split-Path -Parent $PSScriptRoot
$secretsPath = Join-Path $rootDir '.secrets'

if (-not (Test-Path $secretsPath)) {
    Write-Host "[access-sessions] ERROR: .secrets not found at $secretsPath" -ForegroundColor Red
    Write-Host "[access-sessions] Run cloudflared\sync-secrets.bat first." -ForegroundColor Red
    exit 1
}

$line = Select-String -Path $secretsPath -Pattern '^CLOUDFLARE_ACCOUNT_API_TOKEN=' | Select-Object -First 1
if (-not $line) {
    Write-Host "[access-sessions] ERROR: CLOUDFLARE_ACCOUNT_API_TOKEN not found in .secrets" -ForegroundColor Red
    exit 1
}
$token = ($line.Line -split '=', 2)[1].Trim()
if (-not $token -or $token -eq 'replace_me') {
    Write-Host "[access-sessions] ERROR: CLOUDFLARE_ACCOUNT_API_TOKEN is empty or placeholder" -ForegroundColor Red
    exit 1
}

$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
$base    = "https://api.cloudflare.com/client/v4/accounts/$AccountId/access/apps"

Write-Host "[access-sessions] Fetching Access apps..."
$apps = (Invoke-RestMethod -Uri "${base}?per_page=50" -Headers $headers -Method Get).result
Write-Host "[access-sessions] Setting session_duration = $Duration on $($apps.Count) app(s)"

# Cloudflare's PUT endpoint rejects these read-only / nested fields.
$exclude = @('id','aud','created_at','updated_at','policies','tags','scim_config','reusable')

$failed = 0
foreach ($app in $apps) {
    if ($app.session_duration -eq $Duration) {
        Write-Host ("SKIP {0,-45} already {1}" -f $app.name, $Duration)
        continue
    }
    $payload = [ordered]@{}
    foreach ($prop in $app.PSObject.Properties) {
        if ($exclude -notcontains $prop.Name) { $payload[$prop.Name] = $prop.Value }
    }
    $payload['session_duration'] = $Duration
    $body = $payload | ConvertTo-Json -Depth 10 -Compress
    try {
        $resp = Invoke-RestMethod -Uri "$base/$($app.id)" -Headers $headers -Method Put -Body $body
        Write-Host ("OK   {0,-45} {1} -> {2}" -f $app.name, $app.session_duration, $resp.result.session_duration)
    } catch {
        $failed++
        Write-Host ("ERR  {0,-45} {1}" -f $app.name, $_.Exception.Message) -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host ("     " + $_.ErrorDetails.Message) -ForegroundColor Red }
    }
}

if ($failed -gt 0) { exit 1 }

# --- Global (org-level) session timeout ---
Write-Host "`n[access-sessions] Setting global session timeout = $Duration..."
$orgBase = "https://api.cloudflare.com/client/v4/accounts/$AccountId/access/organizations"
try {
    $org = (Invoke-RestMethod -Uri $orgBase -Headers $headers -Method Get).result
    $orgPayload = [ordered]@{
        name                 = $org.name
        auth_domain          = $org.auth_domain
        auth_session_duration = $Duration
    }
    $orgResp = Invoke-RestMethod -Uri $orgBase -Headers $headers -Method Put `
        -Body ($orgPayload | ConvertTo-Json -Depth 5 -Compress)
    Write-Host ("OK   global session timeout -> {0}" -f $orgResp.result.auth_session_duration)
} catch {
    Write-Host ("ERR  global session timeout: {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host ("     " + $_.ErrorDetails.Message) -ForegroundColor Red }
    exit 1
}
