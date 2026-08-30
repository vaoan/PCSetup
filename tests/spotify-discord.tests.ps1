#Requires -Modules Pester

<#
    Contract tests for the Spotify -> Discord bridge.

    The bridge itself cannot be executed in a test: it streams a licensed Spotify
    account into a live Discord voice channel from a cloud VPS. So this suite
    asserts the invariants instead - the documentation and self-healing rules
    that a change could silently break.

    Two of these are the "mandatory" enforcement:

      * every top-level function in the library carries a TSDoc block, so the
        tracking cannot rot as functions are added
      * every @failureMode id referenced in code exists in FAILURES.md, and every
        failure the registry claims is auto-healed has a real detector in
        golibrespot-heal.sh - so "we self-heal that" can never be a claim the
        code does not back up

    The rest encode defects that actually shipped. The original watchdog matched
    exactly ONE log string (dealer pong loss) and therefore sat idle through a
    two-week outage in which every play returned HTTP 500; the tests below make
    narrowing it back down a build failure.

    Run:  tests\run-tests.ps1 -Path tests\spotify-discord.tests.ps1
#>

$ErrorActionPreference = 'Stop'

# NOTE: computed at DISCOVERY time, not in BeforeAll. Pester generates It blocks
# while discovering and runs their bodies later, so a variable set in BeforeAll
# does not exist inside a -ForEach expression.
#
# NOTE 2: -ForEach data must be HASHTABLES, not [pscustomobject]. Pester exposes
# hashtable keys as variables inside the test body; a PSCustomObject arrives as
# $_ only, so every property read comes back $null and the tests fail with an
# empty name - which looks like a data bug and is a Pester binding rule.
#
# NOTE 3: each item carries every path its body needs. Script-scope variables
# from discovery are NOT visible inside It bodies.
$DiscoveryRoot = Split-Path -Parent $PSScriptRoot
$DiscoveryBridge = Join-Path $DiscoveryRoot 'spotify-discord'
$DiscoveryHealer = Join-Path $DiscoveryBridge 'cloud\golibrespot-heal.sh'
$DiscoveryRegistry = Join-Path $DiscoveryBridge 'FAILURES.md'
$DiscoveryLibrary = @('bot.js', 'dj.js', 'accounts.js')

# --- collect every top-level declaration that must carry TSDoc ----------------
$DiscoveryDeclarations = @()
foreach ($file in $DiscoveryLibrary) {
    $path = Join-Path $DiscoveryBridge $file
    if (-not (Test-Path $path)) { continue }
    $lines = Get-Content $path
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $name = $null
        if ($line -match '^(?:async\s+)?function\s+([A-Za-z_$][A-Za-z0-9_$]*)') {
            $name = $Matches[1]
        }
        elseif ($line -match '^const\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s*)?\([^)]*\)\s*=>') {
            $name = $Matches[1]
        }
        if (-not $name) { continue }
        $previous = if ($i -gt 0) { $lines[$i - 1].Trim() } else { '' }
        $DiscoveryDeclarations += @{
            File       = $file
            Name       = $name
            Line       = $i + 1
            Documented = ($previous -eq '*/')
        }
    }
}

# --- collect exported names (they are the module's public surface) -----------
$DiscoveryExports = @()
foreach ($file in $DiscoveryLibrary) {
    $path = Join-Path $DiscoveryBridge $file
    if (-not (Test-Path $path)) { continue }
    $text = Get-Content $path -Raw
    if ($text -match 'module\.exports\s*=\s*\{([^}]*)\}') {
        foreach ($raw in $Matches[1] -split ',') {
            $name = $raw.Trim()
            if (-not $name) { continue }
            if ($name -match '^([A-Za-z_$][A-Za-z0-9_$]*)') { $name = $Matches[1] } else { continue }
            $DiscoveryExports += @{ File = $file; Name = $name; Path = $path }
        }
    }
}

