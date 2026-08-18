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

function Resolve-WorkflowRef {
    $branch = (& git branch --show-current 2>&1).Trim()
    if (-not $branch) { $branch = 'main' }

    # workflow_dispatch reads the workflow file from the *remote* ref, so a branch
    # that only exists locally fails with "Workflow does not exist". Note
    # `git ls-remote --heads` exits 0 with no output when the branch is absent, so
    # test the output rather than $LASTEXITCODE.
    $onRemote = (& git ls-remote --heads origin $branch 2>$null | Out-String).Trim()
    if ($onRemote) { return $branch }

    $default = "$(& gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>$null)".Trim()
    if (-not $default) { $default = 'main' }
    Write-Log "Branch '$branch' is not on origin - dispatching against '$default' instead."

    # The dispatched run uses that ref's copy of the workflow, so an unpushed edit
    # to the secret list would silently not take effect.
    & git fetch origin $default --quiet 2>$null
    $drift = (& git diff "origin/$default" --name-only -- ".github/workflows/$WORKFLOW_FILE" 2>$null | Out-String).Trim()
    if ($drift) {
        Write-Log "WARNING: local $WORKFLOW_FILE differs from origin/$default - push it or the run will use the old secret list."
    }
    return $default
}

function Start-SyncWorkflow { param([string]$ref)
    Write-Log "Triggering sync-secrets workflow..."
    Write-Log "Using ref: $ref"
    & gh workflow run $WORKFLOW_FILE --ref $ref
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
    $tempPassFile = [IO.Path]::GetTempFileName()
    $opensslExit = 1
    try {
        [IO.File]::WriteAllText($tempPassFile, $passphrase, [Text.Encoding]::ASCII)
        & $openssl aes-256-cbc -d -pbkdf2 -iter 600000 -in $encPath -out $decryptTmp -pass "file:$tempPassFile"
        $opensslExit = $LASTEXITCODE
    } finally {
        if (Test-Path $tempPassFile) { Remove-Item $tempPassFile -Force }
    }
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
Start-SyncWorkflow (Resolve-WorkflowRef)
$runId      = Wait-ForRun $prevRunId
Write-Host ""
$encPath    = Get-EncryptedArtifact $runId
$count      = Expand-Secrets $encPath $passphrase $openssl
Write-Log "Synced $count secrets to .secrets"
