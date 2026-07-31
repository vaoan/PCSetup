# Provisions Cloudflare Zero Trust Access gating for every web-console hostname.
#
# The whole point: on a fresh Windows install the tunnel + DNS get recreated,
# but nothing recreates the Access *applications* — so the hostnames would route
# through the tunnel with NO Access app in front of them (i.e. fully public)
# until someone rebuilt them by hand in the dashboard. This script makes the
# gating reproducible and idempotent.
#
# Model: two REUSABLE (account-level) Zero Trust policies, defined once and
# attached to all apps by ID, instead of duplicating inline policies per app:
#   1. "PCSetup - Owner email allow"  (allow)  -> requires Access login as $Email
#   2. "PCSetup - This-PC IP bypass"  (bypass) -> this PC's public IPs skip login
# Each app references [bypass (precedence 1), allow (precedence 2)] and gets the
# max session duration so remote logins are rare ("protected but not annoying").
#
# Running this against an account that still has the old per-app inline policies
# migrates them: the app is re-pointed at the reusable policies and the orphaned
# inline copies are detached (Cloudflare deletes detached non-reusable policies).
#
# Requires CLOUDFLARE_ACCOUNT_API_TOKEN in .secrets (Access: Apps and Policies -> Edit).

[CmdletBinding()]
param(
    [string]$AccountId       = 'd34896e6a0f8b2fba5e03dec659eac50',
    [string[]]$Emails        = @('heinerangarita@gmail.com', 'pagose876@hotmail.com'),  # every address allowed to log in
    [string]$SessionDuration = '8760h',   # 1 year — Cloudflare accepts this; effective re-auth = min(app, org global)
    [switch]$SkipIpRefresh                 # keep the existing bypass IPs instead of re-detecting this PC's public IP
)

# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -AccountId `"$AccountId`" -Emails `"$($Emails -join ',')`" -SessionDuration `"$SessionDuration`""
    if ($SkipIpRefresh) { $argList += ' -SkipIpRefresh' }
    Start-Process PowerShell -ArgumentList $argList -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot 'shared-cloudflare-auth.ps1')

function Write-Log { param([string]$msg) Write-Host "[setup-access-apps] $msg" }

$allowPolicyName  = 'PCSetup - Owner email allow'
$bypassPolicyName = 'PCSetup - This-PC IP bypass'

# Hostname -> Access app display name. Order matters only for readable logging.
$hostApps = [ordered]@{
    'console.ffxiv.be' = 'Console (console.ffxiv.be)'
    'dev.ffxiv.be'     = 'Dev SSH (dev.ffxiv.be)'
    'code.ffxiv.be'    = 'Code Server (code.ffxiv.be)'
    'ttyd.ffxiv.be'    = 'Terminal (ttyd.ffxiv.be)'
    'tools.ffxiv.be'   = 'Dev Tools (tools.ffxiv.be)'
    'git.ffxiv.be'     = 'Git (git.ffxiv.be)'
}