# --- failure ids declared by the registry, and which claim to self-heal ------
$DiscoveryRegistryIds = @()
$DiscoveryAutoHealed = @()
if (Test-Path $DiscoveryRegistry) {
    $registryText = Get-Content $DiscoveryRegistry -Raw
    foreach ($m in [regex]::Matches($registryText, '(?m)^##\s+(SD-\d{3})\s*$')) {
        $DiscoveryRegistryIds += $m.Groups[1].Value
    }
    # Table rows look like: | [SD-001](#sd-001) | description | `auto-healed` |
    foreach ($m in [regex]::Matches($registryText, '(?m)^\|\s*\[(SD-\d{3})\][^|]*\|[^|]*\|\s*`auto-healed`\s*\|')) {
        $DiscoveryAutoHealed += $m.Groups[1].Value
    }
}
$DiscoveryRegistryIds = @($DiscoveryRegistryIds | Sort-Object -Unique)
$DiscoveryAutoHealed = @($DiscoveryAutoHealed | Sort-Object -Unique)

# --- failure ids referenced by the code --------------------------------------
$DiscoveryReferencedIds = @()
foreach ($file in $DiscoveryLibrary) {
    $path = Join-Path $DiscoveryBridge $file
    if (-not (Test-Path $path)) { continue }
    foreach ($m in [regex]::Matches((Get-Content $path -Raw), '@failureMode\s+(SD-\d{3})')) {
        $DiscoveryReferencedIds += @{
            File  = $file
            Id    = $m.Groups[1].Value
            Known = ($DiscoveryRegistryIds -join ',')
        }
    }
}
$DiscoveryReferencedIds = @($DiscoveryReferencedIds |
    Sort-Object -Property { "$($_.Id)|$($_.File)" } -Unique)

# --- healer assertions, each carrying its own path ---------------------------
$DiscoveryAutoHealedItems = @($DiscoveryAutoHealed | ForEach-Object {
    @{ Id = $_; Healer = $DiscoveryHealer }
})
$DiscoveryLogStrings = @(
    @{ Text = 'failed authenticating with login5';        Healer = $DiscoveryHealer }
    @{ Text = 'failed renewing login5 access token';      Healer = $DiscoveryHealer }
    @{ Text = 'failed obtaining spclient access token';   Healer = $DiscoveryHealer }
    @{ Text = 'did not receive last pong from dealer';    Healer = $DiscoveryHealer }
)

Describe 'Spotify-Discord bridge: mandatory TSDoc' {

    BeforeAll {
        $script:Bridge = Join-Path (Split-Path -Parent $PSScriptRoot) 'spotify-discord'
    }

    It 'finds the library files to check' {
        foreach ($file in @('bot.js', 'dj.js', 'accounts.js')) {
            Join-Path $script:Bridge $file | Should -Exist
        }
    }

    It 'discovers a plausible number of top-level declarations' -ForEach @(
        @{ Count = $DiscoveryDeclarations.Count }
    ) {
        # Guards the regexes themselves: if a refactor changed the declaration
        # style, this suite would otherwise pass by checking nothing at all.
        $Count | Should -BeGreaterThan 25
    }

    It '<File>: <Name> (line <Line>) has a TSDoc block' -ForEach $DiscoveryDeclarations {
        # Every top-level function in the library is documented. TSDoc must end
        # on the line immediately above the declaration - a comment separated by
        # a blank line does not attach to the symbol in editors or generators.
        $Documented | Should -BeTrue -Because "$File line $Line ($Name) must carry a TSDoc block ending on the line directly above it"
    }

    It '<File>: exported symbol <Name> is documented' -ForEach $DiscoveryExports {
        $text = Get-Content $Path -Raw
        # The export list is not the declaration; find where the symbol is
        # declared and require a TSDoc block immediately above it.
        $pattern = '(?ms)/\*\*.*?\*/\s*(?:const|(?:async\s+)?function)\s+' + [regex]::Escape($Name) + '\b'
        $text | Should -Match $pattern -Because "$Name is part of $File's public surface and must be documented"
    }
}

