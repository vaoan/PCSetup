<#
.SYNOPSIS
    Transfers ffxiv.be from Rebrandly/Tucows to DNSimple and delegates DNS to Cloudflare.

.DESCRIPTION
    Cloudflare Registrar does not support .be, so the registration lives at DNSimple
    while Cloudflare hosts the zone. This script drives the whole move through the
    DNSimple Registrar API:

        1. Verify DNSIMPLE_API_TOKEN and resolve the account id  (/v2/whoami)
        2. Confirm the domain is transferrable and show the price
        3. Resolve a registrant contact (required by the transfer endpoint)
        4. POST the transfer with the DNS Belgium auth code
        5. Poll until the transfer completes
        6. Delegate to the Cloudflare nameservers
        7. Enable auto-renew

    Steps 4-7 only run with -Execute. Without it the script validates everything and
    reports what it WOULD do, so a stray run never spends money.

.PARAMETER AuthCode
    Transfer code from DNS Belgium. Required with -Execute.

.PARAMETER Execute
    Actually perform the transfer. Omit for a dry run.

.EXAMPLE
    .\transfer-ffxiv-be.ps1
    .\transfer-ffxiv-be.ps1 -AuthCode 001-242-440-681-317 -Execute
#>

[CmdletBinding()]
param(
    [string]   $Domain      = 'ffxiv.be',
    [string]   $AuthCode,
    [string[]] $Nameservers = @('kellen.ns.cloudflare.com', 'paislee.ns.cloudflare.com'),
    [switch]   $Execute,
    [int]      $PollMinutes = 30
)

# Auto-elevate to Administrator (forwarding args so parameters survive the relaunch)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Domain)      { $argList += @('-Domain', $Domain) }
    if ($AuthCode)    { $argList += @('-AuthCode', $AuthCode) }
    if ($Nameservers) { $argList += @('-Nameservers', ($Nameservers -join ',')) }
    if ($Execute)     { $argList += '-Execute' }
    Start-Process PowerShell -ArgumentList $argList -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'
$API = 'https://api.dnsimple.com/v2'

function Write-Step { param($m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    $m" -ForegroundColor Yellow }
function Fail       { param($m) Write-Host "`nFAILED: $m" -ForegroundColor Red; exit 1 }

# ── Load DNSIMPLE_API_TOKEN from .secrets ────────────────────────────────────
$secretsPath = Join-Path (Split-Path $PSScriptRoot -Parent) '.secrets'
if (-not (Test-Path $secretsPath)) { Fail "No .secrets at $secretsPath — run cloudflared\sync-secrets.bat first." }

# NOTE: a pipeline with no matches yields @(), not $null — index it rather than
# chaining -replace, or the empty-array case throws instead of failing cleanly.
$line = @(Get-Content $secretsPath | Where-Object { $_ -match '^\s*DNSIMPLE_API_TOKEN\s*=' })[0]
if (-not $line) { Fail "DNSIMPLE_API_TOKEN not found in $secretsPath — add it, or run cloudflared\sync-secrets.bat after adding it to GitHub Secrets." }

$token = ($line -replace '^\s*DNSIMPLE_API_TOKEN\s*=\s*', '' -replace '["'']', '').Trim()
if (-not $token -or $token -eq 'replace_me') { Fail 'DNSIMPLE_API_TOKEN is present but unset in .secrets.' }

$headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }

function Invoke-DnsimpleApi {
    param($Method, $Path, $Body)
    $params = @{ Method = $Method; Uri = "$API$Path"; Headers = $headers; ContentType = 'application/json' }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 6 -Compress) }
    try { Invoke-RestMethod @params }
    catch {
        $detail = $_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        throw "$Method $Path -> $detail"
    }
}

# ── 1. Verify token, resolve account ─────────────────────────────────────────
Write-Step 'Verifying DNSimple token'
$who = Invoke-DnsimpleApi GET '/whoami'
$accountId = $who.data.account.id
if (-not $accountId) { Fail 'Token resolved to a user, not an account. Create an ACCOUNT access token, not a user token.' }
Write-Ok "account $accountId ($($who.data.account.email)) — plan: $($who.data.account.plan_identifier)"

# ── 2. Check the domain + price ──────────────────────────────────────────────
Write-Step "Checking $Domain"
try {
    $check = Invoke-DnsimpleApi GET "/$accountId/registrar/domains/$Domain/check"
    Write-Ok "available=$($check.data.available)  premium=$($check.data.premium)"
    if ($check.data.available) { Write-Warn 'Registry reports AVAILABLE — it may have expired. Verify before transferring.' }
} catch { Write-Warn "check unavailable: $_" }

