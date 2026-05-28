param(
    [string]$ReportDir = (Join-Path $env:USERPROFILE '.cloudflared\reports'),
    [switch]$Headed
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$accountId = 'd34896e6a0f8b2fba5e03dec659eac50'
$policyPrefix = 'Temporary IP bypass'
$routes = @(
    'console.ffxivbe.org',
    'code.ffxivbe.org',
    'ttyd.ffxivbe.org',
    'tools.ffxivbe.org',
    'git.ffxivbe.org'
)

. (Join-Path $PSScriptRoot 'shared-cloudflare-auth.ps1')

function Write-Log {
    param([string]$Message)
    Write-Host "[verify-public-routes] $Message"
}

function Fail {
    param([string]$Message)
    throw "[verify-public-routes] $Message"
}

function Ensure-Pnpm {
    $pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
    if ($pnpmCmd) {
        return $pnpmCmd.Source
    }

    Write-Log "pnpm not found; installing globally with npm..."
    & npm.cmd install -g pnpm
    if ($LASTEXITCODE -ne 0) {
        Fail "Failed to install pnpm via npm."
    }

    $pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
    if (-not $pnpmCmd) {
        Fail "pnpm install reported success but pnpm is still not on PATH."
    }

    return $pnpmCmd.Source
}

function Ensure-PlaywrightDependencies {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkingDir,
        [Parameter(Mandatory = $true)]
        [string]$PnpmPath
    )

    $lockPath = Join-Path $WorkingDir 'pnpm-lock.yaml'
    $nodeModulesPath = Join-Path $WorkingDir 'node_modules'

    if ((-not (Test-Path $lockPath)) -or (-not (Test-Path $nodeModulesPath))) {
        Write-Log "Installing Playwright dependencies with pnpm..."
        & $PnpmPath install --dir $WorkingDir
        if ($LASTEXITCODE -ne 0) {
            Fail "pnpm install failed in $WorkingDir"
        }
    } else {
        Write-Log "Refreshing Playwright dependencies from pnpm lockfile..."
        & $PnpmPath install --dir $WorkingDir --frozen-lockfile
        if ($LASTEXITCODE -ne 0) {
            Fail "pnpm install --frozen-lockfile failed in $WorkingDir"
        }
    }

    Write-Log "Ensuring Playwright Chromium browser is installed..."
    & $PnpmPath --dir $WorkingDir exec playwright install chromium
    if ($LASTEXITCODE -ne 0) {
        Fail "pnpm exec playwright install chromium failed"
    }
}

function Find-AccessAppForHostname {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Apps,
        [Parameter(Mandatory = $true)]
        [string]$Hostname
    )

    $matches = @(
        $Apps | Where-Object {
            ($_.domain -eq $Hostname) -or
            ($_.self_hosted_domains -contains $Hostname)
        }
    )

    return $matches | Select-Object -First 1
}

function Remove-TemporaryPolicies {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Apps,
        [Parameter(Mandatory = $true)]
        [string]$CurrentIpCidr
    )

    foreach ($app in $Apps) {
        $appId = if ($app.PSObject.Properties.Name -contains 'AppId') { $app.AppId } else { $app.id }
        $appName = if ($app.PSObject.Properties.Name -contains 'AppDomain') { $app.AppDomain } elseif ($app.PSObject.Properties.Name -contains 'Hostname') { $app.Hostname } else { $app.domain }

        $policiesResponse = Invoke-CloudflareApi -RepoRoot $repoRoot -Method GET -Path "/accounts/$accountId/access/apps/$appId/policies"
        $policies = @()
        if ($policiesResponse -is [System.Array]) {
            $policies = @($policiesResponse)
        } elseif ($policiesResponse.PSObject.Properties.Name -contains 'result') {
            $policies = @($policiesResponse.result)
        } else {
            $policies = @($policiesResponse)
        }

        foreach ($policy in $policies) {
            $policyName = [string]$policy.name
            if (-not $policyName.StartsWith($policyPrefix)) {
                continue
            }

            $includedIp = $false
            foreach ($rule in @($policy.include)) {
                if ($rule.PSObject.Properties.Name -contains 'ip' -and $rule.ip.PSObject.Properties.Name -contains 'ip') {
                    if ($rule.ip.ip -eq $CurrentIpCidr) {
                        $includedIp = $true
                        break
                    }
                }
            }

            if ($includedIp) {
                Write-Log "Removing stale policy '$policyName' from $appName"
                Remove-CloudflareAccessPolicy -RepoRoot $repoRoot -AccountId $accountId -AppId $appId -PolicyId $policy.id
            }
        }
    }
}

