<#
.SYNOPSIS
    Deploys ffxiv-be-shortener.js to Cloudflare Workers and verifies every slug.

.DESCRIPTION
    The ffxiv.be link shortener replaced Rebrandly. Slugs live directly in
    ffxiv-be-shortener.js — edit the LINKS map, then run this to publish.

    Uploads the module worker, then smoke-tests each slug through the
    workers.dev preview URL. Deploys take up to ~60s to reach every edge PoP,
    so the verifier retries rather than reporting a false failure.

    Requires CLOUDFLARE_ACCOUNT_API_TOKEN in .secrets (Workers Scripts: Edit).

.EXAMPLE
    .\deploy-shortener.ps1
    .\deploy-shortener.ps1 -SkipVerify
#>

[CmdletBinding()]
param(
    [string] $ScriptName = 'ffxiv-be-shortener',
    [switch] $SkipVerify,
    [int]    $VerifyRetries = 6
)

# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-ScriptName', $ScriptName)
    if ($SkipVerify) { $argList += '-SkipVerify' }
    Start-Process PowerShell -ArgumentList $argList -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'
$ACCOUNT = 'd34896e6a0f8b2fba5e03dec659eac50'

function Write-Step { param($m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Fail       { param($m) Write-Host "`nFAILED: $m" -ForegroundColor Red; exit 1 }

$workerPath = Join-Path $PSScriptRoot "$ScriptName.js"
if (-not (Test-Path $workerPath)) { Fail "Worker source not found: $workerPath" }

# ── Token ────────────────────────────────────────────────────────────────────
$secretsPath = Join-Path (Split-Path $PSScriptRoot -Parent) '.secrets'
$line = @(Get-Content $secretsPath -ErrorAction SilentlyContinue |
          Where-Object { $_ -match '^\s*CLOUDFLARE_ACCOUNT_API_TOKEN\s*=' })[0]
if (-not $line) { Fail "CLOUDFLARE_ACCOUNT_API_TOKEN not found in $secretsPath" }
$token = ($line -replace '^\s*CLOUDFLARE_ACCOUNT_API_TOKEN\s*=\s*', '' -replace '["'']', '').Trim()

# ── Upload ───────────────────────────────────────────────────────────────────
Write-Step "Deploying $ScriptName"

# curl.exe handles multipart with per-part content types more reliably here than
# Invoke-RestMethod, which does not let you set a part's Content-Type.
$curl = "$env:SystemRoot\System32\curl.exe"
if (-not (Test-Path $curl)) { Fail 'curl.exe not found (expected on Windows 10+).' }

$tmp = Join-Path $env:TEMP 'worker.js'
Copy-Item $workerPath $tmp -Force
try {
    $metadata = '{"main_module":"worker.js","compatibility_date":"2026-07-01"}'
    $response = & $curl -s -X PUT `
        -H "Authorization: Bearer $token" `
        -F "metadata=$metadata;type=application/json" `
        -F "worker.js=@$tmp;type=application/javascript+module" `
        "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/scripts/$ScriptName"
} finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

$result = $response | ConvertFrom-Json
if (-not $result.success) {
    Fail "upload rejected: $($result.errors | ConvertTo-Json -Compress)"
}
Write-Host "    deployed $($result.result.id) at $($result.result.modified_on)" -ForegroundColor Green

if ($SkipVerify) { exit 0 }

# ── Verify every slug ────────────────────────────────────────────────────────
$slugs = Select-String -Path $workerPath -Pattern "^\s+'?([A-Za-z0-9_-]+)'?:\s+'https://" |
         ForEach-Object { $_.Matches[0].Groups[1].Value }
if (-not $slugs) { Fail 'Could not parse any slugs out of the LINKS map.' }

$subdomain = (& $curl -s -H "Authorization: Bearer $token" `
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/workers/subdomain" | ConvertFrom-Json).result.subdomain
$base = "https://$ScriptName.$subdomain.workers.dev"

Write-Step "Verifying $($slugs.Count) slugs via $base"
# NOTE: use curl.exe, not Invoke-WebRequest. In PS7 `-MaximumRedirection 0`
# throws on a 3xx instead of returning it, so every redirect reads as a failure
# even when the Worker is answering correctly.
$failed = @()
foreach ($slug in $slugs) {
    $ok = $false
    for ($i = 1; $i -le $VerifyRetries; $i++) {
        $code = (& $curl -s -o NUL -w '%{http_code}' --max-time 20 "$base/$slug")
        if ($code -eq '302') { $ok = $true; break }
        Start-Sleep -Seconds 5   # edge propagation, not a real failure yet
    }
    if ($ok) { Write-Host "    ok    /$slug" -ForegroundColor DarkGray }
    else     { Write-Host "    FAIL  /$slug  (last http=$code)" -ForegroundColor Red; $failed += $slug }
}

if ($failed) { Fail "$($failed.Count) slug(s) not redirecting: $($failed -join ', ')" }
Write-Host "`nAll $($slugs.Count) slugs redirect correctly." -ForegroundColor Green
