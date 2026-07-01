# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Registers a Windows scheduled task that keeps the Spotify->Discord bridge
# available. The bridge itself runs as WSL systemd services (go-librespot +
# spotify-discord-bot, both enabled at boot and held alive by WSLKeepAlive);
# this task is a belt-and-suspenders that (re)starts them at logon/startup and
# boots WSL if it happens to be down.

$ErrorActionPreference = 'Stop'
$taskName = 'SpotifyDiscordBridge'
$distro   = 'Ubuntu-24.04'

function Write-Log { param([string]$m) Write-Host "[install-scheduled-task] $m" }

# One command: ensure WSL is up, then start both services (idempotent).
$cmd = "wsl -d $distro --user root -- bash -lc `"systemctl start go-librespot spotify-discord-bot`""
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"$cmd`""

$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn),
    (New-ScheduledTaskTrigger -AtStartup)
)

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
Write-Log "Registered scheduled task '$taskName' (at logon + startup)."

# Kick it once now so the bridge is up immediately.
try { Start-ScheduledTask -TaskName $taskName; Write-Log "Started '$taskName' now." } catch { Write-Log "Could not start now: $($_.Exception.Message)" }