Describe 'Spotify-Discord bridge: failure registry tracking' {

    BeforeAll {
        $script:Registry = Join-Path (Split-Path -Parent $PSScriptRoot) 'spotify-discord\FAILURES.md'
    }

    It 'has a failure registry' {
        $script:Registry | Should -Exist
    }

    It 'the registry declares failure ids' -ForEach @(
        @{ Count = $DiscoveryRegistryIds.Count }
    ) {
        $Count | Should -BeGreaterThan 5
    }

    It 'the code references at least one failure id' -ForEach @(
        @{ Count = $DiscoveryReferencedIds.Count }
    ) {
        # If this drops to zero the @failureMode convention has been abandoned
        # and every check below would vacuously pass.
        $Count | Should -BeGreaterThan 0
    }

    It '<Id> referenced in <File> exists in FAILURES.md' -ForEach $DiscoveryReferencedIds {
        # A code comment claiming a failure mode the registry never heard of is
        # worse than no comment: it looks like tracking and tracks nothing.
        ($Known -split ',') | Should -Contain $Id -Because "$File references $Id, so FAILURES.md needs a '## $Id' section"
    }

    It 'every registry id has an index row in the summary table' {
        $text = Get-Content $script:Registry -Raw
        $ids = [regex]::Matches($text, '(?m)^##\s+(SD-\d{3})\s*$') | ForEach-Object { $_.Groups[1].Value }
        foreach ($id in $ids) {
            # NOTE: literal Contains, not -BeLike / -Match. The anchor contains
            # [ ] ( ) # - which -BeLike reads as a wildcard character class
            # ("pattern is not valid") and -Match reads as a regex group.
            $anchor = '[' + $id + '](#' + $id.ToLower() + ')'
            $text.Contains($anchor) | Should -BeTrue -Because "$id needs an index row in the summary table linking to its section"
        }
    }

    It 'ids are unique (never renumbered or reused)' {
        $ids = [regex]::Matches((Get-Content $script:Registry -Raw), '(?m)^##\s+(SD-\d{3})\s*$') |
            ForEach-Object { $_.Groups[1].Value }
        (@($ids | Sort-Object -Unique)).Count | Should -Be @($ids).Count
    }
}

Describe 'Spotify-Discord bridge: self-healing watchdog' {

    BeforeAll {
        $script:Healer = Join-Path (Split-Path -Parent $PSScriptRoot) 'spotify-discord\cloud\golibrespot-heal.sh'
    }

    It 'the healer script exists' {
        $script:Healer | Should -Exist
    }

    It 'the healer is LF-only (it runs on Linux)' {
        # A CRLF shell script fails on the VPS with a confusing
        # "bad interpreter: /bin/bash^M".
        $bytes = [System.IO.File]::ReadAllBytes($script:Healer)
        ($bytes -contains 13) | Should -BeFalse -Because 'golibrespot-heal.sh must not contain CR bytes'
    }

    It 'declares an auto-heal for at least the login5 failure' -ForEach @(
        @{ Healed = ($DiscoveryAutoHealed -join ',') }
    ) {
        ($Healed -split ',') | Should -Contain 'SD-001'
    }

    It '<Id> is claimed auto-healed, so the healer must reference it' -ForEach $DiscoveryAutoHealedItems {
        # The registry says this failure is repaired unattended. Prove the healer
        # actually mentions it, so a claim cannot outlive its implementation.
        (Get-Content $Healer -Raw) | Should -BeLike "*$Id*" -Because "FAILURES.md marks $Id auto-healed, so golibrespot-heal.sh must handle it"
    }

    It 'detects the real log string: <Text>' -ForEach $DiscoveryLogStrings {
        # These are the exact strings go-librespot logs. Reworded, the detector
        # silently matches nothing - which is precisely how the original
        # watchdog missed a two-week outage.
        (Get-Content $Healer -Raw) | Should -BeLike "*$Text*"
    }

    It 'verifies an upgrade by the login5 marker, not merely that the process is up' {
        # A restarted process that still cannot authenticate is not a fixed one.
        (Get-Content $script:Healer -Raw) | Should -BeLike '*authenticated Login5*'
    }

    It 'rolls back a failed upgrade' {
        $healer = Get-Content $script:Healer -Raw
        $healer | Should -BeLike '*prev.bak*'
        $healer | Should -Match 'rolling back|rollback'
    }

    It 'backs up the Spotify credentials before upgrading' {
        # Losing state.json means redoing the interactive OAuth tunnel by hand.
        (Get-Content $script:Healer -Raw) | Should -BeLike '*state.json.bak*'
    }

    It 'never acts while audio is playing' {
        # The safety contract that makes a 2-minute timer acceptable.
        $healer = Get-Content $script:Healer -Raw
        $healer | Should -Match 'playback_active'
        $healer | Should -BeLike '*playback active - no action taken*'
    }

    It 'samples instantaneous CPU rather than the lifetime average' {
        # ps -o pcpu reports the average since process start: it misses a new
        # spin and slanders a freshly restarted process.
        (Get-Content $script:Healer -Raw) | Should -BeLike '*/proc/$pid/stat*'
    }

    It 'ignores errors logged before the last restart' {
        # Without this window the healer re-reads the same historical errors
        # every 2 minutes and escalates to an upgrade forever.
        (Get-Content $script:Healer -Raw) | Should -Match 'error_since'
    }

    It 'rate-limits restarts and upgrades' {
        $healer = Get-Content $script:Healer -Raw
        $healer | Should -Match 'MIN_SECONDS_BETWEEN_RESTARTS'
        $healer | Should -Match 'MIN_SECONDS_BETWEEN_UPGRADES'
    }

    It 'serializes concurrent runs' {
        # An upgrade outlasts the 2-minute timer interval. Overlapping runs were
        # observed interleaving during the rollback test, and a second run could
        # restart the service inside the first run's verification window.
        (Get-Content $script:Healer -Raw) | Should -Match 'flock'
    }

    It 'does not double-append the curl failure code' {
        # `curl -w %{http_code} || echo 000` yields "000000", not "000".
        (Get-Content $script:Healer -Raw) | Should -Not -Match "http_code\}' `"\`$API/status`" 2>/dev/null \|\| echo 000"
    }
}

