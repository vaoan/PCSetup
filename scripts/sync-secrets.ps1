# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'

$rootDir     = Split-Path -Parent $PSScriptRoot
$secretsPath = Join-Path $rootDir '.secrets'
$downloadDir = Join-Path $rootDir '.secrets-download'
$decryptTmp  = Join-Path $rootDir '.secrets-decrypted.tmp'

$WORKFLOW_FILE    = 'sync-secrets.yml'
$ARTIFACT_NAME    = 'secrets-encrypted'
$POLL_INTERVAL_MS = 5000
$TIMEOUT_MS       = 120000

function Write-Log { param([string]$msg) Write-Host "[sync-secrets] $msg" }
function Fail { param([string]$msg) Write-Host "[sync-secrets] ERROR: $msg" -ForegroundColor Red; exit 1 }

function Find-OpenSSL {
    $onPath = Get-Command 'openssl.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $gitBin = 'C:\Program Files\Git\usr\bin\openssl.exe'
    if (Test-Path $gitBin) { return $gitBin }
    Fail "openssl.exe not found. Make sure Git for Windows is installed (run 2-setup-windows.bat)."
}

function Read-Passphrase {
    $passphraseFile = Join-Path $env:USERPROFILE '.pcsetup-sync-passphrase'
    if (-not (Test-Path $passphraseFile)) {
        Fail "Passphrase file not found: $passphraseFile`nRun first-time setup from .secrets.example to create it."
    }
    $passphrase = (Get-Content $passphraseFile -Raw).Trim()
    if (-not $passphrase) { Fail "Passphrase file is empty: $passphraseFile" }
    return $passphrase
}

function Assert-GhAuth {
    & gh auth status 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "gh CLI not authenticated. Run: gh auth login" }
}

function Get-RepoSlug {
    $out = & gh repo view --json nameWithOwner -q '.nameWithOwner' 2>&1
    if ($LASTEXITCODE -ne 0 -or -not "$out".Trim()) {
        Fail "Could not determine repository slug. Are you in a GitHub repo?"
    }
    return "$out".Trim()
}

function Start-SyncWorkflow {
    Write-Log "Triggering sync-secrets workflow..."
    $branch = (& git branch --show-current 2>&1).Trim()
    if (-not $branch) { $branch = 'main' }
    Write-Log "Using branch: $branch"
    & gh workflow run $WORKFLOW_FILE --ref $branch
    if ($LASTEXITCODE -ne 0) { Fail "Failed to trigger workflow." }
}

function Wait-ForRun { param([string]$prevRunId)
    Write-Log "Waiting for workflow to complete..."
    Start-Sleep -Seconds 3
    $start = [DateTime]::UtcNow
    while (([DateTime]::UtcNow - $start).TotalMilliseconds -lt $TIMEOUT_MS) {
        $json = & gh run list --workflow $WORKFLOW_FILE --limit 1 --json databaseId,status,conclusion 2>&1
        if ($LASTEXITCODE -eq 0 -and $json) {
            try {
                $runs = @($json | ConvertFrom-Json)
                if ($runs.Count -gt 0) {
                    $run = $runs[0]
                    if ("$($run.databaseId)" -eq $prevRunId) {
                        Start-Sleep -Milliseconds $POLL_INTERVAL_MS
                        continue
                    }
                    if ($run.status -eq 'completed') {
                        if ($run.conclusion -eq 'success') {
                            Write-Log "Workflow completed (run $($run.databaseId))."
                            return $run.databaseId
                        }
                        Fail "Workflow failed ($($run.conclusion)). Check: gh run view $($run.databaseId)"
                    }
                    $elapsed = [int]([DateTime]::UtcNow - $start).TotalSeconds
                    Write-Host -NoNewline "`r[sync-secrets] Workflow $($run.status)... ($($elapsed)s)"
                }
            } catch {
                Write-Log "Warning: failed to parse gh output - retrying"
            }
        }
        Start-Sleep -Milliseconds $POLL_INTERVAL_MS
    }
    Fail "Timed out after $($TIMEOUT_MS / 1000)s. Check: gh run list --workflow $WORKFLOW_FILE"
}

function Get-EncryptedArtifact { param([string]$runId)
    Write-Log "Downloading encrypted artifact..."
    if (Test-Path $downloadDir) { Remove-Item $downloadDir -Recurse -Force }
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    & gh run download $runId --name $ARTIFACT_NAME --dir $downloadDir
    if ($LASTEXITCODE -ne 0) { Fail "Failed to download artifact." }
    $encPath = Join-Path $downloadDir 'secrets-encrypted.bin'
    if (-not (Test-Path $encPath)) {
        Remove-Item $downloadDir -Recurse -Force
        Fail "Artifact missing secrets-encrypted.bin."
    }
    return $encPath
}

function Expand-Secrets { param([string]$encPath, [string]$passphrase, [string]$openssl)
    Write-Log "Decrypting secrets..."
    $passphrase | & $openssl aes-256-cbc -d -pbkdf2 -in $encPath -out $decryptTmp -pass stdin
    $opensslExit = $LASTEXITCODE
    Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($opensslExit -ne 0) {
        if (Test-Path $decryptTmp) { Remove-Item $decryptTmp -Force }
        Fail "Decryption failed. Verify SYNC_PASSPHRASE in GitHub Secrets matches $env:USERPROFILE\.pcsetup-sync-passphrase."
    }
    $content = $null
    try {
        $content = [System.IO.File]::ReadAllText($decryptTmp)
        [System.IO.File]::WriteAllText($secretsPath, $content, [System.Text.Encoding]::UTF8)
    } finally {
        if (Test-Path $decryptTmp) { Remove-Item $decryptTmp -Force }
    }
    $count = ($content -split "`n" | Where-Object { $_ -match '^\s*[^#\s].*=' }).Count
    return $count
}

# ── Main ──────────────────────────────────────────────────────────────────────
Assert-GhAuth
$repo       = Get-RepoSlug
$openssl    = Find-OpenSSL
$passphrase = Read-Passphrase
Write-Log "Repository: $repo"
Write-Log "openssl: $openssl"

$prevRunId = (& gh run list --workflow $WORKFLOW_FILE --limit 1 --json databaseId -q '.[0].databaseId' 2>$null).Trim()
Start-SyncWorkflow
$runId      = Wait-ForRun $prevRunId
Write-Host ""
$encPath    = Get-EncryptedArtifact $runId
$count      = Expand-Secrets $encPath $passphrase $openssl
Write-Log "Synced $count secrets to .secrets"
