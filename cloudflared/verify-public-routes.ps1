param(
    [string]$ReportDir = (Join-Path $env:USERPROFILE '.cloudflared\reports'),
    [switch]$Headed
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$accountId = 'd34896e6a0f8b2fba5e03dec659eac50'
$policyPrefix = 'Temporary public route verifier bypass'
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
        return [string](@($pnpmCmd)[0].Source)
    }

    Write-Log "pnpm not found; installing globally with npm..."
    & npm.cmd install -g pnpm | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Fail "Failed to install pnpm via npm."
    }

    $pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
    if (-not $pnpmCmd) {
        Fail "pnpm install reported success but pnpm is still not on PATH."
    }

    return [string](@($pnpmCmd)[0].Source)
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
    $previousCi = $env:CI
    $previousConfirmModulesPurge = $env:PNPM_CONFIG_CONFIRM_MODULES_PURGE

    try {
        $env:CI = 'true'
        $env:PNPM_CONFIG_CONFIRM_MODULES_PURGE = 'false'

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
    } finally {
        if ($null -eq $previousCi) {
            Remove-Item Env:CI -ErrorAction SilentlyContinue
        } else {
            $env:CI = $previousCi
        }

        if ($null -eq $previousConfirmModulesPurge) {
            Remove-Item Env:PNPM_CONFIG_CONFIRM_MODULES_PURGE -ErrorAction SilentlyContinue
        } else {
            $env:PNPM_CONFIG_CONFIRM_MODULES_PURGE = $previousConfirmModulesPurge
        }
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
        [object[]]$Apps
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

            Write-Log "Removing stale policy '$policyName' from $appName"
            Remove-CloudflareAccessPolicy -RepoRoot $repoRoot -AccountId $accountId -AppId $appId -PolicyId $policy.id
        }
    }
}

function Convert-AccessPolicyToCreateBody {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Policy
    )

    $body = @{
        name       = $Policy.name
        decision   = $Policy.decision
        precedence = $Policy.precedence
        include    = @($Policy.include)
    }

    if ($Policy.PSObject.Properties.Name -contains 'require' -and $Policy.require) {
        $body.require = @($Policy.require)
    }
    if ($Policy.PSObject.Properties.Name -contains 'exclude' -and $Policy.exclude) {
        $body.exclude = @($Policy.exclude)
    }

    return $body
}

function Get-AccessPolicies {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId
    )

    $policiesResponse = Invoke-CloudflareApi -RepoRoot $repoRoot -Method GET -Path "/accounts/$accountId/access/apps/$AppId/policies"
    if ($policiesResponse -is [System.Array]) {
        return @($policiesResponse)
    }
    if ($policiesResponse.PSObject.Properties.Name -contains 'result') {
        return @($policiesResponse.result)
    }
    return @($policiesResponse)
}

function Disable-AccessForVerification {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Apps,
        [Parameter(Mandatory = $true)]
        [System.Collections.IList]$Snapshots,
        [Parameter(Mandatory = $true)]
        [System.Collections.IList]$CreatedPolicies
    )

    foreach ($item in $Apps) {
        $policies = @(Get-AccessPolicies -AppId $item.AppId)
        $Snapshots.Add([pscustomobject]@{
            AppId    = $item.AppId
            Hostname = $item.Hostname
            Policies = $policies
        }) | Out-Null

        foreach ($policy in $policies) {
            Write-Log "Temporarily removing Access policy for $($item.Hostname): $($policy.name)"
            Remove-CloudflareAccessPolicy -RepoRoot $repoRoot -AccountId $accountId -AppId $item.AppId -PolicyId $policy.id
        }

        $policyName = "$policyPrefix - $($item.Hostname)"
        Write-Log "Temporarily disabling Access for $($item.Hostname) via $($item.AppName)"
        $policy = New-CloudflareEveryoneBypassPolicy -RepoRoot $repoRoot -AccountId $accountId -AppId $item.AppId -Name $policyName -Precedence 1
        $CreatedPolicies.Add([pscustomobject]@{
            AppId    = $item.AppId
            Hostname = $item.Hostname
            PolicyId = $policy.id
            Name     = $policy.name
        }) | Out-Null
    }
}

function Restore-AccessPolicies {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IList]$Snapshots
    )

    foreach ($snapshot in $Snapshots) {
        $currentPolicies = @(Get-AccessPolicies -AppId $snapshot.AppId)
        foreach ($policy in $currentPolicies) {
            Write-Log "Clearing verification policy for $($snapshot.Hostname): $($policy.name)"
            Remove-CloudflareAccessPolicy -RepoRoot $repoRoot -AccountId $accountId -AppId $snapshot.AppId -PolicyId $policy.id
        }

        foreach ($policy in @($snapshot.Policies | Sort-Object precedence)) {
            Write-Log "Restoring Access policy for $($snapshot.Hostname): $($policy.name)"
            $body = Convert-AccessPolicyToCreateBody -Policy $policy
            $null = Invoke-CloudflareApi -RepoRoot $repoRoot -Method POST -Path "/accounts/$accountId/access/apps/$($snapshot.AppId)/policies" -Body $body
        }
    }
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
$policySnapshots = New-Object System.Collections.Generic.List[object]

try {
    Remove-TemporaryPolicies -Apps $selectedApps
    Disable-AccessForVerification -Apps $selectedApps -Snapshots $policySnapshots -CreatedPolicies $createdPolicies

    Write-Log "Waiting 60 seconds for Access policy propagation..."
    Start-Sleep -Seconds 60

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
    try {
        Restore-AccessPolicies -Snapshots $policySnapshots
    } catch {
        Write-Log "WARNING: failed to restore Access policies: $_"
        throw
    }
}
