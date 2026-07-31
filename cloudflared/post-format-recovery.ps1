# ============================================================================
# POST-FORMAT RECOVERY SCRIPT
# ============================================================================
# Run this script after formatting your PC to restore everything:
# - Cloudflared (official MSI for Smart App Control)
# - Web tunnel (www.ffxiv.be, chat.ffxiv.be)
# - SSH tunnel (pc.ffxiv.be -> SSH access)
# - Dev tunnel (dev.ffxiv.be -> VS Code Remote SSH)
# - OpenSSH Server with key authentication
# - Scheduled tasks (all run silently)
# - Desktop shortcuts
#
# Usage: Right-click -> Run with PowerShell (will auto-elevate to Admin)
# ============================================================================

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

# ============================================================================
# CONFIGURATION - Update these if IDs change
# ============================================================================
$webTunnelId = "c552cb9c-62bd-4c8b-9ec6-16627b1b8af3"
$webTunnelName = "ffxivbe-tunnel"
$webHostname = "www.ffxiv.be"

$sshTunnelId = "8dffdb51-77cc-43ca-8dc8-8a0c720607a5"
$sshTunnelName = "ssh-tunnel"
$sshHostname = "pc.ffxiv.be"

# Dev tunnel ID is dynamic - looked up from Cloudflare during recovery
$devTunnelName = "dev-tunnel"
$devHostname = "dev.ffxiv.be"

$macPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho heinerangarita@Heiners-MacBook-Air.local"

$cloudflaredPath = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$cfDir = Join-Path $env:USERPROFILE ".cloudflared"
$accountId = 'd34896e6a0f8b2fba5e03dec659eac50'

function Read-Secret {
    param([string]$Key)
    $secretsPath = Join-Path (Split-Path -Parent $PSScriptRoot) '.secrets'
    if (-not (Test-Path $secretsPath)) { throw ".secrets not found at $secretsPath" }
    $line = Get-Content $secretsPath | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if (-not $line) { throw "Secret '$Key' not found in .secrets" }
    return ($line -replace "^$Key=", '').Trim()
}

function Get-CloudflaredTunnelToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TunnelName,
        [Parameter(Mandatory = $true)]
        [string]$OutputPrefix
    )

    $token = Read-Secret 'CLOUDFLARE_ACCOUNT_API_TOKEN'
    $headers = @{ Authorization = "Bearer $token" }
    $tunnels = (Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/accounts/$accountId/cfd_tunnel" -Headers $headers -Method Get).result
    $tunnel = @($tunnels | Where-Object { $_.name -eq $TunnelName -and -not $_.deleted_at } | Select-Object -First 1)
    if (-not $tunnel) { return $null }
    $tokenResponse = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/accounts/$accountId/cfd_tunnel/$($tunnel.id)/token" -Headers $headers -Method Get
    if (-not $tokenResponse.success) { return $null }
    if ($tokenResponse.result.PSObject.Properties.Name -contains 'token') { return $tokenResponse.result.token }
    return $tokenResponse.result
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

function Stop-CloudflaredTunnelProcesses {
    param([string[]]$Patterns)

    $processes = Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue
    foreach ($process in @($processes)) {
        $commandLine = [string]$process.CommandLine
        if (-not $commandLine) { continue }
        foreach ($pattern in $Patterns) {
            if ($commandLine -like "*$pattern*") {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    $stdoutPath = Join-Path $env:TEMP ("pcsetup-capture-{0}.out" -f [Guid]::NewGuid().ToString('N'))
    $stderrPath = Join-Path $env:TEMP ("pcsetup-capture-{0}.err" -f [Guid]::NewGuid().ToString('N'))
    try {
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $stdout = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -Raw } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw } else { '' }
        $combinedOutput = "$stdout`n$stderr" -replace "`0", ''
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output   = $combinedOutput
        }
    }
    finally {
        Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-WslInstalled {
    $wslFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -ErrorAction SilentlyContinue
    if (-not $wslFeature -or $wslFeature.State -ne 'Enabled') {
        return $false
    }

    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        $wslStatus = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--status')
        if ($wslStatus.Output -match 'not installed') {
            return $false
        }
    }

    return $true
}

function Test-WslDistroReady {
    param([string]$DistroName = 'Ubuntu-24.04')

    if (-not (Test-WslInstalled)) {
        return $false
    }

    $stdoutPath = Join-Path $env:TEMP "wsl-list.out"
    $stderrPath = Join-Path $env:TEMP "wsl-list.err"
    Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath 'wsl.exe' -ArgumentList @('-l', '-q') -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $output = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -Raw } else { '' }
    Remove-Item $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue

    if ($process.ExitCode -ne 0) {
        return $false
    }

    $distros = @($output -split "`r?`n" | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
    return ($distros -contains $DistroName)
}

function Install-WslPackage {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "  winget is not available; skipping Microsoft.WSL package install." -ForegroundColor Yellow
        return $false
    }

    Write-Host "  Installing/checking Microsoft.WSL via winget..." -ForegroundColor Gray
    & winget install --id Microsoft.WSL -e --accept-source-agreements --accept-package-agreements --silent
    return ($LASTEXITCODE -eq 0)
}

function Ensure-HypervisorBoot {
    Write-Host "  Ensuring Windows hypervisor launch settings..." -ForegroundColor Gray
    bcdedit /set hypervisorlaunchtype auto | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING Could not set hypervisorlaunchtype=auto." -ForegroundColor Yellow
    }

    bcdedit /set vsmlaunchtype auto | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING Could not set vsmlaunchtype=auto." -ForegroundColor Yellow
    }
}

