# Cloudflare Tunnel Auto-Installer
# Run this script to automatically set up the tunnel
# Automatically elevates to Administrator if needed

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$accountId = 'd34896e6a0f8b2fba5e03dec659eac50'

function Read-Secret {
    param([string]$Key)
    $secretsPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.secrets'
    if (-not (Test-Path $secretsPath)) { throw ".secrets not found at $secretsPath" }
    $line = Get-Content $secretsPath | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if (-not $line) { throw "Secret '$Key' not found in .secrets" }
    return ($line -replace "^$Key=", '').Trim()
}

function Invoke-CloudflareApi {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object]$Body = $null
    )

    $token = Read-Secret 'CLOUDFLARE_ACCOUNT_API_TOKEN'
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

. (Join-Path $PSScriptRoot 'shared-cloudflare-auth.ps1')

# Check if running as Administrator, if not, restart with elevation
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "Elevating to Administrator..." -ForegroundColor Yellow
    Write-Host ""

    $scriptPath = $MyInvocation.MyCommand.Path
    $arguments = "-ExecutionPolicy Bypass -File `"$scriptPath`""

    Start-Process powershell -Verb RunAs -ArgumentList $arguments -Wait
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Cloudflare Tunnel Auto-Installer" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Check/Install cloudflared
Write-Host "[1/5] Checking cloudflared..." -ForegroundColor Yellow

# MUST use official MSI path (not Chocolatey) for Smart App Control compatibility
$cloudflaredPath = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'

function Invoke-CloudflaredCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $stdoutPath = Join-Path $env:TEMP "cloudflared-command.out"
    $stderrPath = Join-Path $env:TEMP "cloudflared-command.err"
    Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath $cloudflaredPath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $stdout = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -Raw } else { "" }

    Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output   = $stdout
    }
}

if (Test-Path $cloudflaredPath) {
    $cfVersionResult = Invoke-CloudflaredCommand -Arguments @('--version')
    Write-Host "  OK Cloudflared: $($cfVersionResult.Output.Trim())" -ForegroundColor Green
} else {
    Write-Host "  Cloudflared not found, installing from official MSI..." -ForegroundColor Yellow
    Write-Host "  (Using official MSI for Smart App Control compatibility)" -ForegroundColor Gray

    $msiUrl = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi'
    $msiPath = "$env:TEMP\cloudflared.msi"

    Write-Host "  Downloading..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath

    Write-Host "  Installing..." -ForegroundColor Gray
    Start-Process msiexec.exe -ArgumentList '/i', $msiPath, '/quiet', '/norestart' -Wait

    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue

    if (Test-Path $cloudflaredPath) {
        $cfVersionResult = Invoke-CloudflaredCommand -Arguments @('--version')
        Write-Host "  OK Cloudflared installed: $($cfVersionResult.Output.Trim())" -ForegroundColor Green
    } else {
        Write-Host "  X Failed to install cloudflared" -ForegroundColor Red
        exit 1
    }
}

# Step 2: Create or reuse tunnel
Write-Host ""
Write-Host "[2/5] Setting up tunnel..." -ForegroundColor Yellow
$tunnelId = "c552cb9c-62bd-4c8b-9ec6-16627b1b8af3"
$tunnelName = "ffxivbe-tunnel"

# Check if tunnel exists
$tunnelListResult = Invoke-CloudflareApi -Method GET -Path "/accounts/$accountId/cfd_tunnel"
$existingTunnel = @($tunnelListResult | Where-Object { $_.name -eq $tunnelName -and -not $_.deleted_at } | Select-Object -First 1)
if ($existingTunnel) {
    $tunnelId = $existingTunnel.id
    Write-Host "  OK Tunnel exists: $tunnelId" -ForegroundColor Green
} else {
    Write-Host "  Creating new tunnel..." -ForegroundColor Gray
    $createResult = Invoke-CloudflareApi -Method POST -Path "/accounts/$accountId/cfd_tunnel" -Body @{ name = $tunnelName }
    $tunnelId = $createResult.id
    Write-Host "  OK Tunnel created: $tunnelId" -ForegroundColor Green
}

# Create config file
Write-Host "  Creating tunnel configuration..." -ForegroundColor Gray
$configDir = Join-Path $env:USERPROFILE ".cloudflared"
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

$configPath = Join-Path $configDir "config.yml"
$credentialsPath = Join-Path $configDir "$tunnelId.json"
$configContent = @"
tunnel: $tunnelId
credentials-file: $credentialsPath
protocol: http2

# The ffxiv.be apex is NOT routed here - it belongs to the ffxiv-be-shortener
# Worker. The web stack lives on www.ffxiv.be.
ingress:
  - hostname: www.ffxiv.be
    service: http://127.0.0.1:9000
  - hostname: chat.ffxiv.be
    service: http://127.0.0.1:3000
  - service: http_status:404
"@

Set-Content -Path $configPath -Value $configContent
Write-Host "  OK Config created: $configPath" -ForegroundColor Green

# Verify credentials file exists, if not generate from token
if (-not (Test-Path $credentialsPath)) {
    Write-Host "  Credentials file not found, generating from tunnel token..." -ForegroundColor Gray
    $tokenResponse = Invoke-CloudflareApi -Method GET -Path "/accounts/$accountId/cfd_tunnel/$tunnelId/token"
    $token = if ($tokenResponse.PSObject.Properties.Name -contains 'token') { $tokenResponse.token } else { $tokenResponse }
    try {
        $tokenJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($token.Trim()))
        $tokenData = $tokenJson | ConvertFrom-Json

        # Create credentials JSON
        $credentials = @{
            AccountTag = $tokenData.a
            TunnelSecret = $tokenData.s
            TunnelID = $tokenData.t
        } | ConvertTo-Json

        Set-Content -Path $credentialsPath -Value $credentials
        Write-Host "  OK Credentials file created: $credentialsPath" -ForegroundColor Green
    } catch {
        Write-Host "  X Failed to decode tunnel token: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "  OK Credentials file exists: $credentialsPath" -ForegroundColor Green
}

# Provision DNS routes headlessly from the stored Cloudflare tunnel auth bundle.
try {
    Write-Host "  Ensuring Cloudflare cert.pem from .secrets..." -ForegroundColor Gray
    $null = Ensure-CloudflareCertPem -RepoRoot (Split-Path -Parent $PSScriptRoot)
    Write-Host "  OK cert.pem ready" -ForegroundColor Green

    Write-Host "  Provisioning DNS routes..." -ForegroundColor Gray
    Invoke-CloudflaredDnsRoute -CloudflaredPath $cloudflaredPath -TunnelName $tunnelId -Hostnames @(
        'www.ffxiv.be',
        'chat.ffxiv.be'
    )
    Write-Host "  OK DNS routes provisioned" -ForegroundColor Green
} catch {
    Write-Host "  X DNS route provisioning failed: $_" -ForegroundColor Red
    exit 1
}

# Step 4: Create scheduled task
Write-Host ""
Write-Host "[4/5] Creating scheduled task..." -ForegroundColor Yellow

$taskName = "ffxivbe-tunnel"
$launcherPath = Join-Path $configDir "ffxivbe-tunnel-launcher.vbs"

# Remove existing task if present
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# Create a hidden VBS launcher so no console window appears
$launcherContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run Chr(34) & "$cloudflaredPath" & Chr(34) & " tunnel --config " & Chr(34) & "$configPath" & Chr(34) & " run ffxivbe-tunnel", 0, False
"@
Set-Content -Path $launcherPath -Value $launcherContent

$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$launcherPath`""
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -Hidden -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Description "Cloudflare Tunnel for ffxivbe.org (silent, boot-started)" | Out-Null
Write-Host "  OK Scheduled task installed" -ForegroundColor Green

