param(
    [switch]$SkipSecretSync,
    [switch]$SkipUninstall,
    [string]$ReportDir = (Join-Path $env:USERPROFILE '.cloudflared\reports')
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

function Write-Log {
    param([string]$Message)
    Write-Host "[test-clean-install] $Message"
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Write-Log $Label
    & $Action
}

$repoRoot = Split-Path -Parent $PSScriptRoot

if (-not $SkipSecretSync) {
    Invoke-Step -Label 'Syncing .secrets from GitHub encrypted artifact...' -Action {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'sync-secrets.ps1')
        if ($LASTEXITCODE -ne 0) {
            throw "sync-secrets.ps1 failed with exit code $LASTEXITCODE"
        }
    }
}

if (-not $SkipUninstall) {
    Invoke-Step -Label 'Removing existing console/dev/web/ssh Cloudflare install state...' -Action {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'uninstall-console.ps1')
        if ($LASTEXITCODE -ne 0) { throw "uninstall-console.ps1 failed with exit code $LASTEXITCODE" }

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'uninstall-tunnel.ps1')
        if ($LASTEXITCODE -ne 0) { throw "uninstall-tunnel.ps1 failed with exit code $LASTEXITCODE" }

        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'uninstall-ssh-tunnel.ps1')
        if ($LASTEXITCODE -ne 0) { throw "uninstall-ssh-tunnel.ps1 failed with exit code $LASTEXITCODE" }
    }
}

Invoke-Step -Label 'Rebuilding the Cloudflare stack from the repo recovery path...' -Action {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'post-format-recovery.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw "post-format-recovery.ps1 failed with exit code $LASTEXITCODE"
    }
}

Invoke-Step -Label 'Running full post-install verification...' -Action {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-console.ps1') -ReportDir $ReportDir
    if ($LASTEXITCODE -ne 0) {
        throw "verify-console.ps1 failed with exit code $LASTEXITCODE"
    }
}

Write-Log "Clean-install smoke test passed. Reports saved under $ReportDir"