function Test-WslDistroRegistered {
    param([string]$DistroName = 'Ubuntu-24.04')

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }

    $distros = (Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('-l', '-q')).Output -replace "`0", ''
    return ($distros -match "(?m)^\s*$([regex]::Escape($DistroName))\s*$")
}

function Register-UbuntuDistro {
    if (-not (Get-Command ubuntu2404.exe -ErrorAction SilentlyContinue)) {
        return $false
    }

    Write-Host "  Registering Ubuntu-24.04 WSL distro..." -ForegroundColor Gray
    $registration = Invoke-ProcessCapture -FilePath 'ubuntu2404.exe' -ArgumentList @('install', '--root')
    if ($registration.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($registration.Output)) {
        Write-Host $registration.Output.Trim() -ForegroundColor Yellow
    }

    return (Test-WslDistroRegistered -DistroName 'Ubuntu-24.04')
}

function Install-WslDistro {
    param([string]$DistroName = 'Ubuntu-24.04')

    if (Test-WslDistroRegistered -DistroName $DistroName) {
        return $true
    }

    Write-Host "  Installing/checking WSL distro: $DistroName" -ForegroundColor Gray
    $distroInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install', '-d', $DistroName, '--no-launch')
    if ($distroInstall.ExitCode -eq 0 -and (Test-WslDistroRegistered -DistroName $DistroName)) {
        return $true
    }

    $distroInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install', $DistroName)
    if ($distroInstall.ExitCode -eq 0 -and (Test-WslDistroRegistered -DistroName $DistroName)) {
        return $true
    }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  WSL CLI distro install did not finish; trying Ubuntu 24.04 via winget..." -ForegroundColor Gray
        & winget install --id Canonical.Ubuntu.2404 -e --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -eq 0 -or (Get-Command ubuntu2404.exe -ErrorAction SilentlyContinue)) {
            if (Register-UbuntuDistro) {
                return $true
            }
            Write-Host "  Ubuntu 24.04 app is installed, but WSL could not register it in this boot." -ForegroundColor Yellow
            return $true
        }
    }

    Write-Host "  Ubuntu-24.04 installation is pending. $($distroInstall.Output.Trim())" -ForegroundColor Yellow
    return $false
}

function Ensure-WslPrerequisites {
    $requiresReboot = $false

    foreach ($featureName in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'HypervisorPlatform', 'Microsoft-Hyper-V-All')) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction SilentlyContinue
        if ($feature -and $feature.State -eq 'Enabled') {
            continue
        }

        Write-Host "  Enabling Windows feature: $featureName" -ForegroundColor Gray
        dism.exe /Online /Enable-Feature "/FeatureName:$featureName" /All /NoRestart | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to enable Windows feature: $featureName"
        }

        $requiresReboot = $true
    }

    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        $wslStatus = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--status')
        if ($wslStatus.Output -match 'not installed') {
            Install-WslPackage | Out-Null
            Ensure-HypervisorBoot

            Write-Host "  Installing WSL platform files..." -ForegroundColor Gray
            $wslInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install', '--no-distribution')
            if ($wslInstall.ExitCode -ne 0) {
                Write-Host "  WSL --no-distribution install did not finish; trying default WSL install..." -ForegroundColor Gray
                $wslInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install')
                if ($wslInstall.ExitCode -ne 0) {
                    throw "wsl --install failed. $($wslInstall.Output.Trim())"
                }
            }
            $requiresReboot = $true
        }

        if ($wslStatus.Output -match 'virtualization is not enabled|Virtual Machine Platform') {
            Install-WslPackage | Out-Null
            Ensure-HypervisorBoot
            $requiresReboot = $true
        }
    }

    return [pscustomobject]@{
        RequiresReboot = $requiresReboot
    }
}