try {
    $prices = Invoke-DnsimpleApi GET "/$accountId/registrar/domains/$Domain/prices"
    Write-Ok "transfer=$($prices.data.transfer_price)  renewal=$($prices.data.renewal_price)"
} catch { Write-Warn "prices unavailable: $_" }

# ── 3. Registrant contact (required by the transfer endpoint) ────────────────
Write-Step 'Resolving registrant contact'
$contacts = Invoke-DnsimpleApi GET "/$accountId/contacts"
if (-not $contacts.data -or $contacts.data.Count -eq 0) {
    Fail 'No contacts on the DNSimple account. Create one in the DNSimple UI (Contacts -> Add contact) — the transfer API requires a registrant_id.'
}
$registrant = $contacts.data[0]
Write-Ok "registrant $($registrant.id): $($registrant.first_name) $($registrant.last_name) <$($registrant.email)>"
if ($contacts.data.Count -gt 1) { Write-Warn "$($contacts.data.Count) contacts exist; using the first. Pass a different one by editing this script if wrong." }

# ── Dry run stops here ───────────────────────────────────────────────────────
if (-not $Execute) {
    Write-Step 'DRY RUN — nothing was purchased or changed'
    Write-Host @"
    Would POST /$accountId/registrar/domains/$Domain/transfers
        registrant_id = $($registrant.id)
        auth_code     = $(if ($AuthCode) { $AuthCode } else { '<missing — pass -AuthCode>' })
        auto_renew    = true
    Then delegate to: $($Nameservers -join ', ')

    Re-run with -AuthCode <code> -Execute to perform it.
"@ -ForegroundColor DarkGray
    exit 0
}

if (-not $AuthCode) { Fail '-Execute requires -AuthCode (the DNS Belgium transfer code).' }

# ── 4. Initiate the transfer ─────────────────────────────────────────────────
Write-Step "Initiating transfer of $Domain"
# NOTE: .be additionally requires the auth code as an extended attribute named 'auth'.
# DNSimple's own GET /v2/tlds/be/extended_attributes returns [] and their docs don't
# mention it, but the transfer endpoint rejects the request without it:
#   {"message":"Invalid extended attributes","errors":{"auth":["it's required"]}}
$transfer = Invoke-DnsimpleApi POST "/$accountId/registrar/domains/$Domain/transfers" @{
    registrant_id       = $registrant.id
    auth_code           = $AuthCode
    auto_renew          = $true
    extended_attributes = @{ auth = $AuthCode }
}
$transferId = $transfer.data.id
Write-Ok "transfer $transferId created — state: $($transfer.data.state)"

# ── 5. Poll until it settles ─────────────────────────────────────────────────
Write-Step "Polling transfer state (up to $PollMinutes min)"
$deadline = (Get-Date).AddMinutes($PollMinutes)
$state = $transfer.data.state
while ((Get-Date) -lt $deadline -and $state -notin @('completed', 'error', 'cancelled')) {
    Start-Sleep -Seconds 60
    $state = (Invoke-DnsimpleApi GET "/$accountId/registrar/domains/$Domain/transfers/$transferId").data.state
    Write-Host "    $(Get-Date -Format HH:mm:ss)  state=$state" -ForegroundColor DarkGray
}

if ($state -ne 'completed') {
    Write-Warn "Transfer is '$state' — registry transfers can take days."
    Write-Warn "Re-run later with:  .\transfer-ffxiv-be.ps1 -Execute -AuthCode $AuthCode"
    Write-Warn 'Delegation and auto-renew were NOT applied yet.'
    exit 0
}
Write-Ok 'Transfer completed.'

# ── 6. Delegate to Cloudflare ────────────────────────────────────────────────
Write-Step 'Delegating to Cloudflare nameservers'
$delegation = Invoke-DnsimpleApi PUT "/$accountId/registrar/domains/$Domain/delegation" $Nameservers
Write-Ok "delegation: $($delegation.data -join ', ')"

# ── 7. Auto-renew ────────────────────────────────────────────────────────────
Write-Step 'Enabling auto-renew'
try {
    Invoke-DnsimpleApi PUT "/$accountId/registrar/domains/$Domain/auto_renewal" | Out-Null
    Write-Ok 'auto-renew enabled'
} catch { Write-Warn "could not enable auto-renew: $_" }

Write-Step 'Done'
Write-Host @"
    $Domain now registered at DNSimple, delegated to Cloudflare.
    Watch the Cloudflare zone flip from 'pending' to 'active':
      cloudflared\verify-ffxiv-be.ps1     (or check the Cloudflare dashboard)
"@ -ForegroundColor Green
