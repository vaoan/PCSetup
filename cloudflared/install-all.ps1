param(
    [switch]$SyncSecrets,
    [switch]$SkipSecretsSync,
    [switch]$AllowIncompleteConsole
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Script
    )

    Write-Host ""
    Write-Host "[$Name]" -ForegroundColor Cyan
    & $Script
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Administrator)) {
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($SyncSecrets) { $argsList += '-SyncSecrets' }
    if ($SkipSecretsSync) { $argsList += '-SkipSecretsSync' }
    if ($AllowIncompleteConsole) { $argsList += '-AllowIncompleteConsole' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList ($argsList -join ' ') -Wait
    exit $LASTEXITCODE
}

$scriptDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptDir
$secretsPath = Join-Path $repoRoot '.secrets'
$syncSecretsScript = Join-Path $scriptDir 'sync-secrets.ps1'
$recoveryScript = Join-Path $scriptDir 'post-format-recovery.ps1'

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$Name
    )

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget is not available; skipping $Name." -ForegroundColor Yellow
        return $false
    }

    Write-Host "Installing/checking $Name via winget..." -ForegroundColor Cyan
    & winget install --id $Id -e --accept-source-agreements --accept-package-agreements --silent
    return ($LASTEXITCODE -eq 0)
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

function Test-WindowsFeatureEnabled {
    param([string]$FeatureName)

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
    return ($feature -and $feature.State -eq 'Enabled')
}

function Ensure-HypervisorBoot {
    Write-Host "Ensuring Windows hypervisor launch settings..." -ForegroundColor Cyan
    & bcdedit /set hypervisorlaunchtype auto | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not set hypervisorlaunchtype=auto. WSL2 may require manual boot configuration." -ForegroundColor Yellow
    }

    & bcdedit /set vsmlaunchtype auto | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not set vsmlaunchtype=auto. Continuing." -ForegroundColor Yellow
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

    Write-Host "Registering Ubuntu-24.04 WSL distro..." -ForegroundColor Cyan
    $registration = Invoke-ProcessCapture -FilePath 'ubuntu2404.exe' -ArgumentList @('install', '--root')
    if ($registration.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($registration.Output)) {
        Write-Host $registration.Output.Trim() -ForegroundColor Yellow
    }

    return (Test-WslDistroRegistered -DistroName 'Ubuntu-24.04')
}

function Install-WslDistro {
    param([string]$DistroName = 'Ubuntu-24.04')

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }

    if (Test-WslDistroRegistered -DistroName $DistroName) {
        Write-Host "$DistroName already registered, skipping..." -ForegroundColor Yellow
        return $true
    }

    Write-Host "Installing/checking WSL distro: $DistroName" -ForegroundColor Cyan
    $distroInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install', '-d', $DistroName, '--no-launch')
    if ($distroInstall.ExitCode -eq 0 -and (Test-WslDistroRegistered -DistroName $DistroName)) {
        return $true
    }

    $distroInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install', $DistroName)
    if ($distroInstall.ExitCode -eq 0 -and (Test-WslDistroRegistered -DistroName $DistroName)) {
        return $true
    }

    Write-Host "WSL CLI distro install did not finish; trying Ubuntu 24.04 via winget..." -ForegroundColor Yellow
    if ((Install-WingetPackage 'Canonical.Ubuntu.2404' 'Ubuntu 24.04 LTS') -or (Get-Command ubuntu2404.exe -ErrorAction SilentlyContinue)) {
        if (Register-UbuntuDistro) {
            return $true
        }
        Write-Host "Ubuntu 24.04 app is installed, but WSL could not register it in this boot." -ForegroundColor Yellow
        return $true
    }

    Write-Host "$DistroName is not ready yet. Reboot if WSL was just enabled, then rerun cloudflared\install-all.bat." -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace($distroInstall.Output)) {
        Write-Host $distroInstall.Output.Trim() -ForegroundColor Yellow
    }
    return $false
}

function Ensure-WslInstallables {
    $requiresReboot = $false

    foreach ($featureName in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'HypervisorPlatform', 'Microsoft-Hyper-V-All')) {
        if (Test-WindowsFeatureEnabled $featureName) {
            Write-Host "$featureName already enabled, skipping..." -ForegroundColor Yellow
            continue
        }

        Write-Host "Enabling Windows feature: $featureName" -ForegroundColor Cyan
        & dism.exe /Online /Enable-Feature "/FeatureName:$featureName" /All /NoRestart
        if ($LASTEXITCODE -eq 0) {
            $requiresReboot = $true
        } else {
            Write-Host "Failed to enable $featureName. Continuing with fallback route setup." -ForegroundColor Yellow
        }
    }

    Install-WingetPackage 'Microsoft.WSL' 'Windows Subsystem for Linux' | Out-Null
    Ensure-HypervisorBoot

    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        $wslStatus = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--status')
        if ($wslStatus.Output -match 'virtualization is not enabled|Virtual Machine Platform') {
            $requiresReboot = $true
        }

        if (-not (Test-WslDistroRegistered -DistroName 'Ubuntu-24.04')) {
            Install-WslDistro -DistroName 'Ubuntu-24.04' | Out-Null
        }
    }

    if ($requiresReboot) {
        Write-Host "WSL prerequisites were installed or changed. A reboot may be required before the full WSL console can replace fallback routes." -ForegroundColor Yellow
    }
}