function Complete-WithConsoleBlocked {
    param([string]$Reason)

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "    BASE RECOVERY COMPLETE, CONSOLE BLOCKED" -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host $Reason -ForegroundColor Yellow
    Write-Host "Public console routes will keep failing until the console stack is installed and verified." -ForegroundColor Yellow
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Reboot Windows if WSL features were just enabled." -ForegroundColor White
    Write-Host "  2. Finish Ubuntu-24.04 first-launch setup if Windows prompts for it." -ForegroundColor White
    Write-Host "  3. Rerun cloudflared\install-all.bat." -ForegroundColor White
    exit 2
}

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
Write-Host "  - Web tunnel: $webHostname + chat/map + app subdomains" -ForegroundColor Gray
Write-Host "  - SSH tunnel: $sshHostname" -ForegroundColor Gray
Write-Host "  - Dev tunnel: $devHostname (VS Code Remote SSH)" -ForegroundColor Gray
Write-Host "  - OpenSSH Server + key auth" -ForegroundColor Gray
Write-Host "  - Silent scheduled tasks" -ForegroundColor Gray
Write-Host "  - Desktop shortcuts" -ForegroundColor Gray
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = $cfDir

# ============================================================================
# STEP 1: Install Cloudflared
# ============================================================================
Write-Host "[1/9] Installing Cloudflared..." -ForegroundColor Yellow

