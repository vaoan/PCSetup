# Install Scheduled Tasks for Cloudflare Tunnels
# Run this to restore auto-start behavior after format
# Automatically elevates to Administrator if needed

$ErrorActionPreference = "Stop"

# Check if running as Administrator, if not, restart with elevation
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "Elevating to Administrator..." -ForegroundColor Yellow
    Write-Host ""

    $scriptPath = $MyInvocation.MyCommand.Path
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`"" -Wait
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Install Scheduled Tasks" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path $env:USERPROFILE ".cloudflared"

function New-CloudflaredStartupTriggers {
    param([string]$UserName)

    return @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn -User $UserName)
    )
}

function New-CloudflaredTaskSettings {
    return New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -Hidden -MultipleInstances IgnoreNew
}

# ============================================
# Web Tunnel (ffxivbe-tunnel)
# ============================================
Write-Host "[1/2] Web Tunnel (ffxivbe-tunnel)..." -ForegroundColor Yellow

$webTaskName = "ffxivbe-tunnel"
$webConfigPath = Join-Path $configDir "config.yml"
$webLauncherPath = Join-Path $configDir "ffxivbe-tunnel-launcher.vbs"
$cloudflaredPath = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'

if (-not (Test-Path $webConfigPath)) {
    Write-Host "  SKIP config.yml not found" -ForegroundColor Yellow
    Write-Host "  Run install-tunnel.ps1 for full setup" -ForegroundColor Gray
} else {
    # Remove existing task if present
    Unregister-ScheduledTask -TaskName $webTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $webLauncherContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run Chr(34) & "$cloudflaredPath" & Chr(34) & " tunnel --config " & Chr(34) & "$webConfigPath" & Chr(34) & " run ffxivbe-tunnel", 0, False
"@
    Set-Content -Path $webLauncherPath -Value $webLauncherContent

    $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$webLauncherPath`""
    $trigger = New-CloudflaredStartupTriggers -UserName $env:USERNAME
    $settings = New-CloudflaredTaskSettings
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

    Register-ScheduledTask -TaskName $webTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Cloudflare Tunnel for ffxivbe.org (boot-started)" | Out-Null
    Write-Host "  OK Task installed: $webTaskName" -ForegroundColor Green

    Start-ScheduledTask -TaskName $webTaskName
    Write-Host "  OK Task started" -ForegroundColor Green
}

# ============================================
# SSH Tunnel (ssh-tunnel)
# ============================================
Write-Host ""
Write-Host "[2/2] SSH Tunnel (ssh-tunnel)..." -ForegroundColor Yellow

$sshTaskName = "ssh-tunnel"
$sshConfigPath = Join-Path $configDir "ssh-config.yml"
$sshLauncherPath = Join-Path $configDir "ssh-tunnel-launcher.vbs"
$sshTunnelName = "ssh-tunnel"

if (-not (Test-Path $sshConfigPath)) {
    Write-Host "  SKIP ssh-config.yml not found" -ForegroundColor Yellow
    Write-Host "  Run install-ssh-tunnel.ps1 for full setup" -ForegroundColor Gray
} else {
    # Remove existing task if present
    Unregister-ScheduledTask -TaskName $sshTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $sshLauncherContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run Chr(34) & "$cloudflaredPath" & Chr(34) & " tunnel --config " & Chr(34) & "$sshConfigPath" & Chr(34) & " run $sshTunnelName", 0, False
"@
    Set-Content -Path $sshLauncherPath -Value $sshLauncherContent

    $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$sshLauncherPath`""
    $trigger = New-CloudflaredStartupTriggers -UserName $env:USERNAME
    $settings = New-CloudflaredTaskSettings
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

    Register-ScheduledTask -TaskName $sshTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "SSH Tunnel for pc.ffxivbe.org (boot-started)" | Out-Null
    Write-Host "  OK Task installed: $sshTaskName" -ForegroundColor Green

    Start-ScheduledTask -TaskName $sshTaskName
    Write-Host "  OK Task started" -ForegroundColor Green
}

# ============================================
# Summary
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Done!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Scheduled Tasks Status:" -ForegroundColor Cyan
$webTask = Get-ScheduledTask -TaskName $webTaskName -ErrorAction SilentlyContinue
$sshTask = Get-ScheduledTask -TaskName $sshTaskName -ErrorAction SilentlyContinue

if ($webTask) {
    Write-Host "  ffxivbe-tunnel: $($webTask.State)" -ForegroundColor $(if ($webTask.State -eq 'Running') { 'Green' } else { 'Yellow' })
} else {
    Write-Host "  ffxivbe-tunnel: Not installed" -ForegroundColor Gray
}

if ($sshTask) {
    Write-Host "  ssh-tunnel: $($sshTask.State)" -ForegroundColor $(if ($sshTask.State -eq 'Running') { 'Green' } else { 'Yellow' })
} else {
    Write-Host "  ssh-tunnel: Not installed" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Both tunnels will now start automatically at boot and logon." -ForegroundColor Gray
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
