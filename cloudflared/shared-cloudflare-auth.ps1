function Read-RepoSecret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $candidateRoots = @($RepoRoot, (Split-Path -Parent $RepoRoot)) | Where-Object { $_ } | Select-Object -Unique
    $secretsPath = $null
    foreach ($root in $candidateRoots) {
        $candidate = Join-Path $root '.secrets'
        if (Test-Path $candidate) {
            $secretsPath = $candidate
            break
        }
    }
    if (-not $secretsPath) {
        throw ".secrets not found at any of: $($candidateRoots -join ', ')"
    }

    $line = Get-Content $secretsPath | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if (-not $line) {
        throw "Secret '$Key' not found in .secrets"
    }

    return ($line -replace "^$Key=", '').Trim()
}

function Ensure-CloudflareCertPem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $pemB64 = Read-RepoSecret -Key 'FFXIVBE_PEM_B64' -RepoRoot $RepoRoot
    if (-not $pemB64 -or $pemB64 -eq 'replace_me') {
        throw "FFXIVBE_PEM_B64 is missing or placeholder in .secrets."
    }

    $pemBytes = [Convert]::FromBase64String($pemB64)
    $cfDir = Join-Path $env:USERPROFILE '.cloudflared'
    New-Item -ItemType Directory -Path $cfDir -Force | Out-Null

    $certPath = Join-Path $cfDir 'cert.pem'
    $legacyPath = Join-Path $cfDir 'ffxivbe.pem'
    [IO.File]::WriteAllBytes($certPath, $pemBytes)
    [IO.File]::WriteAllBytes($legacyPath, $pemBytes)

    return $certPath
}

function Invoke-CloudflaredDnsRoute {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CloudflaredPath,
        [Parameter(Mandatory = $true)]
        [string]$TunnelName,
        [Parameter(Mandatory = $true)]
        [string[]]$Hostnames
    )

    foreach ($hostname in @($Hostnames | Select-Object -Unique)) {
        if (-not $hostname) { continue }
        $stdoutPath = Join-Path $env:TEMP ("cloudflared-route-" + [Guid]::NewGuid().ToString('N') + ".out")
        $stderrPath = Join-Path $env:TEMP ("cloudflared-route-" + [Guid]::NewGuid().ToString('N') + ".err")
        Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

        $args = @('tunnel', 'route', 'dns', '--overwrite-dns', $TunnelName, $hostname)
        $process = Start-Process -FilePath $CloudflaredPath -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stderr = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw } else { '' }
        $stdout = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -Raw } else { '' }
        Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

        if ($process.ExitCode -ne 0) {
            throw "cloudflared tunnel route dns failed for $hostname (exit $($process.ExitCode)): $stderr$stdout"
        }
    }
}

function Invoke-CloudflareApi {
    param(
        [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object]$Body = $null
    )

    $token = Read-RepoSecret -Key 'CLOUDFLARE_ACCOUNT_API_TOKEN' -RepoRoot $RepoRoot
    if (-not $token -or $token -eq 'replace_me') {
        throw "CLOUDFLARE_ACCOUNT_API_TOKEN is missing or placeholder in .secrets."
    }

    $headers = @{ Authorization = "Bearer $token" }
    $params = @{
        Uri     = "https://api.cloudflare.com/client/v4$Path"
        Headers = $headers
        Method  = $Method
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
        $params.ContentType = 'application/json'
    }

    $response = Invoke-RestMethod @params
    if ($null -eq $response.success -or -not $response.success) {
        $errors = if ($response.errors) { ($response.errors | ConvertTo-Json -Depth 8 -Compress) } else { 'unknown error' }
        throw "Cloudflare API $Method $Path failed: $errors"
    }

    return $response.result
}

function Get-CloudflareCurrentPublicIp {
    $response = Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -Method Get
    if (-not $response.ip) {
        throw "Could not determine the current public IP address."
    }

    return $response.ip.Trim()
}

function Convert-PublicIpToCidr {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ip
    )

    $cleanIp = $Ip.Trim()
    if ($cleanIp -match ':') {
        return "$cleanIp/128"
    }

    return "$cleanIp/32"
}

