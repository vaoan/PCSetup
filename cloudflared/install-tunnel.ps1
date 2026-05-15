# Cloudflare Tunnel Auto-Installer
# Run this script to automatically set up the tunnel
# Automatically elevates to Administrator if needed

$ErrorActionPreference = "Stop"

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
if (Test-Path $cloudflaredPath) {
    $cfVersion = & $cloudflaredPath --version 2>&1
    Write-Host "  OK Cloudflared: $cfVersion" -ForegroundColor Green
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
        $cfVersion = & $cloudflaredPath --version 2>&1
        Write-Host "  OK Cloudflared installed: $cfVersion" -ForegroundColor Green
    } else {
        Write-Host "  X Failed to install cloudflared" -ForegroundColor Red
        exit 1
    }
}

# Step 2: Cloudflare authentication
Write-Host ""
Write-Host "[2/5] Cloudflare authentication..." -ForegroundColor Yellow
Write-Host "  Opening browser for authentication..." -ForegroundColor Gray
& $cloudflaredPath tunnel login
if ($LASTEXITCODE -ne 0) {
    Write-Host "  X Authentication failed" -ForegroundColor Red
    exit 1
}
Write-Host "  OK Authenticated" -ForegroundColor Green

# Step 3: Create or reuse tunnel
Write-Host ""
Write-Host "[3/5] Setting up tunnel..." -ForegroundColor Yellow
$tunnelId = "c552cb9c-62bd-4c8b-9ec6-16627b1b8af3"
$tunnelName = "ffxivbe-tunnel"

# Check if tunnel exists
$tunnelList = & $cloudflaredPath tunnel list 2>&1
if ($tunnelList -match $tunnelId) {
    Write-Host "  OK Tunnel exists: $tunnelId" -ForegroundColor Green
} else {
    Write-Host "  Creating new tunnel..." -ForegroundColor Gray
    $createOutput = & $cloudflaredPath tunnel create $tunnelName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X Failed to create tunnel" -ForegroundColor Red
        Write-Host "  Output: $createOutput" -ForegroundColor Gray
        exit 1
    }
    # Extract tunnel ID from output
    if ($createOutput -match "([a-f0-9-]{36})") {
        $tunnelId = $matches[1]
        Write-Host "  OK Tunnel created: $tunnelId" -ForegroundColor Green
    } else {
        Write-Host "  WARNING Could not extract tunnel ID, using default" -ForegroundColor Yellow
    }
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

ingress:
  - hostname: ffxivbe.org
    service: http://127.0.0.1:7542
  - hostname: www.ffxivbe.org
    service: http://127.0.0.1:7542
  - hostname: chat.ffxivbe.org
    service: http://192.168.2.6:3000
  - hostname: landing.ffxivbe.org
    service: http://127.0.0.1:7542
  - hostname: auth.ffxivbe.org
    service: http://127.0.0.1:7542
  - hostname: store.ffxivbe.org
    service: http://127.0.0.1:7542
  - hostname: admin.ffxivbe.org
    service: http://127.0.0.1:7542
  - hostname: payments.ffxivbe.org
    service: http://127.0.0.1:7542
  - hostname: playground.ffxivbe.org
    service: http://127.0.0.1:7542
  - hostname: studio.ffxivbe.org
    service: http://127.0.0.1:7542
  - hostname: supabase.ffxivbe.org
    service: http://127.0.0.1:64321
  - hostname: supabase-studio.ffxivbe.org
    service: http://127.0.0.1:64323
  - hostname: mailpit.ffxivbe.org
    service: http://127.0.0.1:64324
  - service: http_status:404
"@

Set-Content -Path $configPath -Value $configContent
Write-Host "  OK Config created: $configPath" -ForegroundColor Green

# Verify credentials file exists, if not generate from token
if (-not (Test-Path $credentialsPath)) {
    Write-Host "  Credentials file not found, generating from tunnel token..." -ForegroundColor Gray

    # Get tunnel token
    $token = & $cloudflaredPath tunnel token $tunnelName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X Failed to get tunnel token" -ForegroundColor Red
        Write-Host "  Output: $token" -ForegroundColor Gray
        exit 1
    }

    # Decode base64 token to get credentials
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

# Step 4: Create scheduled task
Write-Host ""
Write-Host "[4/5] Creating scheduled task..." -ForegroundColor Yellow

$taskName = "ffxivbe-tunnel"

# Remove existing task if present
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# Create task - runs cloudflared directly via PowerShell hidden window
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -Command `"& '$cloudflaredPath' tunnel --config '$configPath' run ffxivbe-tunnel`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -Hidden
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Cloudflare Tunnel for ffxivbe.org (silent)" | Out-Null
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
Write-Host "  - Make sure your local service is running on port 9000" -ForegroundColor Gray
Write-Host "  - Test: https://ffxivbe.org" -ForegroundColor Gray
Write-Host "  - Toggle tunnel: Double-click 'Toggle Tunnel' on desktop" -ForegroundColor Gray
Write-Host "  - Or run: toggle-tunnel.bat" -ForegroundColor Gray
Write-Host ""
