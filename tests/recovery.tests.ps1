#Requires -Modules Pester

<#
    Contract tests for the post-format recovery / console-provisioning scripts.

    These scripts cannot be executed in a test: they create Cloudflare tunnels and
    DNS records, register scheduled tasks and install MSIs. So instead of running
    them, this suite asserts the invariants that were actually violated in
    practice. Every check here corresponds to a real defect that shipped:

      * a tunnel name referenced by recovery that did not exist ("dev-tunnel"
        vs the real "dev-console") - silently skipped provisioning for months
      * the web origin port disagreeing across four files (7542 vs 9000)
      * $webHostname holding "www.ffxiv.be" while the template composed
        "www.$webHostname" - would have provisioned www.www.ffxiv.be
      * files deployed to a copy directory but not covered by the drift check,
        so a stale copy served old content indefinitely
      * references to scripts that had been deleted
      * a stale hostname in Dockerfile.test, missed because a sweep filtered on
        file extension and Dockerfile.test has none

    Run:  tests\run-tests.ps1 -Path tests\recovery.tests.ps1
#>

$ErrorActionPreference = 'Stop'

# NOTE: evaluated at DISCOVERY time, not inside BeforeAll. Pester resolves -Skip:
# while discovering tests, before BeforeAll has run, so a flag set in BeforeAll is
# still $null and every gated test silently skips - which is worse than failing,
# because the run still looks green.
$DiscoveryRepoRoot = Split-Path -Parent $PSScriptRoot
$DiscoveryToken = $null
$DiscoverySecrets = Join-Path $DiscoveryRepoRoot '.secrets'
if (Test-Path $DiscoverySecrets) {
    $line = Get-Content $DiscoverySecrets | Where-Object { $_ -match '^\s*CLOUDFLARE_ACCOUNT_API_TOKEN\s*=' } | Select-Object -First 1
    if ($line) {
        $v = ($line -replace '^\s*CLOUDFLARE_ACCOUNT_API_TOKEN\s*=\s*', '' -replace '["'']', '').Trim()
        if ($v -and $v -ne 'replace_me') { $DiscoveryToken = $v }
    }
}
$HasCfToken = [bool]$DiscoveryToken
$HasBash    = [bool](Get-Command bash -ErrorAction SilentlyContinue)

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CfDir    = Join-Path $RepoRoot 'cloudflared'

    # The domain being retired. Prose may mention it; executable lines must not.
    $script:RetiredDomain = 'ffxivbe.org'
    $script:LiveZone      = 'ffxiv.be'

    function Get-CfFile { param([string]$Name) Join-Path $script:CfDir $Name }

    function Get-ScriptText {
        param([string]$Name)
        Get-Content (Get-CfFile $Name) -Raw
    }

    # Lines that are not comments - i.e. things that actually execute.
    function Get-CodeLines {
        param([string]$Path)
        Get-Content $Path | Where-Object {
            $t = $_.Trim()
            $t -and -not $t.StartsWith('#') -and -not $t.StartsWith('<#') -and -not $t.StartsWith('>')
        }
    }

    function Get-CloudflareToken {
        $secrets = Join-Path $script:RepoRoot '.secrets'
        if (-not (Test-Path $secrets)) { return $null }
        $line = Get-Content $secrets | Where-Object { $_ -match '^\s*CLOUDFLARE_ACCOUNT_API_TOKEN\s*=' } | Select-Object -First 1
        if (-not $line) { return $null }
        $v = ($line -replace '^\s*CLOUDFLARE_ACCOUNT_API_TOKEN\s*=\s*', '' -replace '["'']', '').Trim()
        if (-not $v -or $v -eq 'replace_me') { return $null }
        return $v
    }

    function Invoke-Cf {
        param([string]$Path)
        $tok = Get-CloudflareToken
        Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4$Path" -Headers @{ Authorization = "Bearer $tok" }
    }

    $script:HasCfToken = [bool](Get-CloudflareToken)
    $script:AccountId  = 'd34896e6a0f8b2fba5e03dec659eac50'
}

