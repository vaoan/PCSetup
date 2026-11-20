# Restores the FFXIV profiles from the private GitHub backups after a format.
#
# Destinations are the ones the repos' own clone scripts use (Profiles\Me\shallow-clone*.bat,
# XIVProfiles env.example PROFILES_DIR=../Profiles, Me\Launcher.bat --roamingPath):
#   vaoan/Profiles     -> <Documents>\Juegos\FFXIV\Profiles
#   vaoan/XIVLauncher  -> <Documents>\Juegos\FFXIV\Profiles\Me\XIVLauncher   (Me's roaming path)
#   vaoan/XIVProfiles  -> <Documents>\Juegos\FFXIV\XIVProfiles                (profile manager)
#   vaoan/FFXIVConfig  -> <Documents>\My Games\FINAL FANTASY XIV - A Realm Reborn
#   vaoan/MINION       -> C:\MINION
#   vaoan/ffxiv-secrets -> <Documents>\Juegos\FFXIV\Secrets                   (keys + plugin repo list)
#
# Then the plugin repositories (phase "plugins"): Secrets\sync-secrets.mjs rebuilds Juegos\FFXIV\.secrets
# (the per-account keys) from that repo's GitHub secrets, Secrets\repos.json (private, so no account or
# repo names live in this public repo) lists each repo, its folder under Juegos\FFXIV (Plugins\<repo>)
# and its key ("None" = public reference repo); each is cloned with that key and tied to it with
# Secrets\Set-RepoKey.ps1. Every Juegos\FFXIV path in Me's dalamudConfig.json (dev plugin paths and the
# settings keyed by them) and in ForkWatch.json is re-pointed at this account's Documents, and missing
# dev plugin DLLs are filled from the prebuilt Juegos\FFXIV\[Plugins\]<repo>\plugins\<Name>\latest.zip.
#
# Never deletes: a destination that is already a clone of the repo is fast-forwarded (or resumed
# when an earlier clone was interrupted), an empty or missing one is cloned, and a non-empty folder
# that is not that clone is MOVED aside to "<dest>.before-restore-<stamp>" first.
#
# GH_TOKEN comes from secrets.txt / .secrets and is NEVER printed or logged: it lives only in this
# process' environment and reaches git through an inline credential helper, so it is not on any
# command line, in the remote URL or in the clones' .git/config.
param(
    [string]$SecretsFile = '',
    [string[]]$Only = @(),
    # Step 12 of the online run: a machine without secrets.txt has nothing to restore - skip, not fail.
    [switch]$SkipWhenNoToken
)

if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'start-log.ps1')) { . (Join-Path $PSScriptRoot 'start-log.ps1') }
$ErrorActionPreference = 'Continue'