if (Test-Path $cloudflaredPath) {
    $cfVersionResult = Invoke-CloudflaredCommand -Arguments @('--version')
    Write-Host "  OK Already installed: $($cfVersionResult.Output.Trim())" -ForegroundColor Green
} else {
    Write-Host "  Downloading official MSI (for Smart App Control)..." -ForegroundColor Gray

    $msiUrl = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi'
    $msiPath = "$env:TEMP\cloudflared.msi"

    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath

    Write-Host "  Installing..." -ForegroundColor Gray
    Start-Process msiexec.exe -ArgumentList '/i', $msiPath, '/quiet', '/norestart' -Wait

    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue

    if (Test-Path $cloudflaredPath) {
        $cfVersionResult = Invoke-CloudflaredCommand -Arguments @('--version')
        Write-Host "  OK Installed: $($cfVersionResult.Output.Trim())" -ForegroundColor Green
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
Write-Host "[2/10] Cloudflare Authentication..." -ForegroundColor Yellow
try {
    $apiToken = Read-Secret 'CLOUDFLARE_ACCOUNT_API_TOKEN'
    if (-not $apiToken -or $apiToken -eq 'replace_me') { throw "CLOUDFLARE_ACCOUNT_API_TOKEN missing" }
    Write-Host "  OK Cloudflare API token loaded from .secrets" -ForegroundColor Green
} catch {
    Write-Host "  X Cloudflare API token missing" -ForegroundColor Red
    Write-Host "  Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
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
  - hostname: chat.$webHostname
    service: http://127.0.0.1:3000
  - service: http_status:404
"@

Set-Content -Path $webConfigPath -Value $webConfigContent
Write-Host "  OK Config: $webConfigPath" -ForegroundColor Green

# Create credentials if needed
if (-not (Test-Path $webCredentialsPath)) {
    Write-Host "  Generating credentials from tunnel token..." -ForegroundColor Gray
    $token = Get-CloudflaredTunnelToken -TunnelName $webTunnelName -OutputPrefix "cloudflared-web-token"
    if ($token) {
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
    $token = Get-CloudflaredTunnelToken -TunnelName $sshTunnelName -OutputPrefix "cloudflared-ssh-token"
    if ($token) {
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

try {
    Write-Host "  Ensuring Cloudflare cert.pem from .secrets..." -ForegroundColor Gray
    $null = Ensure-CloudflareCertPem -RepoRoot $PSScriptRoot
    Write-Host "  OK cert.pem ready" -ForegroundColor Green

    Write-Host "  Provisioning DNS routes for web and SSH tunnels..." -ForegroundColor Gray
    Invoke-CloudflaredDnsRoute -CloudflaredPath $cloudflaredPath -TunnelName $webTunnelId -Hostnames @(
        $webHostname,
        "www.$webHostname",
        "chat.$webHostname",
        "map.$webHostname"
    )
    Invoke-CloudflaredDnsRoute -CloudflaredPath $cloudflaredPath -TunnelName $sshTunnelId -Hostnames @($sshHostname)
    Write-Host "  OK DNS routes provisioned" -ForegroundColor Green
} catch {
    Write-Host "  X DNS route provisioning failed: $_" -ForegroundColor Red
    exit 1
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
$devTunnel = @(Invoke-CloudflareApi -Method GET -Path "/accounts/$accountId/cfd_tunnel" | Where-Object { $_.name -eq $devTunnelName -and -not $_.deleted_at } | Select-Object -First 1)

if ($devTunnel) {
    $devTunnelId = $devTunnel.id
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
        $devToken = Get-CloudflaredTunnelToken -TunnelName $devTunnelName -OutputPrefix "cloudflared-dev-token"
        if ($devToken) {
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
    Write-Host "  Run the dev tunnel installer from its own project if you need that service." -ForegroundColor Gray
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
Stop-CloudflaredTunnelProcesses -Patterns @('config.yml', 'ffxivbe-tunnel')
Unregister-ScheduledTask -TaskName $webTunnelName -Confirm:$false -ErrorAction SilentlyContinue
$webLauncherPath = Join-Path $cfDir "web-tunnel-launcher.vbs"
$webLauncherContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run Chr(34) & "$cloudflaredPath" & Chr(34) & " tunnel --config " & Chr(34) & "$webConfigPath" & Chr(34) & " run $webTunnelName", 0, False
"@
Set-Content -Path $webLauncherPath -Value $webLauncherContent
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$webLauncherPath`""
$trigger = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -Hidden -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
Register-ScheduledTask -TaskName $webTunnelName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Web tunnel for $webHostname (silent, boot-started)" | Out-Null
Start-ScheduledTask -TaskName $webTunnelName
Write-Host "  OK $webTunnelName" -ForegroundColor Green

# SSH Tunnel Task
Stop-CloudflaredTunnelProcesses -Patterns @('ssh-config.yml', 'ssh-tunnel')
Unregister-ScheduledTask -TaskName $sshTunnelName -Confirm:$false -ErrorAction SilentlyContinue
$sshLauncherPath = Join-Path $cfDir "ssh-tunnel-launcher.vbs"
$sshLauncherContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run Chr(34) & "$cloudflaredPath" & Chr(34) & " tunnel --config " & Chr(34) & "$sshConfigPath" & Chr(34) & " run $sshTunnelName", 0, False
"@
Set-Content -Path $sshLauncherPath -Value $sshLauncherContent
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$sshLauncherPath`""
$trigger = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -Hidden -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
Register-ScheduledTask -TaskName $sshTunnelName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "SSH tunnel for $sshHostname (silent, boot-started)" | Out-Null
Start-ScheduledTask -TaskName $sshTunnelName
Write-Host "  OK $sshTunnelName" -ForegroundColor Green

# Dev Tunnel Task (only if tunnel was found)
if ($devTunnelReady) {
    Unregister-ScheduledTask -TaskName $devTunnelName -Confirm:$false -ErrorAction SilentlyContinue
    $devLauncherPath = Join-Path $cfDir "dev-tunnel-launcher.vbs"
    $devLauncherContent = @"
Set shell = CreateObject("WScript.Shell")
shell.Run Chr(34) & "$cloudflaredPath" & Chr(34) & " tunnel --config " & Chr(34) & "$devConfigPath" & Chr(34) & " run $devTunnelName", 0, False
"@
    Set-Content -Path $devLauncherPath -Value $devLauncherContent
    $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$devLauncherPath`""
    $trigger = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
    )
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -Hidden -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
    Register-ScheduledTask -TaskName $devTunnelName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Dev SSH tunnel for $devHostname (VS Code Remote, boot-started)" | Out-Null
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

# Clean up desktop shortcuts left by the removed MSYS2 tmux session feature.
foreach ($stale in @("Toggle Claude.lnk", "Toggle SND.lnk", "Toggle ClaimAngel.lnk")) {
    $stalePath = Join-Path $desktop $stale
    if (Test-Path $stalePath) {
        Remove-Item $stalePath -Force -ErrorAction SilentlyContinue
        Write-Host "  OK Removed stale shortcut: $stale" -ForegroundColor Gray
    }
}

# ============================================================================
# DONE - Show Summary
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "    BASE TUNNEL RECOVERY COMPLETE" -ForegroundColor Green
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
    Write-Host "  Dev tunnel task  : SKIPPED - install it from the dev tunnel project if needed" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Test URLs:" -ForegroundColor Cyan
Write-Host "  Web: https://$webHostname" -ForegroundColor White
Write-Host "  Chat: https://chat.$webHostname" -ForegroundColor White
Write-Host "  Map: https://map.$webHostname" -ForegroundColor White
Write-Host "  SSH: ssh windows-remote (from Mac)" -ForegroundColor White
Write-Host "  Dev: ssh dev-windows (VS Code Remote SSH)" -ForegroundColor White

Write-Host ""
Write-Host "Desktop shortcuts created for toggling tunnels." -ForegroundColor Gray
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# STEP 10: Restore the console stack
# ============================================================================
Write-Host "[10/10] Restoring Console Stack..." -ForegroundColor Yellow

$consoleSetupWindows = Join-Path $scriptDir "setup-console-windows.ps1"
$consoleSetupWsl = Join-Path $scriptDir "setup-console-wsl.sh"
$wslInstalled = Test-WslInstalled
$wslDistroReady = Test-WslDistroReady -DistroName 'Ubuntu-24.04'

if (-not $wslInstalled) {
    Write-Host "  WSL is not installed. Enabling WSL for the next reboot..." -ForegroundColor Yellow
    try {
        $wslPrep = Ensure-WslPrerequisites
        if ($wslPrep.RequiresReboot) {
            Complete-WithConsoleBlocked "WSL prerequisites were enabled and Windows must reboot before Ubuntu-24.04 and the console routes can be installed."
        }
    } catch {
        Complete-WithConsoleBlocked "WSL prerequisite setup failed: $($_.Exception.Message)"
    }
} elseif (-not $wslDistroReady) {
    Write-Host "  WSL features are enabled, but Ubuntu-24.04 is not ready yet." -ForegroundColor Yellow
    try {
        Install-WslDistro -DistroName 'Ubuntu-24.04' | Out-Null
    } catch {
        Write-Host "  Ubuntu-24.04 installation command failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Complete-WithConsoleBlocked "Ubuntu-24.04 is not initialized yet. Finish distro setup, then rerun cloudflared\install-all.bat."
} elseif (Test-Path $consoleSetupWsl) {
    Write-Host "  Running setup-console-wsl.sh..." -ForegroundColor Gray
    $consoleSetupWslUnix = ($consoleSetupWsl -replace '^Z:\\', '/mnt/z/' -replace '\\', '/')
    wsl -d Ubuntu-24.04 --user root bash $consoleSetupWslUnix
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X Console WSL setup failed" -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host "  OK Console WSL setup complete" -ForegroundColor Green
} else {
    Write-Host "  SKIP setup-console-wsl.sh not found" -ForegroundColor Yellow
}

if ($wslDistroReady -and (Test-Path $consoleSetupWindows)) {
    Write-Host "  Running setup-console-windows.ps1..." -ForegroundColor Gray
    & powershell -ExecutionPolicy Bypass -File $consoleSetupWindows -SkipVerification
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  X Console Windows setup failed" -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host "  OK Console Windows setup complete" -ForegroundColor Green
} elseif ($wslDistroReady) {
    Write-Host "  SKIP setup-console-windows.ps1 not found" -ForegroundColor Yellow
}

$verifyScript = Join-Path $scriptDir "verify-console.ps1"
if (-not $wslDistroReady) {
    Complete-WithConsoleBlocked "Full console verification skipped because WSL/Ubuntu-24.04 is not ready."
} elseif (Test-Path $verifyScript) {
    Write-Host "[post-format-recovery] Running full post-install verification..." -ForegroundColor Yellow
    & powershell -NoProfile -ExecutionPolicy Bypass -File $verifyScript
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[post-format-recovery] Full verification passed. Report saved under $env:USERPROFILE\.cloudflared\reports." -ForegroundColor Green
    } else {
        Write-Host "[post-format-recovery] Full verification failed. Check $env:USERPROFILE\.cloudflared\reports." -ForegroundColor Red
        exit $LASTEXITCODE
    }
} else {
    Write-Host "[post-format-recovery] Verification skipped: verify-console.ps1 not found." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "    RECOVERY COMPLETE!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
