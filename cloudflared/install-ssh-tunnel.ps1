# SSH Tunnel Auto-Installer
# Run this script to automatically set up SSH remote access via Cloudflare Tunnel
# Automatically elevates to Administrator if needed

param(
    [string]$MacPublicKey = ""
)

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

    if ($MacPublicKey) {
        $arguments += " -MacPublicKey `"$MacPublicKey`""
    }

    Start-Process powershell -Verb RunAs -ArgumentList $arguments -Wait
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SSH Tunnel Auto-Installer" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Configuration
$sshTunnelId = "8dffdb51-77cc-43ca-8dc8-8a0c720607a5"
$sshTunnelName = "ssh-tunnel"
$sshHostname = "pc.ffxivbe.org"

# Step 1: Check/Install cloudflared
Write-Host "[1/6] Checking cloudflared..." -ForegroundColor Yellow

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

# Step 2: Install OpenSSH Server
Write-Host ""
Write-Host "[2/6] Installing OpenSSH Server..." -ForegroundColor Yellow

$sshCapability = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'

if ($sshCapability.State -eq "Installed") {
    Write-Host "  OK OpenSSH Server already installed" -ForegroundColor Green
} else {
    Write-Host "  Installing OpenSSH Server..." -ForegroundColor Gray
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X Failed to install OpenSSH Server" -ForegroundColor Red
        exit 1
    }
    Write-Host "  OK OpenSSH Server installed" -ForegroundColor Green
}

# Configure and start SSH service
Write-Host "  Configuring SSH service..." -ForegroundColor Gray
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Automatic
Write-Host "  OK SSH service running and set to auto-start" -ForegroundColor Green

# Configure firewall for all network profiles
Write-Host "  Configuring firewall..." -ForegroundColor Gray
$firewallRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($firewallRule) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Profile Any
    Write-Host "  OK Firewall rule updated for all profiles" -ForegroundColor Green
} else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any
    Write-Host "  OK Firewall rule created" -ForegroundColor Green
}

# Step 3: Check/Create SSH Tunnel
Write-Host ""
Write-Host "[3/6] Setting up SSH tunnel..." -ForegroundColor Yellow

# Check if tunnel exists
$tunnelListResult = Invoke-CloudflareApi -Method GET -Path "/accounts/$accountId/cfd_tunnel"
$existingTunnel = @($tunnelListResult | Where-Object { $_.name -eq $sshTunnelName -and -not $_.deleted_at } | Select-Object -First 1)
if ($existingTunnel) {
    $sshTunnelId = $existingTunnel.id
    Write-Host "  OK Tunnel exists: $sshTunnelId" -ForegroundColor Green
} else {
    Write-Host "  Creating new tunnel..." -ForegroundColor Gray
    $createResult = Invoke-CloudflareApi -Method POST -Path "/accounts/$accountId/cfd_tunnel" -Body @{ name = $sshTunnelName }
    $sshTunnelId = $createResult.id
    Write-Host "  OK Tunnel created: $sshTunnelId" -ForegroundColor Green
}

# Step 4: Create SSH config file
Write-Host ""
Write-Host "[4/6] Creating SSH tunnel configuration..." -ForegroundColor Yellow

$configDir = Join-Path $env:USERPROFILE ".cloudflared"
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

$sshConfigPath = Join-Path $configDir "ssh-config.yml"
$credentialsPath = Join-Path $configDir "$sshTunnelId.json"
$tokenOutputPath = Join-Path $env:TEMP "cloudflared-ssh-token.out"
$tokenErrorPath = Join-Path $env:TEMP "cloudflared-ssh-token.err"

$sshConfigContent = @"
tunnel: $sshTunnelId
credentials-file: $credentialsPath
protocol: http2

ingress:
  - hostname: $sshHostname
    service: ssh://localhost:22
  - service: http_status:404
"@

Set-Content -Path $sshConfigPath -Value $sshConfigContent
Write-Host "  OK Config created: $sshConfigPath" -ForegroundColor Green

# Verify credentials file exists, if not generate from token
if (-not (Test-Path $credentialsPath)) {
    Write-Host "  Credentials file not found, generating from tunnel token..." -ForegroundColor Gray
    $tokenResponse = Invoke-CloudflareApi -Method GET -Path "/accounts/$accountId/cfd_tunnel/$sshTunnelId/token"
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

try {
    Write-Host "  Ensuring Cloudflare cert.pem from .secrets..." -ForegroundColor Gray
    $null = Ensure-CloudflareCertPem -RepoRoot (Split-Path -Parent $PSScriptRoot)
    Write-Host "  OK cert.pem ready" -ForegroundColor Green

    Write-Host "  Provisioning DNS route..." -ForegroundColor Gray
    Invoke-CloudflaredDnsRoute -CloudflaredPath $cloudflaredPath -TunnelName $sshTunnelId -Hostnames @($sshHostname)
    Write-Host "  OK DNS route provisioned" -ForegroundColor Green
} catch {
    Write-Host "  X DNS route provisioning failed: $_" -ForegroundColor Red
    exit 1
}

# Step 5: Create scheduled task
Write-Host ""
Write-Host "[5/6] Creating scheduled task..." -ForegroundColor Yellow

$taskName = "ssh-tunnel"
$launcherPath = Join-Path $configDir "ssh-tunnel-launcher.vbs"

# Remove existing task if present
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

# Create a hidden VBS launcher so no console window appears
$launcherContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run Chr(34) & "$cloudflaredPath" & Chr(34) & " tunnel --config " & Chr(34) & "$sshConfigPath" & Chr(34) & " run $sshTunnelName", 0, False
"@
Set-Content -Path $launcherPath -Value $launcherContent

$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$launcherPath`""
$triggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -Hidden -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Description "SSH Tunnel for $sshHostname (boot-started)" | Out-Null
Write-Host "  OK Scheduled task installed: $taskName" -ForegroundColor Green

# Start task
Start-ScheduledTask -TaskName $taskName
Write-Host "  OK Task started" -ForegroundColor Green

# Create desktop shortcut for SSH tunnel toggle
Write-Host "  Creating desktop shortcut..." -ForegroundColor Gray
$desktop = if (Test-Path "$env:USERPROFILE\OneDrive\Desktop") {
    "$env:USERPROFILE\OneDrive\Desktop"
} elseif (Test-Path "$env:USERPROFILE\Desktop") {
    "$env:USERPROFILE\Desktop"
} else {
    [Environment]::GetFolderPath("Desktop")
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$togglePath = Join-Path $scriptDir "toggle-ssh-tunnel.bat"

if (Test-Path $togglePath) {
    $ws = New-Object -ComObject WScript.Shell
    $shortcut = $ws.CreateShortcut("$desktop\Toggle SSH Tunnel.lnk")
    $shortcut.TargetPath = $togglePath
    $shortcut.WorkingDirectory = $scriptDir
    $shortcut.IconLocation = "shell32.dll,144"
    $shortcut.Description = "Toggle SSH Tunnel (Start/Stop)"
    $shortcut.Save()
    Write-Host "  OK Desktop shortcut created" -ForegroundColor Green
}

# Step 6: SSH Key setup (optional)
Write-Host ""
Write-Host "[6/6] SSH Key Authentication..." -ForegroundColor Yellow

$adminKeysPath = "C:\ProgramData\ssh\administrators_authorized_keys"

if ($MacPublicKey) {
    Write-Host "  Setting up SSH key..." -ForegroundColor Gray

    # Create ProgramData\ssh directory if needed
    $sshDir = "C:\ProgramData\ssh"
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }

    # Write the public key
    Set-Content -Path $adminKeysPath -Value $MacPublicKey

    # Set correct permissions
    icacls $adminKeysPath /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null

    # Restart SSH service
    Restart-Service sshd

    Write-Host "  OK SSH key configured" -ForegroundColor Green
} else {
    if (Test-Path $adminKeysPath) {
        Write-Host "  OK SSH key already configured" -ForegroundColor Green
    } else {
        Write-Host "  SKIPPED No SSH key provided" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  To set up key authentication later:" -ForegroundColor Gray
        Write-Host "  1. On Mac: cat ~/.ssh/id_ed25519.pub" -ForegroundColor Gray
        Write-Host "  2. Run this script again with: -MacPublicKey 'ssh-ed25519 AAAA...'" -ForegroundColor Gray
        Write-Host "  Or manually add key to: $adminKeysPath" -ForegroundColor Gray
    }
}

# Final summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installation Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Waiting 15 seconds for tunnel to connect..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

# Check tunnel status
$taskStatus = (Get-ScheduledTask -TaskName $taskName).State
Write-Host ""
Write-Host "SSH Tunnel Status: $taskStatus" -ForegroundColor Cyan
Write-Host ""

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Cloudflare DNS route provisioned headlessly." -ForegroundColor Green
Write-Host "No dashboard step is required for the tunnel itself." -ForegroundColor Green
Write-Host "If you manage Access/WAF separately, keep that in your Cloudflare automation." -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "To connect from Mac:" -ForegroundColor Cyan
Write-Host "  ssh windows-remote" -ForegroundColor White
Write-Host ""
Write-Host "(Requires ~/.ssh/config with ProxyCommand setup - see SETUP_GUIDE.md)" -ForegroundColor Gray
Write-Host ""
