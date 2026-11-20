# Restores the FFXIV profiles from the private GitHub backups after a format.
#
# Destinations are the ones the repos' own clone scripts use (Profiles\Me\shallow-clone*.bat,
# XIVProfiles env.example PROFILES_DIR=../Profiles, Me\Launcher.bat --roamingPath):
#   vaoan/Profiles     -> <Documents>\Juegos\FFXIV\Profiles
#   vaoan/XIVLauncher  -> <Documents>\Juegos\FFXIV\Profiles\Me\XIVLauncher   (Me's roaming path)
#   vaoan/XIVProfiles  -> <Documents>\Juegos\FFXIV\XIVProfiles                (profile manager)
#   vaoan/FFXIVConfig  -> <Documents>\My Games\FINAL FANTASY XIV - A Realm Reborn
#   vaoan/MINION       -> C:\MINION
#
# Never deletes: a destination that is already a clone of the repo is fast-forwarded, an empty
# or missing one is cloned, and a non-empty folder that is not that clone is left alone (FAILED).
#
# GH_TOKEN comes from secrets.txt / .secrets and is NEVER printed or logged: it lives only in this
# process' environment and reaches git through an inline credential helper, so it is not on any
# command line, in the remote URL or in the clones' .git/config.
param(
    [string]$SecretsFile = '',
    [string[]]$Only = @()
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
    @{ Name = 'MINION';      Branch = 'master'; Dest = 'C:\MINION' }
)
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
if (-not $token) { Write-Host 'No GH_TOKEN found in any secrets.txt / .secrets - cannot reach the private repos.' -ForegroundColor Red; exit 1 }
$env:GH_TOKEN = $token
Remove-Variable token
# The helper body runs in Git for Windows' sh; $GH_TOKEN is expanded there, not here.
$helper = 'credential.helper=!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f'

function Invoke-Git {
    param([string[]]$GitArgs)
    & git -c credential.helper= -c $helper -c core.longpaths=true @GitArgs 2>&1 | ForEach-Object { Write-Host "    $_" }
    return $LASTEXITCODE
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
            Write-Host '  already restored; fast-forwarding'
            $code = Invoke-Git @('-C', $dest, 'pull', '--ff-only', '--depth', '1')
            if ($code -ne 0) { Write-Host "  pull failed (exit $code); the existing copy is kept as is" -ForegroundColor Yellow }
            continue
        }
        $notEmpty = (Test-Path -LiteralPath $dest) -and (Get-ChildItem -LiteralPath $dest -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($notEmpty) {
            Write-Host "  FAILED: $dest has files and is not a clone of $($r.Name) - left untouched (move it aside and re-run)" -ForegroundColor Red
            $null = $failures.Add($r.Name)
            continue
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
}
finally {
    Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -gt 0) { Write-Host "FFXIV restore finished with failures: $($failures -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'FFXIV profiles restored.' -ForegroundColor Green
exit 0