Describe 'Spotify-Discord bridge: installer wiring' {

    BeforeAll {
        $script:SetupCloud = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'spotify-discord\cloud\setup-cloud.sh') -Raw
    }

    It 'installs the healer on a rebuilt box' {
        $script:SetupCloud | Should -BeLike '*golibrespot-heal.sh*'
    }

    It 'points the watchdog unit at the healer' {
        $script:SetupCloud | Should -BeLike '*ExecStart=/usr/local/bin/golibrespot-heal.sh*'
    }

    It 'does not resurrect the old single-string watchdog' {
        # The original watchdog only ever matched dealer pong losses and missed
        # a two-week outage. Re-adding it as the timer target would be a
        # regression that looks like a cleanup.
        $script:SetupCloud | Should -Not -Match 'ExecStart=/usr/local/bin/golibrespot-watchdog\.sh'
    }

    It 'keeps needrestart from bouncing services mid-stream (SD-008)' {
        $script:SetupCloud | Should -BeLike '*nrconf*'
    }
}

Describe 'Spotify-Discord bridge: deployment truth' {

    BeforeAll {
        $script:Bridge = Join-Path (Split-Path -Parent $PSScriptRoot) 'spotify-discord'
    }

    It 'the folder CLAUDE.md exists and says where the bridge actually runs' {
        $claude = Join-Path $script:Bridge 'CLAUDE.md'
        $claude | Should -Exist
        # SD-012: the root CLAUDE.md still describes the retired local WSL
        # deployment. This file is what stops the next investigation starting on
        # the wrong machine.
        (Get-Content $claude -Raw) | Should -Match 'does not run on this PC|RackNerd|cloud VPS'
    }

    It 'pins @discordjs/voice >= 0.19 for voice gateway v8 (SD-006)' {
        $pkg = Get-Content (Join-Path $script:Bridge 'package.json') -Raw | ConvertFrom-Json
        $version = $pkg.dependencies.'@discordjs/voice'
        $version | Should -Not -BeNullOrEmpty
        [version]($version -replace '[^0-9.]', '') | Should -BeGreaterOrEqual ([version]'0.19.0')
    }
}
