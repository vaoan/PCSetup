# Refreshes the "this PC" IP bypass so the current network skips the Zero Trust
# login prompt on every console hostname.
#
# In the reusable-policy model there is ONE account-level bypass policy
# ("PCSetup - This-PC IP bypass") attached to all console apps, so allowlisting a
# new IP is a single update instead of one policy per app. This script just
# rewrites that policy's IP list (detected automatically, or -IpCidr to override).
#
# The full gate (apps + email-allow + bypass + session duration) is provisioned
# by setup-access-apps.ps1; this is the quick "my IP changed" refresh.

param(
    [string]$AccountId = 'd34896e6a0f8b2fba5e03dec659eac50',
    [string[]]$IpCidr,
    [switch]$DryRun
)

# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -AccountId `"$AccountId`""
    if ($IpCidr) { $argList += " -IpCidr $($IpCidr -join ',')" }
    if ($DryRun) { $argList += ' -DryRun' }
    Start-Process PowerShell -ArgumentList $argList -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$bypassPolicyName = 'PCSetup - This-PC IP bypass'

. (Join-Path $PSScriptRoot 'shared-cloudflare-auth.ps1')

function Write-Log {
    param([string]$Message)
    Write-Host "[allowlist-current-ip] $Message"
}

New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE '.cloudflared\reports') -Force | Out-Null

$currentIpCidrs = if ($IpCidr) {
    @($IpCidr | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
} else {
    @(Get-CloudflareCurrentPublicIpCidrs)
}
Write-Log "Using public IP allowlist CIDRs: $($currentIpCidrs -join ', ')"

$include = @($currentIpCidrs | Where-Object { $_ } | Select-Object -Unique | ForEach-Object { @{ ip = @{ ip = $_ } } })
if (-not $include) { throw "No IP CIDRs resolved." }

$reusable = @(Get-CloudflareReusablePolicies -RepoRoot $repoRoot -AccountId $AccountId)
$bypass = $reusable | Where-Object { $_.name -eq $bypassPolicyName } | Select-Object -First 1

if ($DryRun) {
    if ($bypass) {
        Write-Log "Dry run: would set '$bypassPolicyName' -> $($currentIpCidrs -join ', ')"
    } else {
        Write-Log "Dry run: '$bypassPolicyName' does not exist yet — run setup-access-apps.ps1 to create it."
    }
    return
}

if (-not $bypass) {
    Write-Log "Reusable bypass policy not found; creating '$bypassPolicyName'."
    $null = New-CloudflareReusablePolicy -RepoRoot $repoRoot -AccountId $AccountId -Name $bypassPolicyName -Decision 'bypass' -Include $include
    Write-Log "Created '$bypassPolicyName'. Run setup-access-apps.ps1 if apps aren't attached to it yet."
} else {
    $null = Set-CloudflareReusablePolicyInclude -RepoRoot $repoRoot -AccountId $AccountId -PolicyId $bypass.id -Name $bypassPolicyName -Decision 'bypass' -Include $include
    Write-Log "Updated '$bypassPolicyName' — attached apps now bypass login from: $($currentIpCidrs -join ', ')"
}
