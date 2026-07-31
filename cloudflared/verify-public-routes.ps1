param(
    [string]$ReportDir = (Join-Path $env:USERPROFILE '.cloudflared\reports'),
    [switch]$Headed
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$accountId = 'd34896e6a0f8b2fba5e03dec659eac50'
# Temp reusable "everyone bypass" policy used only during verification.
$policyPrefix = 'Temporary public route verifier bypass'
# Canonical reusable gate provisioned by setup-access-apps.ps1 — restored after tests.
$allowPolicyName  = 'PCSetup - Owner email allow'
$bypassPolicyName = 'PCSetup - This-PC IP bypass'
$routes = @(
    'console.ffxiv.be',
    'code.ffxiv.be',
    'ttyd.ffxiv.be',
    'tools.ffxiv.be',
    'git.ffxiv.be'
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

# Canonical gate = the two reusable policies provisioned by setup-access-apps.ps1,
# referenced as [bypass (precedence 1), allow (precedence 2)]. Restoring an app
# means simply re-pointing it at these by ID — which is crash-safe: even if a
# previous verifier run died mid-way and left an app on the everyone-bypass,
# re-pointing to canonical fully re-gates it. We never DELETE these shared
# policies (that would strip the gate from every app at once).
function Get-CanonicalPolicyRefs {
    $reusable = @(Get-CloudflareReusablePolicies -RepoRoot $repoRoot -AccountId $accountId)
    $allow  = $reusable | Where-Object { $_.name -eq $allowPolicyName }  | Select-Object -First 1
    $bypass = $reusable | Where-Object { $_.name -eq $bypassPolicyName } | Select-Object -First 1
    if (-not $allow -or -not $bypass) {
        Fail "Canonical reusable policies not found ('$allowPolicyName' / '$bypassPolicyName'). Run setup-access-apps.ps1 first."
    }
    return @(
        @{ id = $bypass.id; precedence = 1 },
        @{ id = $allow.id;  precedence = 2 }
    )
}

function Set-AppPolicyRefs {
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][object[]]$Refs
    )

    $app = Get-CloudflareAccessApp -RepoRoot $repoRoot -AccountId $accountId -AppId $AppId
    $null = Update-CloudflareAccessApp -RepoRoot $repoRoot -AccountId $accountId -App $app -Set @{ policies = @($Refs) }
}

function Restore-CanonicalGate {
    param(
        [Parameter(Mandatory = $true)][object[]]$Apps,
        [Parameter(Mandatory = $true)][object[]]$CanonicalRefs
    )

    foreach ($item in $Apps) {
        Write-Log "Restoring canonical Access gate for $($item.Hostname)"
        Set-AppPolicyRefs -AppId $item.AppId -Refs $CanonicalRefs
    }
}

# Delete any leftover reusable everyone-bypass policies from a crashed prior run.
# Call this only AFTER apps have been re-pointed at the canonical gate, so no app
# still references the temp policy when it is deleted.
function Remove-StaleVerifierPolicies {
    $reusable = @(Get-CloudflareReusablePolicies -RepoRoot $repoRoot -AccountId $accountId)
    foreach ($policy in $reusable) {
        if ([string]$policy.name -like "$policyPrefix*") {
            Write-Log "Removing stale verifier policy: $($policy.name)"
            try {
                Remove-CloudflareReusablePolicy -RepoRoot $repoRoot -AccountId $accountId -PolicyId $policy.id
            } catch {
                Write-Log "WARNING: could not delete stale verifier policy '$($policy.name)': $_"
            }
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

# Canonical gate to restore to (fails fast if setup-access-apps.ps1 never ran).
$canonicalRefs = Get-CanonicalPolicyRefs

# Heal any half-open state left by a crashed prior run, then clear stale temp policies.
Restore-CanonicalGate -Apps $selectedApps -CanonicalRefs $canonicalRefs
Remove-StaleVerifierPolicies

$tempPolicy = $null

try {
    # Turn gating OFF: one temp reusable everyone-bypass, attached to each app.
    $tempName = "$policyPrefix - $([Guid]::NewGuid().ToString('N').Substring(0,8))"
    Write-Log "Creating temporary everyone-bypass policy '$tempName'"
    $tempPolicy = New-CloudflareReusablePolicy -RepoRoot $repoRoot -AccountId $accountId -Name $tempName -Decision 'bypass' -Include @(@{ everyone = @{} })
    $tempRefs = @(@{ id = $tempPolicy.id; precedence = 1 })

    foreach ($item in $selectedApps) {
        Write-Log "Temporarily opening $($item.Hostname) (everyone-bypass) for verification"
        Set-AppPolicyRefs -AppId $item.AppId -Refs $tempRefs
    }

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
    # Turn gating back ON: re-point every app at the canonical reusable gate,
    # THEN delete the temp policy (order matters — nothing references it now).
    try {
        Restore-CanonicalGate -Apps $selectedApps -CanonicalRefs $canonicalRefs
    } catch {
        Write-Log "WARNING: failed to restore Access gate: $_"
        throw
    } finally {
        if ($tempPolicy) {
            try {
                Remove-CloudflareReusablePolicy -RepoRoot $repoRoot -AccountId $accountId -PolicyId $tempPolicy.id
            } catch {
                Write-Log "WARNING: failed to delete temp verifier policy '$($tempPolicy.name)': $_"
            }
        }
    }
}
