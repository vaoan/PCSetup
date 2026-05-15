# ============================================================================
# POST-FORMAT RECOVERY SCRIPT
# ============================================================================
# Run this script after formatting your PC to restore everything:
# - Cloudflared (official MSI for Smart App Control)
# - Web tunnel (ffxivbe.org -> localhost:9000)
# - SSH tunnel (pc.ffxivbe.org -> SSH access)
# - Dev tunnel (dev.ffxivbe.org -> VS Code Remote SSH)
# - OpenSSH Server with key authentication
# - Scheduled tasks (all run silently)
# - Desktop shortcuts
#
# Usage: Right-click -> Run with PowerShell (will auto-elevate to Admin)
# ============================================================================

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION - Update these if IDs change
# ============================================================================
$webTunnelId = "c552cb9c-62bd-4c8b-9ec6-16627b1b8af3"
$webTunnelName = "ffxivbe-tunnel"
$webHostname = "ffxivbe.org"

$sshTunnelId = "8dffdb51-77cc-43ca-8dc8-8a0c720607a5"
$sshTunnelName = "ssh-tunnel"
$sshHostname = "pc.ffxivbe.org"

# Dev tunnel ID is dynamic - looked up from Cloudflare during recovery
$devTunnelName = "dev-tunnel"
$devHostname = "dev.ffxivbe.org"

$macPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho heinerangarita@Heiners-MacBook-Air.local"

$cloudflaredPath = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'

# ============================================================================
# AUTO-ELEVATE TO ADMINISTRATOR
# ============================================================================
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

# ============================================================================
# SCRIPT START
# ============================================================================
Clear-Host
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "    POST-FORMAT RECOVERY SCRIPT" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This will install and configure:" -ForegroundColor White
Write-Host "  - Cloudflared (official MSI)" -ForegroundColor Gray
Write-Host "  - Web tunnel: $webHostname" -ForegroundColor Gray
Write-Host "  - SSH tunnel: $sshHostname" -ForegroundColor Gray
Write-Host "  - Dev tunnel: $devHostname (VS Code Remote SSH)" -ForegroundColor Gray
Write-Host "  - OpenSSH Server + key auth" -ForegroundColor Gray
Write-Host "  - Silent scheduled tasks" -ForegroundColor Gray
Write-Host "  - Desktop shortcuts" -ForegroundColor Gray
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path $env:USERPROFILE ".cloudflared"

# ============================================================================
# STEP 1: Install Cloudflared
# ============================================================================
Write-Host "[1/9] Installing Cloudflared..." -ForegroundColor Yellow