function Test-IpPolicyExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [Parameter(Mandatory = $true)]
        [string]$CurrentIpCidr
    )

    $policiesResponse = Invoke-CloudflareApi -RepoRoot $repoRoot -Method GET -Path "/accounts/$accountId/access/apps/$AppId/policies"
    $policies = @()
    if ($policiesResponse -is [System.Array]) {
        $policies = @($policiesResponse)
    } elseif ($policiesResponse.PSObject.Properties.Name -contains 'result') {
        $policies = @($policiesResponse.result)
    } else {
        $policies = @($policiesResponse)
    }

    foreach ($policy in $policies) {
        foreach ($rule in @($policy.include)) {
            if ($rule.PSObject.Properties.Name -contains 'ip' -and $rule.ip.PSObject.Properties.Name -contains 'ip') {
                if ($rule.ip.ip -eq $CurrentIpCidr) {
                    return $true
                }
            }
        }
    }

    return $false
}

function Invoke-PublicRouteVerification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VerifyScript,
        [Parameter(Mandatory = $true)]
        [string]$ReportDir
    )

    $nodeArgs = @($VerifyScript, $ReportDir)
    if ($Headed) {
        $nodeArgs += '--headed'
    }

    & node @nodeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Public route verification failed with exit code $LASTEXITCODE"
    }
}

New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

$pnpmPath = Ensure-Pnpm
Ensure-PlaywrightDependencies -WorkingDir $PSScriptRoot -PnpmPath $pnpmPath

$publicIp = Get-CloudflareCurrentPublicIp
$currentIpCidr = "$publicIp/32"
Write-Log "Current public IP: $currentIpCidr"

$apps = Get-CloudflareAccessApps -RepoRoot $repoRoot -AccountId $accountId
$selectedApps = foreach ($route in $routes) {
    $app = Find-AccessAppForHostname -Apps $apps -Hostname $route
    if (-not $app) {
        Fail "No Cloudflare Access app found for $route"
    }

    [pscustomobject]@{
        Hostname = $route
        AppId    = $app.id
        AppName  = $app.name
        AppDomain = $app.domain
    }
}

$createdPolicies = New-Object System.Collections.Generic.List[object]

try {
    $allRoutesCovered = $true
    foreach ($item in $selectedApps) {
        if (-not (Test-IpPolicyExists -AppId $item.AppId -CurrentIpCidr $currentIpCidr)) {
            $allRoutesCovered = $false
            break
        }
    }

    if ($allRoutesCovered) {
        Write-Log "Current IP is already allowlisted for all protected routes; skipping temporary bypass creation"
    } else {
        Remove-TemporaryPolicies -Apps $selectedApps -CurrentIpCidr $currentIpCidr

        foreach ($item in $selectedApps) {
            $policyName = "$policyPrefix - $($item.Hostname) - $currentIpCidr"
            Write-Log "Creating bypass for $($item.Hostname) via $($item.AppName)"
            $policy = New-CloudflareAccessPolicy -RepoRoot $repoRoot -AccountId $accountId -AppId $item.AppId -Name $policyName -IpCidr $currentIpCidr -Precedence 0
            $createdPolicies.Add([pscustomobject]@{
                AppId    = $item.AppId
                Hostname = $item.Hostname
                PolicyId = $policy.id
                Name     = $policy.name
            }) | Out-Null
        }

        Write-Log "Waiting for Access policy propagation..."
        Start-Sleep -Seconds 10
    }

    $verifyScript = Join-Path $PSScriptRoot 'verify-public-routes.mjs'
    if (-not (Test-Path $verifyScript)) {
        Fail "verify-public-routes.mjs not found at $verifyScript"
    }

    if ($Headed) {
        Write-Log "Running headed Playwright route verification..."
    } else {
        Write-Log "Running headless Playwright route verification..."
    }
    Invoke-PublicRouteVerification -VerifyScript $verifyScript -ReportDir $ReportDir

    $latestMd = Join-Path $ReportDir 'public-routes-latest.md'
    if (Test-Path $latestMd) {
        Write-Log "Report written to $latestMd"
    }
} finally {
    for ($i = $createdPolicies.Count - 1; $i -ge 0; $i--) {
        $policy = $createdPolicies[$i]
        try {
            Write-Log "Removing bypass policy for $($policy.Hostname)"
            Remove-CloudflareAccessPolicy -RepoRoot $repoRoot -AccountId $accountId -AppId $policy.AppId -PolicyId $policy.PolicyId
        } catch {
            Write-Log "WARNING: failed to remove policy $($policy.PolicyId) for $($policy.Hostname): $_"
        }
    }
}
