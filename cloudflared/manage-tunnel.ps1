# Check Cloudflare Tunnel Status
$taskName = "ffxivbe-tunnel"

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    $color = if ($task.State -eq "Running") { "Green" } else { "Yellow" }
    Write-Host "Task Status: $($task.State)" -ForegroundColor $color
} else {
    Write-Host "Task not found!" -ForegroundColor Red
    exit 1
}

$proc = Get-Process -Name cloudflared -ErrorAction SilentlyContinue
Write-Host "Processes: $($proc.Count)" -ForegroundColor Gray

$tunnel = cloudflared tunnel info ffxivbe-tunnel 2>&1 | Select-String "CONNECTOR"
if ($tunnel) {
    Write-Host "Tunnel: HAS CONNECTIONS" -ForegroundColor Green
} else {
    Write-Host "Tunnel: NO CONNECTIONS" -ForegroundColor Red
}

$url = Invoke-WebRequest -Uri "https://ffxivbe.org" -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue
if ($url) {
    Write-Host "Remote URL: Status $($url.StatusCode) - WORKING" -ForegroundColor Green
} else {
    Write-Host "Remote URL: NOT WORKING" -ForegroundColor Red
}