function Get-CloudflareCurrentPublicIpCidrs {
    $ips = New-Object System.Collections.Generic.List[string]

    foreach ($uri in @(
        'https://api.ipify.org?format=json',
        'https://api64.ipify.org?format=json'
    )) {
        try {
            $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20
            if ($response.ip) {
                $ips.Add([string]$response.ip) | Out-Null
            }
        } catch {
            Write-Warning "Could not determine public IP from $uri`: $_"
        }
    }

    try {
        $trace = Invoke-RestMethod -Uri 'https://www.cloudflare.com/cdn-cgi/trace' -Method Get -TimeoutSec 20
        $traceIp = ($trace -split "`n" | Where-Object { $_ -match '^ip=' } | Select-Object -First 1) -replace '^ip=', ''
        if ($traceIp) {
            $ips.Add($traceIp) | Out-Null
        }
    } catch {
        Write-Warning "Could not determine public IP from Cloudflare trace: $_"
    }

    try {
        $curlTrace = & curl.exe --silent --show-error --max-time 20 'https://www.cloudflare.com/cdn-cgi/trace' 2>$null
        $curlTraceIp = ($curlTrace -split "`n" | Where-Object { $_ -match '^ip=' } | Select-Object -First 1) -replace '^ip=', ''
        if ($curlTraceIp) {
            $ips.Add($curlTraceIp) | Out-Null
        }
    } catch {
        Write-Warning "Could not determine public IP from curl Cloudflare trace: $_"
    }

    $playwrightModule = Join-Path $PSScriptRoot 'node_modules\playwright'
    if ((Get-Command node -ErrorAction SilentlyContinue) -and (Test-Path $playwrightModule)) {
        $scriptPath = Join-Path $env:TEMP ("cloudflare-trace-playwright-" + [Guid]::NewGuid().ToString('N') + ".js")
        $script = @"
const { chromium } = require(String.raw`$playwrightModule`);
(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-proxy-server', '--proxy-server=direct://', '--proxy-bypass-list=*']
  });
  try {
    const page = await browser.newPage();
    await page.goto('https://www.cloudflare.com/cdn-cgi/trace', { waitUntil: 'domcontentloaded', timeout: 30000 });
    console.log(await page.locator('body').innerText());
  } finally {
    await browser.close();
  }
})().catch(error => {
  console.error(error && error.message ? error.message : String(error));
  process.exit(1);
});
"@
        try {
            Set-Content -Path $scriptPath -Value $script -Encoding UTF8
            $playwrightTrace = & node $scriptPath 2>$null
            $playwrightTraceIp = ($playwrightTrace -split "`n" | Where-Object { $_ -match '^ip=' } | Select-Object -First 1) -replace '^ip=', ''
            if ($playwrightTraceIp) {
                $ips.Add($playwrightTraceIp) | Out-Null
            }
        } catch {
            Write-Warning "Could not determine public IP from Playwright Cloudflare trace: $_"
        } finally {
            Remove-Item $scriptPath -ErrorAction SilentlyContinue
        }
    }

    $cidrs = @(
        $ips |
            Where-Object { $_ } |
            ForEach-Object { Convert-PublicIpToCidr -Ip $_ } |
            Select-Object -Unique
    )

    if (-not $cidrs) {
        throw "Could not determine any current public IP CIDR."
    }

    return $cidrs
}

function Get-CloudflareAccessApps {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$AccountId
    )

    $response = Invoke-CloudflareApi -RepoRoot $RepoRoot -Method GET -Path "/accounts/$AccountId/access/apps?per_page=100"
    if ($response -is [System.Array]) {
        return $response
    }

    if ($response.PSObject.Properties.Name -contains 'result') {
        return @($response.result)
    }

    return @($response)
}

function Remove-CloudflareAccessPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$AccountId,
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [Parameter(Mandatory = $true)]
        [string]$PolicyId
    )

    $null = Invoke-CloudflareApi -RepoRoot $RepoRoot -Method DELETE -Path "/accounts/$AccountId/access/apps/$AppId/policies/$PolicyId"
}

function New-CloudflareAccessPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$AccountId,
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string[]]$IpCidr,
        [int]$Precedence = 0
    )

    $includeRules = @(
        $IpCidr |
            Where-Object { $_ } |
            Select-Object -Unique |
            ForEach-Object {
                @{
                    ip = @{
                        ip = $_
                    }
                }
            }
    )

    $body = @{
        name       = $Name
        decision   = 'bypass'
        precedence = $Precedence
        include    = $includeRules
    }

    return Invoke-CloudflareApi -RepoRoot $RepoRoot -Method POST -Path "/accounts/$AccountId/access/apps/$AppId/policies" -Body $body
}

function New-CloudflareEveryoneBypassPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$AccountId,
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [int]$Precedence = 1
    )

    $body = @{
        name       = $Name
        decision   = 'bypass'
        precedence = $Precedence
        include    = @(
            @{
                everyone = @{}
            }
        )
    }

    return Invoke-CloudflareApi -RepoRoot $RepoRoot -Method POST -Path "/accounts/$AccountId/access/apps/$AppId/policies" -Body $body
}
