param(
    [string]$AccountId = 'd34896e6a0f8b2fba5e03dec659eac50',
    [string]$IpCidr,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$policyPrefix = 'Permanent IP allowlist'
$routes = @(
    'console.ffxivbe.org',
    'dev.ffxivbe.org',
    'code.ffxivbe.org',
    'ttyd.ffxivbe.org',
    'tools.ffxivbe.org',
    'git.ffxivbe.org'
)

. (Join-Path $PSScriptRoot 'shared-cloudflare-auth.ps1')

function Write-Log {
    param([string]$Message)
    Write-Host "[allowlist-current-ip] $Message"
}

function Find-AccessAppForHostname {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Apps,
        [Parameter(Mandatory = $true)]
        [string]$Hostname
    )

    $Apps | Where-Object {
        ($_.domain -eq $Hostname) -or
        ($_.self_hosted_domains -contains $Hostname)
    } | Select-Object -First 1
}

function Get-CurrentPublicIpCidr {
    param([string]$Value)

    if ($Value) {
        return $Value.Trim()
    }

    $publicIp = Get-CloudflareCurrentPublicIp
    return "$publicIp/32"
}

function Get-ExistingMatchingPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [Parameter(Mandatory = $true)]
        [string]$CurrentIpCidr,
        [Parameter(Mandatory = $true)]
        [string]$Hostname
    )

    $policiesResponse = Invoke-CloudflareApi -RepoRoot $repoRoot -Method GET -Path "/accounts/$AccountId/access/apps/$AppId/policies"
    $policies = @()
    if ($policiesResponse -is [System.Array]) {
        $policies = @($policiesResponse)
    } elseif ($policiesResponse.PSObject.Properties.Name -contains 'result') {
        $policies = @($policiesResponse.result)
    } else {
        $policies = @($policiesResponse)
    }

    return $policies | Where-Object {
        [string]$_.name -eq "$policyPrefix - $Hostname - $CurrentIpCidr"
    } | Select-Object -First 1
}

New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE '.cloudflared\reports') -Force | Out-Null

$currentIpCidr = Get-CurrentPublicIpCidr -Value $IpCidr
Write-Log "Using public IP allowlist CIDR: $currentIpCidr"

$apps = Get-CloudflareAccessApps -RepoRoot $repoRoot -AccountId $AccountId
$selectedApps = foreach ($route in $routes) {
    $app = Find-AccessAppForHostname -Apps $apps -Hostname $route
    if (-not $app) {
        throw "No Cloudflare Access app found for $route"
    }

    [pscustomobject]@{
        Hostname = $route
        AppId    = $app.id
        AppName  = $app.name
    }
}

foreach ($item in $selectedApps) {
    $existing = Get-ExistingMatchingPolicy -AppId $item.AppId -CurrentIpCidr $currentIpCidr -Hostname $item.Hostname
    if ($existing) {
        Write-Log "Already present for $($item.Hostname): $($existing.name)"
        continue
    }

    if ($DryRun) {
        Write-Log "Dry run: would add allowlist for $($item.Hostname) via $($item.AppName)"
        continue
    }

    Write-Log "Adding permanent allowlist for $($item.Hostname) via $($item.AppName)"
    $null = New-CloudflareAccessPolicy -RepoRoot $repoRoot -AccountId $AccountId -AppId $item.AppId -Name "$policyPrefix - $($item.Hostname) - $currentIpCidr" -IpCidr $currentIpCidr -Precedence 0
}

Write-Log "Permanent IP allowlist completed for $($selectedApps.Count) route(s)."
