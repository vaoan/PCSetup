param(
    [string]$ReportDir = (Join-Path $env:USERPROFILE ".cloudflared\reports")
)

# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = Split-Path -Parent $PSScriptRoot
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportBase = Join-Path $ReportDir "post-install-$timestamp"
$jsonPath = "$reportBase.json"
$mdPath = "$reportBase.md"
$latestJson = Join-Path $ReportDir "latest.json"
$latestMd = Join-Path $ReportDir "latest.md"

$cloudflaredPath = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$cfDir = Join-Path $env:USERPROFILE '.cloudflared'
$cloudflareDir = Join-Path $env:USERPROFILE 'Documents\Cloudflare'
$sshwiftyDir = Join-Path $cloudflareDir 'sshwifty'
$launcherDir = Join-Path $cloudflareDir 'launcher'
$sshwiftyLog = Join-Path $sshwiftyDir 'sshwifty.log'
$proxyLog = Join-Path $launcherDir 'proxy.log'
$cfLog = Join-Path $cfDir 'cloudflared-dev.log'
$cfPidFile = Join-Path $cfDir 'cloudflared-dev.pid'
$sshwiftyConf = Join-Path $cloudflareDir 'sshwifty\sshwifty.conf.json'

New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null

$results = [System.Collections.Generic.List[PSObject]]::new()

function Add-Check {
    param(
        [string]$Group,
        [string]$Name,
        [string]$Expected,
        [string]$Actual,
        [bool]$Passed,
        [string]$Detail = ''
    )

    $results.Add([PSCustomObject]@{
        Group    = $Group
        Name     = $Name
        Expected = $Expected
        Actual   = $Actual
        Passed   = $Passed
        Detail   = $Detail
    })
}

function Get-TaskState {
    param([string]$TaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return 'Missing' }
    return $task.State.ToString()
}

function Get-CodeServerUser {
    $user = (& wsl -d Ubuntu-24.04 --user root -- bash -lc "getent passwd 1000 | cut -d: -f1" | Out-String).Trim()
    if (-not $user) { return 'root' }
    return $user
}

function Test-Task {
    param([string]$TaskName)
    $state = Get-TaskState $TaskName
    $ok = $state -in @('Ready', 'Running')
    Add-Check 'Task' $TaskName 'Ready or Running' $state $ok
}

function Test-ProcessMatch {
    param(
        [string]$Name,
        [string]$Pattern,
        [string]$Expected = 'Present'
    )
    $proc = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match $Pattern -or ($_.CommandLine -and $_.CommandLine -match $Pattern)
    } | Select-Object -First 1
    $actual = if ($proc) { "PID $($proc.ProcessId)" } else { 'Missing' }
    Add-Check 'Process' $Name $Expected $actual ([bool]$proc)
}

function Test-PortListening {
    param([int]$Port)
    $hit = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {
        $_.LocalPort -eq $Port -and $_.LocalAddress -in @('127.0.0.1', '::1', '0.0.0.0', '::')
    } | Select-Object -First 1
    $actual = if ($hit) { "$($hit.LocalAddress):$Port" } else { 'Not listening' }
    Add-Check 'Port' "$Port" 'Listening' $actual ([bool]$hit)
}