# Start task
Start-ScheduledTask -TaskName $taskName
Write-Host "  OK Task started" -ForegroundColor Green

# Step 5: Create shortcuts
Write-Host ""
Write-Host "[5/5] Creating desktop shortcuts..." -ForegroundColor Yellow
$shortcutScript = Join-Path $PSScriptRoot "create-shortcuts.ps1"
if (Test-Path $shortcutScript) {
    powershell -ExecutionPolicy Bypass -File $shortcutScript
    Write-Host "  OK Shortcuts created" -ForegroundColor Green
} else {
    Write-Host "  SKIP create-shortcuts.ps1 not found" -ForegroundColor Yellow
}

# Final summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Waiting 15 seconds for tunnel to connect..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

# Check task status
$taskStatus = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
Write-Host ""
Write-Host "Tunnel Status: $taskStatus" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  - Make sure the local web stack is running on 9000 and 3000 as needed" -ForegroundColor Gray
Write-Host "  - Test: https://www.ffxiv.be, https://chat.ffxiv.be" -ForegroundColor Gray
Write-Host "  - Toggle tunnel: Double-click 'Toggle Tunnel' on desktop" -ForegroundColor Gray
Write-Host "  - Or run: toggle-tunnel.bat" -ForegroundColor Gray
Write-Host ""