$docs = [Environment]::GetFolderPath('MyDocuments')
$ffxiv = Join-Path $docs 'Juegos\FFXIV'
# The profile launchers (<profile>.lnk, made by Profiles\New-ProfileShortcut.ps1) run
# cmd /c "%PCSETUP_DOCUMENTS%\Juegos\FFXIV\Profiles\<name>\Launcher.bat": no account name in them.
if ([Environment]::GetEnvironmentVariable('PCSETUP_DOCUMENTS', 'User') -ne $docs.TrimEnd('\')) {
    [Environment]::SetEnvironmentVariable('PCSETUP_DOCUMENTS', $docs.TrimEnd('\'), 'User')
}
$repos = @(
    @{ Name = 'Profiles';    Branch = 'main';   Dest = (Join-Path $ffxiv 'Profiles') },
    @{ Name = 'XIVLauncher'; Branch = 'master'; Dest = (Join-Path $ffxiv 'Profiles\Me\XIVLauncher') },
    @{ Name = 'XIVProfiles'; Branch = 'main';   Dest = (Join-Path $ffxiv 'XIVProfiles') },
    @{ Name = 'FFXIVConfig'; Branch = 'main';   Dest = (Join-Path $docs 'My Games\FINAL FANTASY XIV - A Realm Reborn') },
    @{ Name = 'MINION';      Branch = 'master'; Dest = 'C:\MINION' },
    @{ Name = 'ffxiv-secrets'; Branch = 'main'; Dest = (Join-Path $ffxiv 'Secrets') }
)
$doPlugins = ($Only.Count -eq 0) -or ($Only -contains 'plugins')
if ($Only.Count -gt 0) { $repos = @($repos | Where-Object { $Only -contains $_.Name }) }

function Get-GhToken {
    $candidates = @()
    if ($SecretsFile) { $candidates += $SecretsFile }
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Root) { $candidates += (Join-Path $drive 'secrets.txt') }
    $candidates += (Join-Path (Split-Path -Parent $PSScriptRoot) '.secrets')
    $candidates += 'Z:\Github\aeleos\.secrets'
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $line = Get-Content -LiteralPath $c -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*GH_TOKEN\s*=' } | Select-Object -First 1
        if ($line) {
            $value = ($line -replace '^\s*GH_TOKEN\s*=\s*', '').Trim().Trim('"')
            if ($value) { Write-Host "GH_TOKEN read from $c (value not shown)"; return $value }
        }
    }
    return $null
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Host 'git is not installed.' -ForegroundColor Red; exit 1 }
$token = Get-GhToken
if (-not $token) {
    if ($SkipWhenNoToken) { Write-Host 'SKIP: no GH_TOKEN in any <drive>:\secrets.txt / .secrets - FFXIV profiles not restored.' -ForegroundColor Yellow; exit 0 }
    Write-Host 'No GH_TOKEN found in any secrets.txt / .secrets - cannot reach the private repos.' -ForegroundColor Red; exit 1
}
$env:GH_TOKEN = $token
Remove-Variable token
# The helper body runs in Git for Windows' sh; $GH_TOKEN is expanded there, not here.
$helper = 'credential.helper=!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f'

function Invoke-Git {
    param([string[]]$GitArgs)
    # HTTP/1.1: over HTTP/2 the XIVLauncher clone crawled at 6-13 KiB/s while the same clone with
    # HTTP/1.1 ran at ~9 MiB/s and plain GitHub downloads at ~25 MB/s (measured 2026-11-19).
    & git -c credential.helper= -c $helper -c core.longpaths=true -c http.version=HTTP/1.1 @GitArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    return $LASTEXITCODE
}

function Restore-PluginRepos {
    $secretsDir = Join-Path $ffxiv 'Secrets'
    $sync = Join-Path $secretsDir 'sync-secrets.mjs'
    $manifest = Join-Path $secretsDir 'repos.json'
    $keysFile = Join-Path $ffxiv '.secrets'
    Write-Host ""
    Write-Host "== plugin repositories (Secrets\repos.json)" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $sync) -or -not (Test-Path -LiteralPath $manifest)) {
        Write-Host "  FAILED: $secretsDir has no sync-secrets.mjs / repos.json" -ForegroundColor Red; $null = $failures.Add('plugins'); return
    }
    # node and gh come from steps 2-3 of this same run; this process started with the old PATH.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if ((Get-Command node -ErrorAction SilentlyContinue) -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        # GH_TOKEN (this run's own-account key) is what sync-secrets.mjs authenticates gh with.
        & node $sync 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -ne 0) { Write-Host "  key sync failed (exit $LASTEXITCODE); using the existing .secrets if any" -ForegroundColor Yellow }
    }
    else { Write-Host '  node or gh missing; using the existing .secrets if any' -ForegroundColor Yellow }
    $keys = @{}
    if (Test-Path -LiteralPath $keysFile) {
        foreach ($l in Get-Content -LiteralPath $keysFile) { if ($l -match '^\s*([A-Z0-9_]+)\s*=\s*(.+?)\s*$') { $keys[$Matches[1]] = $Matches[2] } }
    }
    $setRepoKey = Join-Path $secretsDir 'Set-RepoKey.ps1'
    foreach ($e in (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json)) {
        $dest = Join-Path $ffxiv $e.folder
        Write-Host "  -- $($e.folder)"
        # key "None": a public reference repo (read by a plugin, never pushed): no token, no Set-RepoKey.
        $public = ([string]$e.key -eq 'None')
        if ($public) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
        else {
            $keyName = 'GH_TOKEN_' + ([string]$e.key).ToUpperInvariant()
            if (-not $keys[$keyName]) { Write-Host "    FAILED: $keyName is not in $keysFile" -ForegroundColor Red; $null = $failures.Add($e.folder); continue }
            $env:GH_TOKEN = $keys[$keyName]
        }
        $isClone = $false
        if (Test-Path -LiteralPath (Join-Path $dest '.git')) {
            $origin = (& git -C $dest remote get-url origin 2>$null)
            $isClone = ($origin -and ($origin -replace '\.git$', '') -ieq ($e.url -replace '\.git$', ''))
        }
        if ($isClone) {
            # Full clones (these are worked on): a fast-forward only, local work is never touched.
            $code = Invoke-Git @('-C', $dest, 'pull', '--ff-only')
            if ($code -ne 0) { Write-Host "    pull failed (exit $code); the existing copy is kept as is" -ForegroundColor Yellow }
        }
        else {
            if ((Test-Path -LiteralPath $dest) -and (Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                $aside = "$dest.before-restore-$(Get-Date -Format yyyyMMdd-HHmmss)"
                try { Move-Item -LiteralPath $dest -Destination $aside -ErrorAction Stop; Write-Host "    moved the existing folder to $aside (nothing deleted)" -ForegroundColor Yellow }
                catch { Write-Host "    FAILED: could not move $dest aside: $($_.Exception.Message)" -ForegroundColor Red; $null = $failures.Add($e.folder); continue }
            }
            $parent = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
            $cloneArgs = @('clone', '--progress', '--config', 'core.longpaths=true')
            if ($e.branch) { $cloneArgs += @('--branch', [string]$e.branch) }
            $code = Invoke-Git ($cloneArgs + @($e.url, $dest))
            if ($code -ne 0) { Write-Host "    FAILED: clone exit $code" -ForegroundColor Red; $null = $failures.Add($e.folder); continue }
        }
        if ($public) { Write-Host '    OK (public, no key)' -ForegroundColor Green; continue }
        # Pushes from this clone then use the same key; its output names the account, so it stays out of the log.
        if (Test-Path -LiteralPath $setRepoKey) {
            try { & $setRepoKey -Repo $dest -Key $e.key *> $null; Write-Host "    OK, tied to key $($e.key)" -ForegroundColor Green }
            catch { Write-Host "    cloned, but Set-RepoKey failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }
    Remove-Variable keys
    Restore-DevPluginDlls
}

function Restore-DevPluginDlls {
    $cfgPath = Join-Path $ffxiv 'Profiles\Me\XIVLauncher\dalamudConfig.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return }
    Write-Host ""
    Write-Host "== Dalamud dev plugins" -ForegroundColor Cyan
    $jsonFfxiv = $ffxiv.TrimEnd('\').Replace('\', '\\') + '\\'
    # A hashtable, so the regex callbacks (their own scope) can count into it.
    $count = @{ Placed = 0; Repointed = 0 }
    # 1) Every JSON string under an old Documents' Juegos\FFXIV, in the dev plugin paths, the per-plugin
    #    settings keyed by DLL path (DevPluginSettings) and ForkWatch's RepoPath values, now points here.
    foreach ($file in @($cfgPath, (Join-Path $ffxiv 'Profiles\Me\XIVLauncher\pluginConfigs\ForkWatch.json'))) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $bytes = [IO.File]::ReadAllBytes($file)
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $text = [IO.File]::ReadAllText($file)
        $before = $count.Repointed
        $text = [regex]::Replace($text, '"[A-Za-z]:\\\\(?:[^"\\]+\\\\)*?Juegos\\\\FFXIV\\\\', {
            param($m)
            if ($m.Value -ne ('"' + $jsonFfxiv)) { $count.Repointed++ }
            return '"' + $jsonFfxiv
        })
        # Same encoding as before; the old account's path only worked through a junction.
        if ($count.Repointed -gt $before) { [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($bom))) }
    }
    # 2) A dev plugin DLL that is missing comes from the prebuilt zip in the plugin repo.
    $text = [IO.File]::ReadAllText($cfgPath)
    foreach ($m in [regex]::Matches($text, '"Path":\s*"[^"]*?\\\\Juegos\\\\FFXIV\\\\([^"]+?\.dll)"')) {
        $rel = $m.Groups[1].Value.Replace('\\', '\')
        $dll = Join-Path $ffxiv $rel
        $name = [IO.Path]::GetFileNameWithoutExtension($dll)
        if (-not (Test-Path -LiteralPath $dll)) {
            # The plugin repo sits in Juegos\FFXIV\<repo> or Juegos\FFXIV\Plugins\<repo>.
            $zip = @(Get-ChildItem -Path (Join-Path $ffxiv "*\plugins\$name\latest.zip"), (Join-Path $ffxiv "*\*\plugins\$name\latest.zip") -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($zip) {
                try {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    $dir = Split-Path -Parent $dll
                    $null = New-Item -ItemType Directory -Force -Path $dir
                    [IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $dir)
                    Write-Host "    $name : extracted from $($zip.FullName)" -ForegroundColor Green
                    $count.Placed++
                }
                catch { Write-Host "    $name : extract failed: $($_.Exception.Message)" -ForegroundColor Yellow }
            }
            else { Write-Host "    $name : no DLL and no prebuilt zip (build it from its repo)" -ForegroundColor Yellow }
        }
    }
    Write-Host "  dev plugins: $($count.Placed) DLL(s) placed, $($count.Repointed) path(s) re-pointed at $ffxiv"
}

$failures = New-Object System.Collections.ArrayList
try {
    foreach ($r in $repos) {
        $url = "https://github.com/vaoan/$($r.Name).git"
        $dest = $r.Dest
        Write-Host ""
        Write-Host "== $($r.Name) -> $dest" -ForegroundColor Cyan
        $isClone = $false
        if (Test-Path -LiteralPath (Join-Path $dest '.git')) {
            $origin = (& git -C $dest remote get-url origin 2>$null)
            $isClone = ($origin -and ($origin.TrimEnd('/') -replace '\.git$', '') -ieq ($url -replace '\.git$', ''))
        }
        if ($isClone) {
            # An interrupted clone leaves .git with the right origin but no commit checked out.
            & git -C $dest rev-parse --verify --quiet HEAD *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Host '  an earlier clone was interrupted; resuming it'
                $code = Invoke-Git @('-C', $dest, 'fetch', '--progress', '--depth', '1', 'origin', $r.Branch)
                # No -f: a file in the way stops the checkout instead of being overwritten.
                if ($code -eq 0) { $code = Invoke-Git @('-C', $dest, 'checkout', '-B', $r.Branch, 'FETCH_HEAD') }
                if ($code -ne 0) { Write-Host "  FAILED: resume exit $code" -ForegroundColor Red; $null = $failures.Add($r.Name) } else { Write-Host '  OK (resumed)' -ForegroundColor Green }
                continue
            }
            Write-Host '  already restored; fast-forwarding'
            $code = Invoke-Git @('-C', $dest, 'pull', '--ff-only', '--depth', '1')
            if ($code -ne 0) { Write-Host "  pull failed (exit $code); the existing copy is kept as is" -ForegroundColor Yellow }
            continue
        }
        $notEmpty = (Test-Path -LiteralPath $dest) -and (Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($notEmpty) {
            # Moved aside, never deleted. Seen on 2026-11-19: the game's boot updater had already
            # created FFXIV_BOOT.cfg and downloads\ in the FFXIVConfig folder, so the restore stopped.
            $aside = "$dest.before-restore-$(Get-Date -Format yyyyMMdd-HHmmss)"
            try { Move-Item -LiteralPath $dest -Destination $aside -ErrorAction Stop; Write-Host "  $dest had other files; moved them to $aside (nothing deleted)" -ForegroundColor Yellow }
            catch { Write-Host "  FAILED: $dest has files, is not a clone of $($r.Name), and could not be moved aside: $($_.Exception.Message)" -ForegroundColor Red; $null = $failures.Add($r.Name); continue }
        }
        $parent = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        $started = Get-Date
        $code = Invoke-Git @('clone', '--progress', '--depth', '1', '--single-branch', '--branch', $r.Branch, '--config', 'core.longpaths=true', $url, $dest)
        $secs = [int]((Get-Date) - $started).TotalSeconds
        $files = @(Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue).Count
        if ($code -ne 0 -or $files -lt 2) {
            Write-Host "  FAILED: clone exit $code ($secs s)" -ForegroundColor Red
            $null = $failures.Add($r.Name)
        }
        else {
            Write-Host ("  OK in {0} s ({1:N2} GB)" -f $secs, ((Get-ChildItem -LiteralPath $dest -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB)) -ForegroundColor Green
        }
    }
    if ($doPlugins) { Restore-PluginRepos }
}
finally {
    Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -gt 0) { Write-Host "FFXIV restore finished with failures: $($failures -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'FFXIV profiles restored.' -ForegroundColor Green
exit 0
