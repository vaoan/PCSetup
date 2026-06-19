param(
    [string]$AccountId = 'd34896e6a0f8b2fba5e03dec659eac50',
    [string[]]$IpCidr,
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
    param([string[]]$Value)

    if ($Value) {
        return @($Value | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }

    return @(Get-CloudflareCurrentPublicIpCidrs)
}

function Get-ExistingMatchingPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,
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
        [string]$_.name -like "$policyPrefix - $Hostname*"
    }
}

New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE '.cloudflared\reports') -Force | Out-Null

$currentIpCidrs = @(Get-CurrentPublicIpCidr -Value $IpCidr)
Write-Log "Using public IP allowlist CIDRs: $($currentIpCidrs -join ', ')"

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
    $existingPolicies = @(Get-ExistingMatchingPolicy -AppId $item.AppId -Hostname $item.Hostname)
    $allPolicies = @(Invoke-CloudflareApi -RepoRoot $repoRoot -Method GET -Path "/accounts/$AccountId/access/apps/$($item.AppId)/policies")
    $emailPolicies = @($allPolicies | Where-Object { $_.name -match '^Allow ' -and $_.decision -eq 'allow' })

    if ($DryRun) {
        foreach ($existing in $existingPolicies) {
            Write-Log "Dry run: would remove old allowlist for $($item.Hostname): $($existing.name)"
        }
        foreach ($existing in $emailPolicies) {
            Write-Log "Dry run: would reorder email policy for $($item.Hostname): $($existing.name)"
        }
        Write-Log "Dry run: would add this-PC allowlist for $($item.Hostname) via $($item.AppName): $($currentIpCidrs -join ', ')"
        continue
    }

    foreach ($existing in $existingPolicies) {
        Write-Log "Removing old allowlist for $($item.Hostname): $($existing.name)"
        Remove-CloudflareAccessPolicy -RepoRoot $repoRoot -AccountId $AccountId -AppId $item.AppId -PolicyId $existing.id
    }
    foreach ($existing in $emailPolicies) {
        Write-Log "Temporarily removing email policy for $($item.Hostname): $($existing.name)"
        Remove-CloudflareAccessPolicy -RepoRoot $repoRoot -AccountId $AccountId -AppId $item.AppId -PolicyId $existing.id
    }

    Write-Log "Adding permanent this-PC allowlist for $($item.Hostname) via $($item.AppName): $($currentIpCidrs -join ', ')"
    $null = New-CloudflareAccessPolicy -RepoRoot $repoRoot -AccountId $AccountId -AppId $item.AppId -Name "$policyPrefix - $($item.Hostname) - this PC" -IpCidr $currentIpCidrs -Precedence 1

    foreach ($existing in $emailPolicies) {
        Write-Log "Recreating email policy for $($item.Hostname): $($existing.name)"
        $body = @{
            name       = $existing.name
            decision   = $existing.decision
            precedence = 2
            include    = $existing.include
            require    = @($existing.require)
            exclude    = @($existing.exclude)
        }
        $null = Invoke-CloudflareApi -RepoRoot $repoRoot -Method POST -Path "/accounts/$AccountId/access/apps/$($item.AppId)/policies" -Body $body
    }
}

Write-Log "Permanent IP allowlist completed for $($selectedApps.Count) route(s)."
