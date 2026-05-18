# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$results = [System.Collections.Generic.List[PSObject]]::new()

function Test-PortListening {
    # Checks LISTEN state via netstat — does NOT open a TCP connection,
    # which would disturb portproxy state for subsequent HTTP checks.
    param([int]$Port)
    $hit = netstat -an 2>$null | Select-String "127\.0\.0\.1:$Port\s+.*LISTENING"
    return [bool]$hit
}

function Test-HttpWindows {
    # Tests a Windows-side HTTP service (no portproxy involved).
    # Uses HttpWebRequest with KeepAlive=false for a clean single-shot request.
    param([string]$Url, [hashtable]$Headers = @{})
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout   = 8000
        $req.KeepAlive = $false
        $req.Method    = 'GET'
        foreach ($key in $Headers.Keys) {
            if ($key -eq 'Host') { $req.Host = $Headers[$key] }
            else { $req.Headers.Add($key, $Headers[$key]) }
        }
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return $code
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            $_.Exception.Response.Close()
            return $code
        }
        return 0
    } catch { return 0 }
}

function Test-HttpWSL {
    # Tests a WSL-side HTTP service using curl inside WSL.
    # Avoids the Windows portproxy entirely — tests the service directly
    # from within WSL where it runs.
    param([int]$Port, [string]$Path = '/')
    try {
        $code = wsl -d Ubuntu-24.04 --user root -- bash -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:${Port}${Path} 2>/dev/null" 2>$null
        return [int]$code.Trim()
    } catch { return 0 }
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

# ── HTTP checks ────────────────────────────────────────────────────────────
# WSL services tested from inside WSL (no portproxy involved — avoids
# portproxy state corruption that would break the subsequent port checks).
# Windows services tested via HttpWebRequest.
$httpChecks = @(
    @{ Name = 'dashboard';     Type = 'wsl';     Port = 7686; Path = '/';     Headers = @{} }
    @{ Name = 'console-proxy'; Type = 'windows'; Port = 7681; Path = '/';     Headers = @{ Host = 'console.ffxivbe.org' } }
    @{ Name = 'ttyd-proxy';    Type = 'wsl';     Port = 7683; Path = '/';     Headers = @{} }
    @{ Name = 'git-proxy';     Type = 'wsl';     Port = 7687; Path = '/repos'; Headers = @{} }
)
foreach ($e in $httpChecks) {
    if ($e.Type -eq 'wsl') {
        $code = Test-HttpWSL $e.Port $e.Path
    } else {
        $code = Test-HttpWindows "http://127.0.0.1:$($e.Port)$($e.Path)" $e.Headers
    }
    $ok = ($code -ge 200 -and $code -lt 300)
    Add-Result "$($e.Name)" 'http' $ok "HTTP $code"
}

# ── Windows port-listening checks (netstat, no TCP connection) ──────────────
$ports = @(
    @{ Name = 'dashboard';     Port = 7686 }
    @{ Name = 'console-proxy'; Port = 7681 }
    @{ Name = 'ttyd-proxy';    Port = 7683 }
    @{ Name = 'git-proxy';     Port = 7687 }
)
foreach ($p in $ports) {
    $ok = Test-PortListening $p.Port
    Add-Result "$($p.Name) ($($p.Port))" 'port' $ok "127.0.0.1:$($p.Port)"
}

# ── WSL service checks ──────────────────────────────────────────────────────
$wslServices = @('ssh', 'code-server@root', 'ttyd-proxy', 'ttyd-persistent', 'ttyd-fresh', 'git-proxy', 'ungit')
foreach ($svc in $wslServices) {
    $ok = Test-WslService $svc
    Add-Result "WSL: $svc" 'systemd' $ok ''
}

# ── Results output ──────────────────────────────────────────────────────────
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