# -- 1. Reusable "allow owner email" policy -----------------------------------
$emailList    = @($Emails | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
if (-not $emailList) { throw "No emails supplied for the allow policy." }
$reusable     = @(Get-CloudflareReusablePolicies -RepoRoot $repoRoot -AccountId $AccountId)
$allowInclude = @($emailList | ForEach-Object { @{ email = @{ email = $_ } } })
$allow = $reusable | Where-Object { $_.name -eq $allowPolicyName } | Select-Object -First 1
if (-not $allow) {
    Write-Log "Creating reusable policy '$allowPolicyName' (allow $($emailList -join ', '))"
    $allow = New-CloudflareReusablePolicy -RepoRoot $repoRoot -AccountId $AccountId -Name $allowPolicyName -Decision 'allow' -Include $allowInclude
} else {
    Write-Log "Reusable policy '$allowPolicyName' exists; ensuring it allows $($emailList -join ', ')"
    $allow = Set-CloudflareReusablePolicyInclude -RepoRoot $repoRoot -AccountId $AccountId -PolicyId $allow.id -Name $allowPolicyName -Decision 'allow' -Include $allowInclude
}

# -- 2. Reusable "this-PC IP bypass" policy -----------------------------------
$bypass = $reusable | Where-Object { $_.name -eq $bypassPolicyName } | Select-Object -First 1

$cidrs = @()
if ($SkipIpRefresh -and $bypass) {
    $cidrs = @($bypass.include | ForEach-Object { $_.ip.ip } | Where-Object { $_ })
    Write-Log "Keeping existing bypass CIDRs: $($cidrs -join ', ')"
} else {
    try {
        $cidrs = @(Get-CloudflareCurrentPublicIpCidrs)
        Write-Log "Detected this PC's public IP CIDRs: $($cidrs -join ', ')"
    } catch {
        if ($bypass) {
            $cidrs = @($bypass.include | ForEach-Object { $_.ip.ip } | Where-Object { $_ })
            Write-Log "WARNING: could not detect public IP; keeping existing CIDRs: $($cidrs -join ', ')"
        } else {
            throw "Could not detect this PC's public IP and no existing bypass policy to fall back to: $_"
        }
    }
}

$bypassInclude = @($cidrs | Select-Object -Unique | ForEach-Object { @{ ip = @{ ip = $_ } } })
if (-not $bypassInclude) {
    throw "No IP CIDRs resolved for the bypass policy."
}

if (-not $bypass) {
    Write-Log "Creating reusable policy '$bypassPolicyName' (bypass $($cidrs.Count) CIDR(s))"
    $bypass = New-CloudflareReusablePolicy -RepoRoot $repoRoot -AccountId $AccountId -Name $bypassPolicyName -Decision 'bypass' -Include $bypassInclude
} else {
    Write-Log "Reusable policy '$bypassPolicyName' exists; ensuring CIDRs are current"
    $bypass = Set-CloudflareReusablePolicyInclude -RepoRoot $repoRoot -AccountId $AccountId -PolicyId $bypass.id -Name $bypassPolicyName -Decision 'bypass' -Include $bypassInclude
}

$policyRefs = @(
    @{ id = $bypass.id; precedence = 1 },
    @{ id = $allow.id;  precedence = 2 }
)

# -- 3. Ensure every app exists and references the reusable policies ----------
$apps = @(Get-CloudflareAccessApps -RepoRoot $repoRoot -AccountId $AccountId)
foreach ($hostname in $hostApps.Keys) {
    $appName = $hostApps[$hostname]
    $app = $apps | Where-Object { ($_.domain -eq $hostname) -or ($_.self_hosted_domains -contains $hostname) } | Select-Object -First 1

    if (-not $app) {
        Write-Log "Creating Access app '$appName' -> reusable gate, session $SessionDuration"
        $body = @{
            name                       = $appName
            domain                     = $hostname
            type                       = 'self_hosted'
            self_hosted_domains        = @($hostname)
            destinations               = @(@{ type = 'public'; uri = $hostname })
            session_duration           = $SessionDuration
            app_launcher_visible       = $true
            allowed_idps               = @()
            auto_redirect_to_identity  = $false
            http_only_cookie_attribute = $true
            policies                   = $policyRefs
        }
        $null = Invoke-CloudflareApi -RepoRoot $repoRoot -Method POST -Path "/accounts/$AccountId/access/apps" -Body $body
    } else {
        Write-Log "Updating Access app '$($app.name)' -> reusable gate, session $SessionDuration"
        $null = Update-CloudflareAccessApp -RepoRoot $repoRoot -AccountId $AccountId -App $app -Set @{
            session_duration = $SessionDuration
            policies         = $policyRefs
        }
    }
}

# -- 4. Org-global session timeout (best-effort fallback) ---------------------
# App-level session_duration OVERRIDES the org global per app, so the 8760h set
# on each app above is authoritative for our hostnames regardless of this. We
# still push the global as a fallback for any future app that doesn't set its
# own. Note: Cloudflare's org endpoint accepts the PUT but does not echo
# auth_session_duration back in GET, so we don't assert on the response.
Write-Log "Pushing org-global auth_session_duration = $SessionDuration (best-effort fallback; app-level governs)"
try {
    $org = Invoke-CloudflareApi -RepoRoot $repoRoot -Method GET -Path "/accounts/$AccountId/access/organizations"
    $null = Invoke-CloudflareApi -RepoRoot $repoRoot -Method PUT -Path "/accounts/$AccountId/access/organizations" -Body @{
        name                  = $org.name
        auth_domain           = $org.auth_domain
        auth_session_duration = $SessionDuration
    }
} catch {
    Write-Log "WARNING: could not push org-global session timeout: $_"
}

Write-Host ""
Write-Log "Done. $($hostApps.Count) app(s) gated by reusable policies '$allowPolicyName' + '$bypassPolicyName' at $SessionDuration."
