# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SSH Tunnel Uninstaller" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$taskName = "ssh-tunnel"
$configDir = Join-Path $env:USERPROFILE ".cloudflared"
$sshConfigPath = Join-Path $configDir "ssh-config.yml"
$launcherPath = Join-Path $configDir "ssh-tunnel-launcher.vbs"
$credentialsPath = Join-Path $configDir "8dffdb51-77cc-43ca-8dc8-8a0c720607a5.json"

# Step 1: Stop and remove scheduled task
Write-Host "[1/4] Removing scheduled task..." -ForegroundColor Yellow
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "  OK Task removed" -ForegroundColor Green
} else {
    Write-Host "  SKIP Task not found" -ForegroundColor Gray
}

# Step 2: Kill matching cloudflared process
Write-Host ""
Write-Host "[2/4] Stopping cloudflared processes for ssh-tunnel..." -ForegroundColor Yellow
$killed = 0
Get-WmiObject Win32_Process -Filter "Name='cloudflared.exe'" | ForEach-Object {
    $cmd = $_.CommandLine
    if ($cmd -and $cmd -match "run ssh-tunnel") {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $killed++
    }
}
if ($killed -gt 0) {
    Write-Host "  OK Stopped $killed process(es)" -ForegroundColor Green
} else {
    Write-Host "  SKIP No matching processes running" -ForegroundColor Gray
}

# Step 3: Remove local config artifacts
Write-Host ""
Write-Host "[3/4] Removing local config..." -ForegroundColor Yellow
Remove-Item $sshConfigPath -Force -ErrorAction SilentlyContinue
Remove-Item $launcherPath -Force -ErrorAction SilentlyContinue
Remove-Item $credentialsPath -Force -ErrorAction SilentlyContinue
Write-Host "  OK Removed ssh-config.yml, launcher, and credentials" -ForegroundColor Green

# Step 4: Stop SSH service but leave the Windows capability installed for easy reinstall
Write-Host ""
Write-Host "[4/4] Stopping SSH service..." -ForegroundColor Yellow
Stop-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Disabled -ErrorAction SilentlyContinue
Write-Host "  OK SSH service stopped and disabled" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "To reinstall: .\install-ssh-tunnel.ps1" -ForegroundColor Gray
Write-Host ""
