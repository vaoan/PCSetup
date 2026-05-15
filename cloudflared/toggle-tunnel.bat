@echo off
powershell -ExecutionPolicy Bypass -Command "$task = Get-ScheduledTask -TaskName 'ffxivbe-tunnel'; if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName 'ffxivbe-tunnel'; Write-Host 'Tunnel stopped!' -ForegroundColor Yellow } else { Start-ScheduledTask -TaskName 'ffxivbe-tunnel'; Write-Host 'Tunnel started!' -ForegroundColor Green }; Start-Sleep -Seconds 2"


