# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$results = [System.Collections.Generic.List[PSObject]]::new()

function Test-Port {
    param([int]$Port)
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $tcp.Connect('127.0.0.1', $Port)
        return $tcp.Connected
    } catch { return $false }
    finally { $tcp.Close(); $tcp.Dispose() }
}

function Test-Http {
    param([string]$Url)
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return [int]$r.StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        return 0
    }
}

function Test-WslService {
    param([string]$Service)
    try {
        $out = wsl systemctl is-active $Service 2>$null
        return ($out.Trim() -eq 'active')
    } catch { return $false }
}

function Add-Result {
    param([string]$Name, [string]$Check, [bool]$Passed, [string]$Detail = '')
    $results.Add([PSCustomObject]@{
        Service = $Name
        Check   = $Check
        Passed  = $Passed
        Detail  = $Detail
    })
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Console Service Verifier" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── Windows port checks ──────────────────────────────────────────────
$ports = @(
    @{ Name = 'dashboard'; Port = 7686 }
    @{ Name = 'console-proxy'; Port = 7681 }
    @{ Name = 'ttyd-proxy'; Port = 7683 }
    @{ Name = 'git-proxy'; Port = 7687 }
)
foreach ($p in $ports) {
    $ok = Test-Port $p.Port
    Add-Result "$($p.Name) ($($p.Port))" 'port' $ok "localhost:$($p.Port)"
}

# ── HTTP checks ───────────────────────────────────────────────────────
$httpEndpoints = @(
    @{ Name = 'dashboard'; Url = 'http://localhost:7686' }
    @{ Name = 'console-proxy'; Url = 'http://localhost:7681' }
    @{ Name = 'ttyd-proxy'; Url = 'http://localhost:7683' }
    @{ Name = 'git-proxy'; Url = 'http://localhost:7687' }
)
foreach ($e in $httpEndpoints) {
    $code = Test-Http $e.Url
    $ok = ($code -ge 200 -and $code -lt 300)
    Add-Result "$($e.Name)" 'http' $ok "HTTP $code"
}

# ── WSL service checks ────────────────────────────────────────────────
$wslServices = @('ssh', 'code-server@root', 'ttyd-proxy', 'ttyd-persistent', 'ttyd-fresh', 'git-proxy', 'ungit')
foreach ($svc in $wslServices) {
    $ok = Test-WslService $svc
    Add-Result "WSL: $svc" 'systemd' $ok ''
}

# ── Results output ────────────────────────────────────────────────────
Write-Host ""
$width = @{ Service = 30; Check = 8 }
$header = "{0,-$($width.Service)} {1,-$($width.Check)} {2,-6} {3}" -f 'Service', 'Check', 'Status', 'Detail'
Write-Host $header -ForegroundColor White
Write-Host ("-" * 70) -ForegroundColor DarkGray

foreach ($r in $results) {
    $color = if ($r.Passed) { 'Green' } else { 'Red' }
    $status = if ($r.Passed) { 'PASS' } else { 'FAIL' }
    $line = "{0,-$($width.Service)} {1,-$($width.Check)} {2,-6} {3}" -f $r.Service, $r.Check, $status, $r.Detail
    Write-Host $line -ForegroundColor $color
}

$failed = @($results | Where-Object { -not $_.Passed })
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "All $($results.Count) checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failed.Count) of $($results.Count) check(s) failed." -ForegroundColor Red
    exit 1
}
