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
        [string]$IpCidr,
        [int]$Precedence = 0
    )

    $body = @{
        name       = $Name
        decision   = 'bypass'
        precedence = $Precedence
        include    = @(
            @{
                ip = @{
                    ip = $IpCidr
                }
            }
        )
    }

    return Invoke-CloudflareApi -RepoRoot $RepoRoot -Method POST -Path "/accounts/$AccountId/access/apps/$AppId/policies" -Body $body
}
