# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Cloudflare Tunnel Uninstaller" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$taskName  = "ffxivbe-tunnel"
$configPath = Join-Path $env:USERPROFILE ".cloudflared\config.yml"

# Step 1: Stop and remove scheduled task
Write-Host "[1/3] Removing scheduled task..." -ForegroundColor Yellow
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "  OK Task removed" -ForegroundColor Green
} else {
    Write-Host "  SKIP Task not found" -ForegroundColor Gray
}

# Step 2: Kill any running cloudflared processes using this config
Write-Host ""
Write-Host "[2/3] Stopping cloudflared processes for ffxivbe-tunnel..." -ForegroundColor Yellow
$killed = 0
Get-WmiObject Win32_Process -Filter "Name='cloudflared.exe'" | ForEach-Object {
    $cmd = $_.CommandLine
    if ($cmd -match "config\.yml" -or $cmd -match "ffxivbe-tunnel" -or $cmd -match "run-tunnel-hidden") {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $killed++
    }
}
if ($killed -gt 0) {
    Write-Host "  OK Stopped $killed process(es)" -ForegroundColor Green
} else {
    Write-Host "  SKIP No matching processes running" -ForegroundColor Gray
}

# Step 3: Report config/credentials status (not deleted — needed for reinstall)
Write-Host ""
Write-Host "[3/3] Config files..." -ForegroundColor Yellow
Write-Host "  NOTE Config kept at: $configPath" -ForegroundColor Gray
Write-Host "  NOTE DNS records and Cloudflare tunnel registration kept (run cloudflared tunnel delete to remove)" -ForegroundColor Gray

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "To reinstall: .\install-tunnel.ps1" -ForegroundColor Gray
Write-Host ""