Describe 'Recovery scripts - syntax' {

    It 'every PowerShell script in cloudflared/ parses' {
        $failures = @()
        foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '..\cloudflared') -Filter *.ps1) {
            $errs = $null; $tokens = $null
            [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs) | Out-Null
            if ($errs) { $failures += "$($f.Name): line $($errs[0].Extent.StartLineNumber) $($errs[0].Message)" }
        }
        $failures | Should -BeNullOrEmpty
    }

    It 'every shell script in cloudflared/ parses' -Skip:(-not $HasBash) {
        # Pipe the script in on stdin. Passing a Windows path to bash lets MSYS
        # rewrite it (Z:\... becomes C:/Program Files/Git/...), so the check
        # would read a nonexistent file and report a false result either way.
        $failures = @()
        foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '..\cloudflared') -Filter *.sh) {
            Get-Content $f.FullName -Raw | & bash -n 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $failures += $f.Name }
        }
        $failures | Should -BeNullOrEmpty
    }
}

Describe 'Recovery scripts - no dangling references' {

    It 'every cloudflared script referenced by another script exists' {
        # Catches deletions that leave callers pointing at nothing.
        $present = (Get-ChildItem $script:CfDir -File | ForEach-Object { $_.Name })
        $missing = @()
        foreach ($f in Get-ChildItem $script:CfDir -Include *.ps1, *.sh, *.bat -File) {
            $text = Get-Content $f.FullName -Raw
            foreach ($m in [regex]::Matches($text, '(?<![\w./\\-])([a-z0-9][a-z0-9-]*\.(?:ps1|sh))(?![\w-])')) {
                $name = $m.Groups[1].Value
                if ($name -eq $f.Name) { continue }
                if ($present -notcontains $name) { $missing += "$($f.Name) -> $name" }
            }
        }
        $missing | Should -BeNullOrEmpty
    }

    It 'no executable line still targets the retired domain' {
        # Prose/comments may explain the migration; code must not depend on it.
        # Deliberately includes extensionless files - a previous sweep filtered on
        # extension and missed Dockerfile.test.
        $offenders = @()
        $files = Get-ChildItem $script:RepoRoot -Recurse -File |
            Where-Object {
                $_.FullName -notmatch '\\\.git\\|\\node_modules\\|\\docs\\superpowers\\|\\tests\\|latest-chat|rebrandly-links-export' -and
                ($_.Extension -in '.ps1', '.sh', '.bat', '.cmd', '.js', '.mjs', '.yml', '.yaml', '.toml', '.json' -or
                 $_.Name -like 'Dockerfile*')
            }
        foreach ($f in $files) {
            foreach ($line in (Get-CodeLines $f.FullName)) {
                if ($line -match [regex]::Escape($script:RetiredDomain)) {
                    $offenders += "$($f.Name): $($line.Trim())"
                }
            }
        }
        $offenders | Should -BeNullOrEmpty
    }
}

Describe 'Recovery scripts - configuration agreement' {

    It 'the web origin port is identical everywhere it is declared' {
        # Was 7542 in the repo config and CLAUDE.md, 9000 in install-tunnel.ps1
        # and the live config. Nothing listened on either, so it went unnoticed.
        $ports = @{}
        $repoCfg = Get-Content (Join-Path $script:CfDir '.cloudflared\config.yml') -Raw
        if ($repoCfg -match 'www\.[^\s]+\s*\r?\n\s*service:\s*http://127\.0\.0\.1:(\d+)') { $ports['repo config.yml'] = $Matches[1] }

        $install = Get-ScriptText 'install-tunnel.ps1'
        if ($install -match 'hostname:\s*www\.[^\s]+\s*\r?\n\s*service:\s*http://127\.0\.0\.1:(\d+)') { $ports['install-tunnel.ps1'] = $Matches[1] }

        $recovery = Get-ScriptText 'post-format-recovery.ps1'
        if ($recovery -match 'hostname:\s*www\.\$webHostname\s*\r?\n\s*service:\s*http://127\.0\.0\.1:(\d+)') { $ports['post-format-recovery.ps1'] = $Matches[1] }

        $ports.Count | Should -BeGreaterThan 1 -Because 'the port should be declared in more than one place for this test to mean anything'
        ($ports.Values | Select-Object -Unique).Count | Should -Be 1 -Because "ports disagree: $($ports.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })"
    }

    It 'the console hostname list matches between provisioning and Access gating' {
        $setup  = Get-ScriptText 'setup-console-windows.ps1'
        $access = Get-ScriptText 'setup-access-apps.ps1'

        $setupHosts = [regex]::Matches($setup, "'([a-z0-9-]+\.$([regex]::Escape($script:LiveZone)))'") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $accessHosts = [regex]::Matches($access, "'([a-z0-9-]+\.$([regex]::Escape($script:LiveZone)))'\s*=") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

        $setupHosts.Count | Should -BeGreaterThan 0
        # Every hostname the tunnel serves must be gated, or it is public.
        $ungated = $setupHosts | Where-Object { $accessHosts -notcontains $_ }
        $ungated | Should -BeNullOrEmpty -Because 'a tunnelled hostname with no Access app is exposed to the internet'
    }

    It 'hostname variables are zone roots, so subdomain composition cannot double up' {
        # $webHostname was briefly "www.ffxiv.be" while the template composed
        # "www.$webHostname" -> www.www.ffxiv.be.
        $recovery = Get-ScriptText 'post-format-recovery.ps1'
        if ($recovery -match '(?m)^\$webHostname\s*=\s*"([^"]+)"') {
            $value = $Matches[1]
            $composed = [regex]::Matches($recovery, '(?:www|chat|map)\.\$webHostname').Count
            if ($composed -gt 0) {
                $value | Should -Not -Match '^(www|chat|map)\.' -Because "`$webHostname is composed as e.g. www.`$webHostname, so it must be a zone root, not '$value'"
            }
        }
    }
}

