# Cloudflared tunnel supervisor.
#
# Why this exists:
#   cloudflared runs a startup precheck. If the Cloudflare edge isn't resolvable/
#   reachable yet (region1.v2.argotunnel.com:7844) it hard-fails and *exits* - it
#   does NOT keep retrying. At boot/logon the network is frequently not ready yet
#   (ProtonVPN still connecting, DNS not up), so the tunnel dies and never comes
#   back until started by hand. See the "console-down-after-reboot" note.
#
#   This wrapper fixes that: it waits until the Cloudflare edge is actually
#   reachable, THEN launches cloudflared, and if cloudflared ever exits it waits
#   for the edge again and relaunches. One long-lived, self-healing process.
#
# It is always launched already-elevated (by a RunLevel=Highest scheduled task or
# by start-console.ps1). The auto-elevation block below is therefore a no-op in
# normal use and only matters if someone runs it by hand from a non-admin shell.

param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,   # cloudflared --config path
    [string]$RunTarget = '',                             # tunnel name arg (blank = read from config)
    [Parameter(Mandatory = $true)][string]$CfLog,        # cloudflared stderr log file
    [Parameter(Mandatory = $true)][string]$LogPath,      # this supervisor's own log
    [string]$CfPidFile = '',                             # optional: written with the live cloudflared PID
    [string]$Label = 'tunnel'                            # log tag
)

# Auto-elevate to Administrator (no-op when already elevated, which is the normal path)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $reArgs = @('-ConfigPath', "`"$ConfigPath`"", '-RunTarget', "`"$RunTarget`"", '-CfLog', "`"$CfLog`"", '-LogPath', "`"$LogPath`"", '-CfPidFile', "`"$CfPidFile`"", '-Label', "`"$Label`"") -join ' '
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" $reArgs" -Verb RunAs
    exit
}

$cfExe = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'

function Write-SupLog {
    param([string]$msg)
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    try { Add-Content -Path $LogPath -Value "$ts [supervisor:$Label] $msg" -ErrorAction SilentlyContinue } catch { }
}

# True once the Cloudflare tunnel edge is reachable (DNS resolves AND TCP:7844 opens).
# This is exactly what cloudflared's precheck needs, so if this passes the tunnel connects.
function Test-CloudflareEdge {
    param([int]$TimeoutMs = 3000)
    foreach ($edgeHost in @('region1.v2.argotunnel.com', 'region2.v2.argotunnel.com')) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($edgeHost, 7844, $null, $null)   # BeginConnect resolves DNS; throws if it can't
            if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected) {
                $client.EndConnect($iar)
                return $true
            }
        } catch {
            # DNS failure or connection refused/timeout -> edge not ready yet
        } finally {
            if ($client) { $client.Close() }
        }
    }
    return $false
}

if (-not (Test-Path $cfExe)) {
    Write-SupLog "FATAL: cloudflared.exe not found at $cfExe"
    exit 1
}

$cfArgs = @('tunnel', '--config', $ConfigPath, 'run')
if ($RunTarget) { $cfArgs += $RunTarget }

Write-SupLog "Supervisor started (PID $PID). config=$ConfigPath target='$RunTarget'"

while ($true) {
    # 1. Wait for the Cloudflare edge to be reachable.
    $waited = 0
    while (-not (Test-CloudflareEdge)) {
        if ($waited % 30 -eq 0) { Write-SupLog "Waiting for Cloudflare edge (region*.v2.argotunnel.com:7844)... ${waited}s" }
        Start-Sleep -Seconds 5
        $waited += 5
    }
    Write-SupLog "Edge reachable after ${waited}s; launching cloudflared"

    # 2. Launch cloudflared (foreground of this supervisor) and wait for it to exit.
    try {
        $proc = Start-Process -FilePath $cfExe -ArgumentList $cfArgs `
            -WindowStyle Hidden -RedirectStandardError $CfLog -PassThru
    } catch {
        Write-SupLog "ERROR launching cloudflared: $($_.Exception.Message); retrying in 10s"
        Start-Sleep -Seconds 10
        continue
    }

    if ($CfPidFile) { $proc.Id | Out-File -FilePath $CfPidFile -Encoding utf8 }
    Write-SupLog "cloudflared running (PID $($proc.Id))"

    $proc.WaitForExit()
    $code = $proc.ExitCode
    if ($CfPidFile) { Remove-Item $CfPidFile -Force -ErrorAction SilentlyContinue }
    Write-SupLog "cloudflared exited (code $code); will re-check edge and relaunch in 5s"

    # 3. Brief backoff, then loop back to the edge-readiness wait and relaunch.
    Start-Sleep -Seconds 5
}