function Invoke-HttpProbe {
    param(
        [string]$Url,
        [int[]]$ExpectedCodes = @(200),
        [hashtable]$Headers = @{}
    )

    $bodyPath = Join-Path $env:TEMP "pcsetup-http-$([guid]::NewGuid().ToString('N')).body"
    $headerPath = Join-Path $env:TEMP "pcsetup-http-$([guid]::NewGuid().ToString('N')).headers"
    try {
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $args = @('-L', '-sS', '--max-time', '25', '-o', $bodyPath, '-D', $headerPath, '-w', '%{http_code}|%{url_effective}')
            foreach ($key in $Headers.Keys) {
                $args += '-H'
                $args += ('{0}: {1}' -f $key, $Headers[$key])
            }
            $args += $Url

            $output = & curl.exe @args
            if ($LASTEXITCODE -eq 0 -and $output) {
                $parts = $output.Trim().Split('|', 2)
                $code = [int]$parts[0]
                $finalUrl = if ($parts.Count -gt 1) { $parts[1] } else { $Url }
                $body = if (Test-Path $bodyPath) { Get-Content $bodyPath -Raw } else { '' }
                $header = if (Test-Path $headerPath) { Get-Content $headerPath -Raw } else { '' }
                $passed = $ExpectedCodes -contains $code
                $detail = "HTTP $code -> $finalUrl"
                if ($code -eq 1033) {
                    $detail += '; Cloudflare tunnel error 1033'
                    $passed = $false
                }

                if ($passed -or $attempt -eq 5) {
                    return [PSCustomObject]@{
                        Code    = $code
                        Url     = $finalUrl
                        Body    = $body
                        Header  = $header
                        Passed  = $passed
                        Detail  = $detail
                    }
                }
            }

            Start-Sleep -Seconds 3
        }

        return [PSCustomObject]@{
            Code    = 0
            Url     = $Url
            Body    = ''
            Header  = ''
            Passed  = $false
            Detail  = "curl exit code $LASTEXITCODE"
        }
    } finally {
        Remove-Item $bodyPath, $headerPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-PublicRoute {
    param(
        [string]$Name,
        [string]$Url,
        [int[]]$ExpectedCodes = @(200)
    )

    $probe = Invoke-HttpProbe -Url $Url -ExpectedCodes $ExpectedCodes
    Add-Check 'Public' $Name (($ExpectedCodes -join ', ')) "HTTP $($probe.Code)" $probe.Passed $probe.Detail
}

function Test-LocalHttp {
    param(
        [string]$Name,
        [string]$Url,
        [hashtable]$Headers = @{}
    )

    $probe = Invoke-HttpProbe -Url $Url -ExpectedCodes @(200) -Headers $Headers
    Add-Check 'LocalHTTP' $Name '200' "HTTP $($probe.Code)" $probe.Passed $probe.Detail
}

function Test-WslHttp {
    param(
        [string]$Name,
        [int]$Port,
        [string]$Path = '/'
    )

    $cmd = "curl -sS --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:${Port}${Path} 2>/dev/null"
    $code = & wsl -d Ubuntu-24.04 --user root -- bash -lc $cmd
    $code = ($code | Out-String).Trim()
    if (-not ($code -as [int])) { $code = '0' }
    $passed = ([int]$code -eq 200)
    Add-Check 'WSLHTTP' $Name '200' "HTTP $code" $passed "http://127.0.0.1:$Port$Path"
}

function Test-WslService {
    param([string]$Service)
    $state = (& wsl -d Ubuntu-24.04 --user root -- bash -lc "systemctl is-active $Service 2>/dev/null || true" | Out-String).Trim()
    if (-not $state) { $state = 'unknown' }
    Add-Check 'WSLService' $Service 'active' $state ($state -eq 'active')
}

function Test-SshwiftyHostTargets {
    if (-not (Test-Path $sshwiftyConf)) {
        Add-Check 'Config' 'SSHwifty SSH host target' 'Config file present' 'Missing' $false $sshwiftyConf
        return
    }

    try {
        $cfg = Get-Content $sshwiftyConf -Raw | ConvertFrom-Json
        $sshPresets = @($cfg.Presets | Where-Object { $_.Type -eq 'SSH' })
        $expected = '127.0.0.1:2222'
        $bad = @($sshPresets | Where-Object { $_.Host -ne $expected })
        $actual = if ($bad.Count -eq 0) { $expected } else { ($bad | Select-Object -First 1).Host }
        $detail = if ($bad.Count -eq 0) {
            "All SSH presets target $expected"
        } else {
            "Expected $expected, found $actual"
        }
        Add-Check 'Config' 'SSHwifty SSH host target' $expected $actual ($bad.Count -eq 0) $detail
    } catch {
        Add-Check 'Config' 'SSHwifty SSH host target' 'Readable JSON' 'Unreadable' $false $_.Exception.Message
    }
}

function Invoke-PublicRoutePlaywrightCheck {
    param([string]$ReportDir)

    $scriptPath = Join-Path $PSScriptRoot 'verify-public-routes.mjs'
    if (-not (Test-Path $scriptPath)) {
        Add-Check 'Public' 'playwright verifier' 'Present' 'Missing' $false 'verify-public-routes.mjs not found'
        return
    }

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCmd) {
        Add-Check 'Public' 'playwright verifier' 'Node installed' 'Missing' $false 'node.exe not found'
        return
    }

    $jsonPath = Join-Path $ReportDir 'public-routes-latest.json'
    Remove-Item $jsonPath -Force -ErrorAction SilentlyContinue

    & node $scriptPath $ReportDir | Out-Null
    $exitCode = $LASTEXITCODE

    if (-not (Test-Path $jsonPath)) {
        Add-Check 'Public' 'playwright verifier' 'Report generated' 'Missing' $false "No public route report at $jsonPath"
        return
    }

    try {
        $report = Get-Content $jsonPath -Raw | ConvertFrom-Json
        foreach ($result in @($report.Results)) {
            $actual = "HTTP $($result.Status) -> $($result.FinalUrl)"
            if ($result.Redirected) {
                $actual += " (redirected $($result.RedirectCount)x)"
            }
            Add-Check 'Public' $result.Name '200 or redirect' $actual ([bool]$result.Passed) $result.Detail
        }
        if ($exitCode -ne 0 -and -not @($report.Results | Where-Object { -not $_.Passed }).Count) {
            Add-Check 'Public' 'playwright exit code' '0' "$exitCode" $false "verify-public-routes.mjs exited $exitCode"
        }
    } catch {
        Add-Check 'Public' 'playwright verifier' 'Readable JSON report' 'Unreadable' $false $_.Exception.Message
    }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "    PCSetup Post-Install Verifier" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[verify-console] Public route checks auto-bootstrap pnpm and Playwright if missing." -ForegroundColor DarkGray
Write-Host ""

# Tasks and processes
@('ffxivbe-tunnel', 'ssh-tunnel', 'web-console', 'UpdateWSLPortProxy') | ForEach-Object { Test-Task $_ }
Test-ProcessMatch -Name 'cloudflared web tunnel' -Pattern 'run ffxivbe-tunnel'
Test-ProcessMatch -Name 'cloudflared ssh tunnel' -Pattern 'run ssh-tunnel'
Test-ProcessMatch -Name 'cloudflared dev tunnel' -Pattern 'cloudflared-dev|dev-config\.yml|dev-console'
Test-ProcessMatch -Name 'SSHwifty' -Pattern 'sshwifty_windows_amd64\.exe'
Test-ProcessMatch -Name 'console proxy' -Pattern 'console-proxy\.js'

# Local origin checks for the web tunnel
Test-LocalHttp -Name 'ffxivbe origin' -Url 'http://127.0.0.1:9000/'
Test-LocalHttp -Name 'chat origin' -Url 'http://127.0.0.1:3000/'

# Console / WSL checks
Test-LocalHttp -Name 'console proxy' -Url 'http://127.0.0.1:7681/' -Headers @{ Host = 'console.ffxivbe.org' }
Test-LocalHttp -Name 'dashboard' -Url 'http://127.0.0.1:7686/'
Test-LocalHttp -Name 'git proxy' -Url 'http://127.0.0.1:7687/'
Test-LocalHttp -Name 'code-server portproxy' -Url 'http://127.0.0.1:8080/'
Test-LocalHttp -Name 'ttyd proxy' -Url 'http://127.0.0.1:7683/'
Test-SshwiftyHostTargets

Test-PortListening -Port 2222
Test-PortListening -Port 7681
Test-PortListening -Port 7683
Test-PortListening -Port 7686
Test-PortListening -Port 7687
Test-PortListening -Port 8080

$codeUser = Get-CodeServerUser
@('ssh', "code-server@$codeUser", 'ttyd-proxy', 'ttyd-persistent', 'ttyd-fresh', 'dashboard', 'ungit', 'git-proxy') | ForEach-Object {
    Test-WslService $_
}

# Public hostnames
Invoke-PublicRoutePlaywrightCheck -ReportDir $ReportDir

# Dev tunnel log file evidence
$cfLogExists = Test-Path $cfLog
$cfPidExists = Test-Path $cfPidFile
Add-Check 'Artifact' 'cloudflared-dev log' 'Present' ($(if ($cfLogExists) { $cfLog } else { 'Missing' })) $cfLogExists
Add-Check 'Artifact' 'cloudflared-dev pid' 'Present' ($(if ($cfPidExists) { $cfPidFile } else { 'Missing' })) $cfPidExists

$failed = @($results | Where-Object { -not $_.Passed })

$summary = [PSCustomObject]@{
    Timestamp = (Get-Date).ToString('o')
    Computer   = $env:COMPUTERNAME
    User       = $env:USERNAME
    Passed     = $results.Count - $failed.Count
    Failed     = $failed.Count
    Results    = $results
}

$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8
Copy-Item $jsonPath $latestJson -Force

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# PCSetup Post-Install Verification Report')
$lines.Add("")
$lines.Add("- Timestamp: " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
$lines.Add("- Computer: $env:COMPUTERNAME")
$lines.Add("- User: $env:USERNAME")
$lines.Add("- Passed: $($summary.Passed)")
$lines.Add("- Failed: $($summary.Failed)")
$lines.Add("")
$lines.Add('| Group | Name | Expected | Actual | Result | Detail |')
$lines.Add('| --- | --- | --- | --- | --- | --- |')
foreach ($r in $results) {
    $resultText = if ($r.Passed) { 'PASS' } else { 'FAIL' }
    $detail = ($r.Detail -replace '\|', '\|')
    $lines.Add("| $($r.Group) | $($r.Name) | $($r.Expected) | $($r.Actual) | $resultText | $detail |")
}
$lines.Add("")
if ($failed.Count -gt 0) {
    $lines.Add('## Failures')
    foreach ($r in $failed) {
        $lines.Add("- [$($r.Group)] $($r.Name): $($r.Detail)")
    }
    $lines.Add("")
}
if (Test-Path $cfLog) {
    $lines.Add("## Cloudflared Dev Log")
    $lines.Add("`$cfLog` exists at `$cfLog`.")
    $lines.Add("")
}
$lines | Set-Content -Path $mdPath -Encoding UTF8
Copy-Item $mdPath $latestMd -Force

Write-Host ""
Write-Host "Report written:" -ForegroundColor Cyan
Write-Host "  $mdPath"
Write-Host "  $jsonPath"
Write-Host ""

$header = "{0,-14} {1,-30} {2,-14} {3,-14} {4}" -f 'Group', 'Name', 'Expected', 'Actual', 'Result'
Write-Host $header -ForegroundColor White
Write-Host ('-' * 90) -ForegroundColor DarkGray
foreach ($r in $results) {
    $color = if ($r.Passed) { 'Green' } else { 'Red' }
    $result = if ($r.Passed) { 'PASS' } else { 'FAIL' }
    $line = "{0,-14} {1,-30} {2,-14} {3,-14} {4}" -f $r.Group, $r.Name, $r.Expected, $r.Actual, $result
    Write-Host $line -ForegroundColor $color
}

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "All $($results.Count) checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($failed.Count) of $($results.Count) checks failed." -ForegroundColor Red
    exit 1
}