Describe 'Recovery scripts - deployed copies are drift-checked' {

    It 'every file copied into the launcher dir is covered by the verifier' {
        # console-proxy.js serves the PWA assets from its own directory. A copy
        # that setup deploys but the verifier does not check can serve stale
        # content indefinitely - which is exactly what happened with the icons.
        $setup  = Get-ScriptText 'setup-console-windows.ps1'
        $verify = Get-ScriptText 'verify-console.ps1'

        $copied = [regex]::Matches($setup, 'Copy-Item\s+"\$PSScriptRoot\\([^"]+)"\s+"\$launcherDir') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

        $copied.Count | Should -BeGreaterThan 0
        $unchecked = $copied | Where-Object { $verify -notmatch [regex]::Escape($_) }
        $unchecked | Should -BeNullOrEmpty -Because 'these are deployed but never compared against the repo'
    }

    It 'the WSL node proxies are redeployed by start-console and drift-checked' {
        $start  = Get-ScriptText 'start-console.ps1'
        $verify = Get-ScriptText 'verify-console.ps1'
        foreach ($proxy in 'dashboard.js', 'git-proxy.js', 'ttyd-proxy.js') {
            $start  | Should -Match ([regex]::Escape($proxy)) -Because 'start-console.ps1 must refresh the /usr/local/bin copy'
            $verify | Should -Match ([regex]::Escape($proxy)) -Because 'verify-console.ps1 must detect drift in the deployed copy'
        }
    }
}

Describe 'Recovery scripts - live Cloudflare contract' -Skip:(-not $HasCfToken) {

    It 'every tunnel name referenced by a script exists in the account' {
        # "dev-tunnel" was referenced for months and never existed.
        $live = (Invoke-Cf "/accounts/$($script:AccountId)/cfd_tunnel?is_deleted=false").result |
            ForEach-Object { $_.name }

        $referenced = @()
        foreach ($f in Get-ChildItem $script:CfDir -Filter *.ps1) {
            $text = Get-Content $f.FullName -Raw
            foreach ($m in [regex]::Matches($text, '(?m)^\s*\$\w*[Tt]unnelName\s*=\s*[''"]([^''"]+)[''"]')) {
                $referenced += [pscustomobject]@{ File = $f.Name; Name = $m.Groups[1].Value }
            }
        }

        $referenced.Count | Should -BeGreaterThan 0
        $bogus = $referenced | Where-Object { $live -notcontains $_.Name } |
            ForEach-Object { "$($_.File) references tunnel '$($_.Name)'" }
        $bogus | Should -BeNullOrEmpty -Because "live tunnels are: $($live -join ', ')"
    }

    It 'every console hostname has a DNS record in the live zone' {
        $zoneId = ((Invoke-Cf "/zones?name=$($script:LiveZone)").result | Select-Object -First 1).id
        $zoneId | Should -Not -BeNullOrEmpty

        $records = (Invoke-Cf "/zones/$zoneId/dns_records?per_page=100").result | ForEach-Object { $_.name }

        $setup = Get-ScriptText 'setup-console-windows.ps1'
        $hosts = [regex]::Matches($setup, "'([a-z0-9-]+\.$([regex]::Escape($script:LiveZone)))'") |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique

        $hosts.Count | Should -BeGreaterThan 0
        $missing = $hosts | Where-Object { $records -notcontains $_ }
        $missing | Should -BeNullOrEmpty -Because 'a hostname in the ingress list with no DNS record will never resolve'
    }
}