function Test-WslDistroReady {
    param([string]$DistroName = 'Ubuntu-24.04')

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }

    $distrosResult = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('-l', '-q')
    if ($distrosResult.ExitCode -ne 0) {
        return $false
    }

    $distros = $distrosResult.Output -replace "`0", ''
    return ($distros -match "(?m)^\s*$([regex]::Escape($DistroName))\s*$")
}

function Test-TcpPortListening {
    param([int]$Port)

    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $listener)
}

function Test-ConsoleStackReady {
    $requiredTasks = @('web-console', 'UpdateWSLPortProxy')
    foreach ($taskName in $requiredTasks) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) {
            Write-Host "  Missing scheduled task: $taskName" -ForegroundColor Yellow
            return $false
        }
    }

    $devConfigPath = Join-Path $env:USERPROFILE '.cloudflared\dev-config.yml'
    if (-not (Test-Path $devConfigPath)) {
        Write-Host "  Missing console tunnel config: $devConfigPath" -ForegroundColor Yellow
        return $false
    }

    $consoleCloudflared = Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*dev-config.yml*' }
    if (-not $consoleCloudflared) {
        Write-Host "  Console cloudflared process is not running with dev-config.yml" -ForegroundColor Yellow
        return $false
    }

    foreach ($port in 7681, 7682, 2222, 8080, 7683, 7686, 7687) {
        if (-not (Test-TcpPortListening -Port $port)) {
            Write-Host "  Console origin port is not listening: 127.0.0.1:$port" -ForegroundColor Yellow
            return $false
        }
    }

    return $true
}

function Assert-ConsoleStackReady {
    if (Test-ConsoleStackReady) {
        Write-Host "Console stack readiness check passed." -ForegroundColor Green
        return
    }

    if ($AllowIncompleteConsole) {
        Write-Host "Console stack is incomplete, but -AllowIncompleteConsole was supplied." -ForegroundColor Yellow
        return
    }

    if (-not (Test-WslDistroReady -DistroName 'Ubuntu-24.04')) {
        throw "Console stack is incomplete because Ubuntu-24.04 is not ready. Reboot if WSL was enabled, finish Ubuntu first-launch setup, then rerun cloudflared\install-all.bat."
    }

    throw "Console stack is incomplete. Rerun cloudflared\install-all.bat, then run cloudflared\verify-console.ps1 and cloudflared\verify-public-routes.ps1."
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Cloudflare Full Install" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This will sync secrets when needed, install cloudflared, configure tunnels, start them, and install scheduled tasks." -ForegroundColor Gray

if (-not $SkipSecretsSync -and ($SyncSecrets -or -not (Test-Path $secretsPath))) {
    if (-not (Test-Path $syncSecretsScript)) {
        throw "Missing sync script: $syncSecretsScript"
    }

    Invoke-Step 'Sync secrets' {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $syncSecretsScript
    }
}
elseif (Test-Path $secretsPath) {
    Write-Host "Secrets already present: $secretsPath" -ForegroundColor Green
}
else {
    throw ".secrets is missing and secrets sync was skipped."
}

if (-not (Test-Path $recoveryScript)) {
    throw "Missing recovery script: $recoveryScript"
}

Invoke-Step 'Set PowerShell execution policy' {
    foreach ($scope in 'CurrentUser', 'LocalMachine') {
        try {
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope $scope -Force -ErrorAction Stop
        }
        catch {
            if ((Get-ExecutionPolicy -Scope $scope) -ne 'RemoteSigned') {
                throw
            }
            Write-Host "  $scope execution policy is RemoteSigned; ignoring process-scope override." -ForegroundColor Gray
        }
    }
    $global:LASTEXITCODE = 0
}

Invoke-Step 'Install WSL prerequisites for console routes' {
    Ensure-WslInstallables
    $global:LASTEXITCODE = 0
}

Invoke-Step 'Install, start, and schedule Cloudflare stack' {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $recoveryScript
}

Write-Host ""
Write-Host "[Task status]" -ForegroundColor Cyan
$taskNames = @(
    'ffxivbe-tunnel',
    'ssh-tunnel',
    'dev-tunnel',
    'web-console',
    'UpdateWSLPortProxy'
)

foreach ($taskName in $taskNames) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host ("  {0}: {1}" -f $taskName, $task.State) -ForegroundColor $(if ($task.State -eq 'Running' -or $task.State -eq 'Ready') { 'Green' } else { 'Yellow' })
    }
    else {
        Write-Host ("  {0}: Not installed" -f $taskName) -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "[Console stack readiness]" -ForegroundColor Cyan
Assert-ConsoleStackReady

Write-Host ""
Write-Host "Cloudflare full install complete." -ForegroundColor Green