if (Test-Path $cloudflaredPath) {
    $cfVersion = & $cloudflaredPath --version 2>&1
    Write-Host "  OK Already installed: $cfVersion" -ForegroundColor Green
} else {
    Write-Host "  Downloading official MSI (for Smart App Control)..." -ForegroundColor Gray

    $msiUrl = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi'
    $msiPath = "$env:TEMP\cloudflared.msi"

    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath

    Write-Host "  Installing..." -ForegroundColor Gray
    Start-Process msiexec.exe -ArgumentList '/i', $msiPath, '/quiet', '/norestart' -Wait

    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue

    if (Test-Path $cloudflaredPath) {
        $cfVersion = & $cloudflaredPath --version 2>&1
        Write-Host "  OK Installed: $cfVersion" -ForegroundColor Green
    } else {
        Write-Host "  X Failed to install cloudflared" -ForegroundColor Red
        Write-Host "  Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }
}

# ============================================================================
# STEP 2: Cloudflare Authentication
# ============================================================================
Write-Host ""
Write-Host "[2/9] Cloudflare Authentication..." -ForegroundColor Yellow

# Check if cert.pem exists (indicates already authenticated)
$certPath = Join-Path $configDir "cert.pem"
if (Test-Path $certPath) {
    Write-Host "  OK Already authenticated (cert.pem exists)" -ForegroundColor Green
} else {
    Write-Host "  Opening browser for authentication..." -ForegroundColor Gray
    Write-Host "  (Complete login in your browser)" -ForegroundColor Gray
    & $cloudflaredPath tunnel login
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X Authentication failed" -ForegroundColor Red
        Write-Host "  Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }
    Write-Host "  OK Authenticated" -ForegroundColor Green
}

# Create config directory if needed
if (-not (Test-Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

# ============================================================================
# STEP 3: Setup Web Tunnel Config
# ============================================================================
Write-Host ""
Write-Host "[3/9] Setting up Web Tunnel ($webHostname)..." -ForegroundColor Yellow

$webConfigPath = Join-Path $configDir "config.yml"
$webCredentialsPath = Join-Path $configDir "$webTunnelId.json"

# Create config file
$webConfigContent = @"
tunnel: $webTunnelId
credentials-file: $webCredentialsPath
protocol: http2

ingress:
  - hostname: $webHostname
    service: http://127.0.0.1:9000
  - hostname: www.$webHostname
    service: http://127.0.0.1:9000
  - hostname: landing.$webHostname
    service: http://127.0.0.1:5004
  - hostname: auth.$webHostname
    service: http://127.0.0.1:5000
  - hostname: store.$webHostname
    service: http://127.0.0.1:5001
  - hostname: admin.$webHostname
    service: http://127.0.0.1:5002
  - hostname: playground.$webHostname
    service: http://127.0.0.1:5003
  - hostname: payments.$webHostname
    service: http://127.0.0.1:5005
  - hostname: studio.$webHostname
    service: http://127.0.0.1:5006
  - hostname: supabase.$webHostname
    service: http://127.0.0.1:54321
  - hostname: supabase-studio.$webHostname
    service: http://127.0.0.1:54323
  - hostname: mailpit.$webHostname
    service: http://127.0.0.1:54324
  - service: http_status:404
"@

Set-Content -Path $webConfigPath -Value $webConfigContent
Write-Host "  OK Config: $webConfigPath" -ForegroundColor Green

# Create credentials if needed
if (-not (Test-Path $webCredentialsPath)) {
    Write-Host "  Generating credentials from tunnel token..." -ForegroundColor Gray
    $token = & $cloudflaredPath tunnel token $webTunnelName 2>&1
    if ($LASTEXITCODE -eq 0) {
        try {
            $tokenJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($token.Trim()))
            $tokenData = $tokenJson | ConvertFrom-Json
            $credentials = @{
                AccountTag = $tokenData.a
                TunnelSecret = $tokenData.s
                TunnelID = $tokenData.t
            } | ConvertTo-Json
            Set-Content -Path $webCredentialsPath -Value $credentials
            Write-Host "  OK Credentials created" -ForegroundColor Green
        } catch {
            Write-Host "  X Failed to decode token: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  WARNING Could not get tunnel token (tunnel may not exist yet)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  OK Credentials exist" -ForegroundColor Green
}

# ============================================================================
# STEP 4: Setup SSH Tunnel Config
# ============================================================================
Write-Host ""
Write-Host "[4/9] Setting up SSH Tunnel ($sshHostname)..." -ForegroundColor Yellow

$sshConfigPath = Join-Path $configDir "ssh-config.yml"
$sshCredentialsPath = Join-Path $configDir "$sshTunnelId.json"

# Create config file
$sshConfigContent = @"
tunnel: $sshTunnelId
credentials-file: $sshCredentialsPath
protocol: http2

ingress:
  - hostname: $sshHostname
    service: ssh://localhost:22
  - service: http_status:404
"@

Set-Content -Path $sshConfigPath -Value $sshConfigContent
Write-Host "  OK Config: $sshConfigPath" -ForegroundColor Green

# Create credentials if needed
if (-not (Test-Path $sshCredentialsPath)) {
    Write-Host "  Generating credentials from tunnel token..." -ForegroundColor Gray
    $token = & $cloudflaredPath tunnel token $sshTunnelName 2>&1
    if ($LASTEXITCODE -eq 0) {
        try {
            $tokenJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($token.Trim()))
            $tokenData = $tokenJson | ConvertFrom-Json
            $credentials = @{
                AccountTag = $tokenData.a
                TunnelSecret = $tokenData.s
                TunnelID = $tokenData.t
            } | ConvertTo-Json
            Set-Content -Path $sshCredentialsPath -Value $credentials
            Write-Host "  OK Credentials created" -ForegroundColor Green
        } catch {
            Write-Host "  X Failed to decode token: $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  WARNING Could not get tunnel token (tunnel may not exist yet)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  OK Credentials exist" -ForegroundColor Green
}

# ============================================================================
# STEP 5: Setup Dev Tunnel Config (VS Code Remote SSH)
# ============================================================================
Write-Host ""
Write-Host "[5/9] Setting up Dev Tunnel ($devHostname)..." -ForegroundColor Yellow

$devConfigPath = Join-Path $configDir "dev-config.yml"
$devIdStorePath = Join-Path $configDir "dev-tunnel-id.txt"
$devTunnelId = $null
$devTunnelReady = $false

# Look up dev-tunnel ID dynamically (it's not hardcoded since it may be recreated)
$tunnelListOutput = & $cloudflaredPath tunnel list 2>&1
$devMatch = [regex]::Match($tunnelListOutput, "([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})\s+$devTunnelName")

if ($devMatch.Success) {
    $devTunnelId = $devMatch.Groups[1].Value
    Set-Content -Path $devIdStorePath -Value $devTunnelId
    Write-Host "  OK Tunnel found: $devTunnelId" -ForegroundColor Green

    $devCredentialsPath = Join-Path $configDir "$devTunnelId.json"

    # Create config file
    $devConfigContent = @"
tunnel: $devTunnelId
credentials-file: $devCredentialsPath
protocol: http2

ingress:
  - hostname: $devHostname
    service: ssh://localhost:22
  - service: http_status:404
"@
    Set-Content -Path $devConfigPath -Value $devConfigContent
    Write-Host "  OK Config: $devConfigPath" -ForegroundColor Green

    # Create credentials if needed
    if (-not (Test-Path $devCredentialsPath)) {
        Write-Host "  Generating credentials from tunnel token..." -ForegroundColor Gray
        $devToken = & $cloudflaredPath tunnel token $devTunnelName 2>&1
        if ($LASTEXITCODE -eq 0) {
            try {
                $tokenJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($devToken.Trim()))
                $tokenData = $tokenJson | ConvertFrom-Json
                $credentials = @{
                    AccountTag = $tokenData.a
                    TunnelSecret = $tokenData.s
                    TunnelID = $tokenData.t
                } | ConvertTo-Json
                Set-Content -Path $devCredentialsPath -Value $credentials
                Write-Host "  OK Credentials created" -ForegroundColor Green
            } catch {
                Write-Host "  X Failed to decode token: $_" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  OK Credentials exist" -ForegroundColor Green
    }

    $devTunnelReady = $true
} else {
    Write-Host "  WARNING dev-tunnel not found in Cloudflare account." -ForegroundColor Yellow
    Write-Host "  Run install-dev-tunnel.ps1 from the candystore scripts after recovery." -ForegroundColor Gray
    Write-Host "  Location: Z:\Github\candystore\scripts\dev-tunnel\install-dev-tunnel.ps1" -ForegroundColor Gray
}

# ============================================================================
# STEP 6: Install OpenSSH Server
# ============================================================================
Write-Host ""
Write-Host "[6/9] Installing OpenSSH Server..." -ForegroundColor Yellow

$sshCapability = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'

if ($sshCapability.State -eq "Installed") {
    Write-Host "  OK Already installed" -ForegroundColor Green
} else {
    Write-Host "  Installing..." -ForegroundColor Gray
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    Write-Host "  OK Installed" -ForegroundColor Green
}

# Configure SSH service
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Automatic
Write-Host "  OK SSH service configured" -ForegroundColor Green

# Configure firewall
$firewallRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($firewallRule) {
    Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Profile Any
} else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any | Out-Null
}
Write-Host "  OK Firewall configured" -ForegroundColor Green

# ============================================================================
# STEP 7: Configure SSH Key Authentication
# ============================================================================
Write-Host ""
Write-Host "[7/9] Configuring SSH Key Authentication..." -ForegroundColor Yellow

$sshProgramDataDir = "C:\ProgramData\ssh"
$adminKeysPath = Join-Path $sshProgramDataDir "administrators_authorized_keys"

if (-not (Test-Path $sshProgramDataDir)) {
    New-Item -ItemType Directory -Path $sshProgramDataDir -Force | Out-Null
}

Set-Content -Path $adminKeysPath -Value $macPublicKey
icacls $adminKeysPath /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
Restart-Service sshd

Write-Host "  OK Mac public key configured" -ForegroundColor Green

# ============================================================================
# STEP 8: Create Scheduled Tasks (Silent)
# ============================================================================
Write-Host ""
Write-Host "[8/9] Creating Scheduled Tasks..." -ForegroundColor Yellow

# Web Tunnel Task
Unregister-ScheduledTask -TaskName $webTunnelName -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -Command `"& '$cloudflaredPath' tunnel --config '$webConfigPath' run $webTunnelName`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -Hidden
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $webTunnelName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Web tunnel for $webHostname (silent)" | Out-Null
Start-ScheduledTask -TaskName $webTunnelName
Write-Host "  OK $webTunnelName" -ForegroundColor Green

# SSH Tunnel Task
Unregister-ScheduledTask -TaskName $sshTunnelName -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -Command `"& '$cloudflaredPath' tunnel --config '$sshConfigPath' run $sshTunnelName`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -Hidden
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $sshTunnelName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "SSH tunnel for $sshHostname (silent)" | Out-Null
Start-ScheduledTask -TaskName $sshTunnelName
Write-Host "  OK $sshTunnelName" -ForegroundColor Green

# Dev Tunnel Task (only if tunnel was found)
if ($devTunnelReady) {
    Unregister-ScheduledTask -TaskName $devTunnelName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -Command `"& '$cloudflaredPath' tunnel --config '$devConfigPath' run $devTunnelName`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -Hidden
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $devTunnelName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Dev SSH tunnel for $devHostname (VS Code Remote)" | Out-Null
    Start-ScheduledTask -TaskName $devTunnelName
    Write-Host "  OK $devTunnelName" -ForegroundColor Green
} else {
    Write-Host "  SKIP $devTunnelName (tunnel not found - run install-dev-tunnel.ps1 after)" -ForegroundColor Yellow
}

# ============================================================================
# STEP 9: Create Desktop Shortcuts
# ============================================================================
Write-Host ""
Write-Host "[9/9] Creating Desktop Shortcuts..." -ForegroundColor Yellow

$desktop = if (Test-Path "$env:USERPROFILE\OneDrive\Desktop") {
    "$env:USERPROFILE\OneDrive\Desktop"
} elseif (Test-Path "$env:USERPROFILE\Desktop") {
    "$env:USERPROFILE\Desktop"
} else {
    [Environment]::GetFolderPath("Desktop")
}

$ws = New-Object -ComObject WScript.Shell

# Toggle Web Tunnel
$toggleTunnelPath = Join-Path $scriptDir "toggle-tunnel.bat"
if (Test-Path $toggleTunnelPath) {
    $shortcut = $ws.CreateShortcut("$desktop\Toggle Tunnel.lnk")
    $shortcut.TargetPath = $toggleTunnelPath
    $shortcut.WorkingDirectory = $scriptDir
    $shortcut.IconLocation = "shell32.dll,238"
    $shortcut.Description = "Toggle Web Tunnel (Start/Stop)"
    $shortcut.Save()
    Write-Host "  OK Toggle Tunnel" -ForegroundColor Green
}

# Toggle SSH Tunnel
$toggleSshPath = Join-Path $scriptDir "toggle-ssh-tunnel.bat"
if (Test-Path $toggleSshPath) {
    $shortcut = $ws.CreateShortcut("$desktop\Toggle SSH Tunnel.lnk")
    $shortcut.TargetPath = $toggleSshPath
    $shortcut.WorkingDirectory = $scriptDir
    $shortcut.IconLocation = "shell32.dll,144"
    $shortcut.Description = "Toggle SSH Tunnel (Start/Stop)"
    $shortcut.Save()
    Write-Host "  OK Toggle SSH Tunnel" -ForegroundColor Green
}

# Toggle Dev Tunnel
$toggleDevPath = "Z:\Github\candystore\scripts\dev-tunnel\toggle-dev-tunnel.bat"
if (Test-Path $toggleDevPath) {
    $shortcut = $ws.CreateShortcut("$desktop\Toggle Dev Tunnel.lnk")
    $shortcut.TargetPath = $toggleDevPath
    $shortcut.WorkingDirectory = "Z:\Github\candystore\scripts\dev-tunnel"
    $shortcut.IconLocation = "shell32.dll,144"
    $shortcut.Description = "Toggle Dev SSH Tunnel (Start/Stop)"
    $shortcut.Save()
    Write-Host "  OK Toggle Dev Tunnel" -ForegroundColor Green
}

# Toggle Claude Sessions
$toggleClaudePath = Join-Path $scriptDir "toggle-claude-session.bat"
if (Test-Path $toggleClaudePath) {
    foreach ($session in @("claude", "claimangel", "snd")) {
        $displayName = $session.Substring(0,1).ToUpper() + $session.Substring(1)
        $shortcut = $ws.CreateShortcut("$desktop\Toggle $displayName.lnk")
        $shortcut.TargetPath = $toggleClaudePath
        $shortcut.Arguments = $session
        $shortcut.WorkingDirectory = $scriptDir
        $shortcut.IconLocation = "shell32.dll,24"
        $shortcut.Description = "Toggle $displayName tmux session (Start/Stop)"
        $shortcut.Save()
        Write-Host "  OK Toggle $displayName" -ForegroundColor Green
    }
}

# ============================================================================
# DONE - Show Summary
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "    RECOVERY COMPLETE!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Wait for tunnels to connect
Write-Host "Waiting for tunnels to connect..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# Check status
$procs = Get-Process cloudflared -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Status:" -ForegroundColor Cyan
Write-Host "  Cloudflared processes: $($procs.Count)" -ForegroundColor White

$webTaskState = (Get-ScheduledTask -TaskName $webTunnelName -ErrorAction SilentlyContinue).State
$sshTaskState = (Get-ScheduledTask -TaskName $sshTunnelName -ErrorAction SilentlyContinue).State
$devTaskState = (Get-ScheduledTask -TaskName $devTunnelName -ErrorAction SilentlyContinue).State
Write-Host "  Web tunnel task  : $webTaskState" -ForegroundColor White
Write-Host "  SSH tunnel task  : $sshTaskState" -ForegroundColor White
if ($devTunnelReady) {
    Write-Host "  Dev tunnel task  : $devTaskState" -ForegroundColor White
} else {
    Write-Host "  Dev tunnel task  : SKIPPED - run Z:\Github\candystore\scripts\dev-tunnel\install-dev-tunnel.ps1" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Test URLs:" -ForegroundColor Cyan
Write-Host "  Web: https://$webHostname" -ForegroundColor White
Write-Host "  SSH: ssh windows-remote (from Mac)" -ForegroundColor White
Write-Host "  Dev: ssh dev-windows (VS Code Remote SSH)" -ForegroundColor White

Write-Host ""
Write-Host "Desktop shortcuts created for toggling tunnels." -ForegroundColor Gray
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
