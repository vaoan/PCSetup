$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

# Server Core and freshly-imaged machines do not always preload the compression assemblies.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Portable git/gh live here. Nothing else on the machine is assumed to exist yet.
$script:BootstrapRoot = Join-Path $env:ProgramData 'PCSetup\bootstrap'
$script:BootstrapPaths = New-Object System.Collections.Generic.List[string]

function Ensure-GetFileHashCommand {
    function global:Get-FileHash {
        [CmdletBinding(DefaultParameterSetName = 'Path')]
        param(
            [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')]
            [string[]]$Path,

            [Parameter(Mandatory, ParameterSetName = 'LiteralPath')]
            [Alias('PSPath')]
            [string[]]$LiteralPath,

            [Parameter(Mandatory, ParameterSetName = 'Stream')]
            [System.IO.Stream]$InputStream,

            [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5')]
            [string]$Algorithm = 'SHA256'
        )

        if ($PSCmdlet.ParameterSetName -eq 'Stream') {
            $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
            try {
                $hash = [BitConverter]::ToString($hasher.ComputeHash($InputStream)).Replace('-', '')
                [pscustomobject]@{
                    Algorithm = $Algorithm.ToUpperInvariant()
                    Hash = $hash
                }
            }
            finally {
                if ($hasher) { $hasher.Dispose() }
            }
            return
        }

        $pathsToProcess = if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') { $LiteralPath } else { $Path }
        foreach ($item in $pathsToProcess) {
            $resolved = Resolve-Path -LiteralPath $item -ErrorAction Stop
            foreach ($resolvedPath in $resolved) {
                $stream = [System.IO.File]::OpenRead($resolvedPath.ProviderPath)
                try {
                    $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
                    $hash = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '')
                    [pscustomobject]@{
                        Algorithm = $Algorithm.ToUpperInvariant()
                        Hash = $hash
                        Path = $resolvedPath.ProviderPath
                    }
                }
                finally {
                    if ($hasher) { $hasher.Dispose() }
                    $stream.Dispose()
                }
            }
        }
    }
}

function Refresh-SetupEnvironment {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $extra = @(
        "$env:USERPROFILE\scoop\shims",
        "$env:ProgramData\scoop\shims",
        "$env:ProgramData\chocolatey\bin",
        "$env:APPDATA\nvm",
        "$env:ProgramFiles\nodejs"
    )

    # Bootstrap paths go LAST on purpose: once Scoop installs the managed git/gh, its shims must
    # win over the portable copies. This function rebuilds $env:Path from scratch, so the
    # bootstrap entries have to be re-appended here or they vanish on the next refresh.
    $env:Path = ($extra + @($machinePath, $userPath) + @($script:BootstrapPaths) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique) -join ';'

    foreach ($scope in 'Machine', 'User') {
        foreach ($name in 'SCOOP', 'SCOOP_GLOBAL', 'NVM_HOME', 'NVM_SYMLINK') {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                Set-Item -Path "Env:$name" -Value $value
            }
        }
    }
}

function Set-PathEntryFirst {
    param(
        [string]$Entry,
        [ValidateSet('Machine', 'User')]
        [string]$Scope = 'Machine'
    )

    if ([string]::IsNullOrWhiteSpace($Entry)) {
        return
    }

    $current = [Environment]::GetEnvironmentVariable('Path', $Scope)
    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $normalizedEntry = $Entry.TrimEnd('\')
    $parts = @($parts | Where-Object { $_.TrimEnd('\') -ine $normalizedEntry })
    [Environment]::SetEnvironmentVariable('Path', ((@($Entry) + $parts) -join ';'), $Scope)
}

function Get-BootstrapArchitecture {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { return [pscustomobject]@{ MinGit = 'arm64';  Gh = 'arm64' } }
        'x86'   { return [pscustomobject]@{ MinGit = '32-bit'; Gh = '386' } }
        default { return [pscustomobject]@{ MinGit = '64-bit'; Gh = 'amd64' } }
    }
}

function Add-BootstrapPath {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    if (-not ($script:BootstrapPaths -contains $Directory)) {
        $script:BootstrapPaths.Add($Directory)
    }
    Refresh-SetupEnvironment
}

function Install-BootstrapTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$AssetPattern,
        [string]$ExcludePattern,
        [Parameter(Mandatory = $true)][string]$BinSubPath
    )

    $target = Join-Path $script:BootstrapRoot $Name
    $exe = Join-Path (Join-Path $target $BinSubPath) "$Command.exe"

    if (Test-Path $exe) {
        Write-Host "$Name bootstrap already present, reusing..." -ForegroundColor Yellow
        Add-BootstrapPath (Split-Path $exe -Parent)
        return
    }

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "$Name already on PATH, no bootstrap needed..." -ForegroundColor Yellow
        return
    }

    Write-Host "Bootstrapping portable $Name from $Repo..." -ForegroundColor Cyan
    $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'PCSetup' }
    $asset = $release.assets |
        Where-Object { $_.name -like $AssetPattern } |
        Where-Object { -not $ExcludePattern -or $_.name -notlike $ExcludePattern } |
        Select-Object -First 1
    if (-not $asset) {
        throw "No asset matching '$AssetPattern' in the latest $Repo release; cannot bootstrap $Name."
    }

    $zipPath = Join-Path $env:TEMP ("pcsetup-bootstrap-{0}.zip" -f $Name)
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    # WebClient + ZipFile rather than Invoke-WebRequest + Expand-Archive: this runs before
    # anything is installed, and both of those cmdlets live in Microsoft.PowerShell.Utility /
    # .Archive, which a PS7-poisoned PSModulePath can make unloadable (the same failure this
    # script already works around with Ensure-GetFileHashCommand).
    [System.Net.WebClient]::new().DownloadFile($asset.browser_download_url, $zipPath)

    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $target)
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $exe)) {
        $found = Get-ChildItem $target -Filter "$Command.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) {
            throw "$Name bootstrap archive ($($asset.name)) did not contain $Command.exe."
        }
        $exe = $found.FullName
    }

    Add-BootstrapPath (Split-Path $exe -Parent)
    Write-Host "$Name bootstrapped to $exe" -ForegroundColor Green
}

function Invoke-Logged {
    param(
        [string]$Name,
        [scriptblock]$Script
    )

    Write-Host "Installing/checking $Name..." -ForegroundColor Cyan
    try {
        $result = & $Script
        if ($result -contains $false) {
            return $false
        }
        return $true
    }
    catch {
        Write-Host "$Name failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Test-ScoopPackageInstalled {
    param([string]$Package)

    $prefix = & scoop prefix $Package 2>$null
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($prefix))
}

function Install-ScoopPackage {
    param(
        [string]$Package,
        [string[]]$Commands = @()
    )

    Refresh-SetupEnvironment
    if (Test-ScoopPackageInstalled $Package) {
        Write-Host "$Package already installed by Scoop, skipping..." -ForegroundColor Yellow
        return $true
    }

    foreach ($command in $Commands) {
        if (Get-Command $command -ErrorAction SilentlyContinue) {
            Write-Host "$Package command exists outside Scoop; installing Scoop package anyway..." -ForegroundColor Yellow
            break
        }
    }

    & scoop install $Package
    Refresh-SetupEnvironment
    return ($LASTEXITCODE -eq 0)
}

function Install-FirstAvailableScoopPackage {
    param(
        [string]$Name,
        [string[]]$Packages,
        [string[]]$Commands = @()
    )

    foreach ($command in $Commands) {
        if (Get-Command $command -ErrorAction SilentlyContinue) {
            Write-Host "$Name already available via $command, skipping..." -ForegroundColor Yellow
            return $true
        }
    }

    foreach ($package in $Packages) {
        if (Invoke-Logged $package { Install-ScoopPackage $package $Commands }) {
            return $true
        }
    }

    return $false
}

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

    Write-Host "$DistroName is not ready. Reboot if WSL was just enabled, then rerun 0-init-prereqs.bat." -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace($distroInstall.Output)) {
        Write-Host $distroInstall.Output.Trim() -ForegroundColor Yellow
    }
    return $false
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

function Enable-WslPrerequisites {
    param([string]$DistroName = 'Ubuntu-24.04')

    Write-Host "Checking WSL prerequisites for Cloudflare console routes..." -ForegroundColor Cyan
    $requiresReboot = $false

    foreach ($featureName in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'HypervisorPlatform', 'Microsoft-Hyper-V-All')) {
        if (Test-WindowsFeatureEnabled $featureName) {
            Write-Host "$featureName already enabled, skipping..." -ForegroundColor Yellow
            continue
        }

        Write-Host "Enabling Windows feature: $featureName" -ForegroundColor Cyan
        & dism.exe /Online /Enable-Feature "/FeatureName:$featureName" /All /NoRestart
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to enable $featureName. Enable it manually, reboot, then rerun 0-init-prereqs.bat." -ForegroundColor Yellow
            continue
        }

        $requiresReboot = $true
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Host "wsl.exe is not available yet. Reboot Windows, then rerun 0-init-prereqs.bat." -ForegroundColor Yellow
        return
    }

    $wslStatus = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--status')
    if ($wslStatus.Output -match 'not installed') {
        Install-WingetPackage 'Microsoft.WSL' 'Windows Subsystem for Linux' | Out-Null
        Ensure-HypervisorBoot

        Write-Host "Installing WSL platform files..." -ForegroundColor Cyan
        $wslInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install', '--no-distribution')
        if ($wslInstall.ExitCode -ne 0) {
            Write-Host "WSL --no-distribution install did not finish; trying default WSL install..." -ForegroundColor Yellow
            $wslInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install')
            if ($wslInstall.ExitCode -ne 0) {
                Write-Host "WSL platform install did not finish. Reboot Windows, then run: wsl --install" -ForegroundColor Yellow
                if (-not [string]::IsNullOrWhiteSpace($wslInstall.Output)) {
                    Write-Host $wslInstall.Output.Trim() -ForegroundColor Yellow
                }
            }
        }
        $requiresReboot = $true
    }

    if ($wslStatus.Output -match 'virtualization is not enabled|Virtual Machine Platform') {
        Ensure-HypervisorBoot
        Write-Host "WSL2 is installed but cannot start in this boot. Reboot Windows, then rerun 0-init-prereqs.bat." -ForegroundColor Yellow
        $requiresReboot = $true
    }

    if ($requiresReboot) {
        Write-Host "WSL prerequisites were changed. Reboot Windows before installing the Cloudflare console stack." -ForegroundColor Yellow
        return
    }

    if (-not (Test-WslDistroRegistered -DistroName $DistroName)) {
        Install-WslDistro -DistroName $DistroName | Out-Null
    }
}

Write-Host "Starting PCSetup prerequisite initialization..." -ForegroundColor Cyan
Ensure-GetFileHashCommand
Set-PathEntryFirst "$env:USERPROFILE\scoop\shims" 'Machine'
Set-PathEntryFirst "$env:ProgramData\scoop\shims" 'Machine'
Refresh-SetupEnvironment

# ─────────────────────────────────────────────
# Git and GitHub CLI first, from portable zips, before any package manager exists.
#
# Scoop cannot function without git: "scoop update" and every "scoop bucket add" are git
# operations. The previous order ran "scoop update" and only then installed git *through Scoop*,
# so on a machine without git the run died at "Scoop update failed" before ever reaching the line
# that would have fixed it. Bootstrapping from the official release zips needs nothing but a
# network connection - no Chocolatey, no Scoop, no MSI, no admin-only installer.
#
# Scoop still installs its own managed git/gh further down; those shims take precedence because
# bootstrap paths are appended last in Refresh-SetupEnvironment.
# ─────────────────────────────────────────────
$bootstrapArch = Get-BootstrapArchitecture
Install-BootstrapTool -Name 'git' -Command 'git' -Repo 'git-for-windows/git' `
    -AssetPattern "MinGit-*-$($bootstrapArch.MinGit).zip" -ExcludePattern '*busybox*' -BinSubPath 'cmd'
Install-BootstrapTool -Name 'gh' -Command 'gh' -Repo 'cli/cli' `
    -AssetPattern "gh_*_windows_$($bootstrapArch.Gh).zip" -BinSubPath 'bin'

foreach ($required in 'git', 'gh') {
    if (-not (Get-Command $required -ErrorAction SilentlyContinue)) {
        throw "$required is not available after bootstrap; Scoop bucket operations would fail."
    }
}

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey bootstrap..." -ForegroundColor Cyan
    try {
        $chocoInstallScript = (Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -UseBasicParsing -TimeoutSec 120).Content
        Invoke-Expression $chocoInstallScript
    }
    catch {
        throw "Chocolatey bootstrap failed: $($_.Exception.Message)"
    }

    Refresh-SetupEnvironment
}
else {
    Write-Host "Chocolatey already installed, skipping bootstrap..." -ForegroundColor Yellow
}

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    throw 'Chocolatey is not available after installation.'
}

if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Scoop..." -ForegroundColor Cyan
    $installer = Join-Path $env:TEMP 'scoop-install.ps1'
    Invoke-WebRequest -Uri 'https://get.scoop.sh' -OutFile $installer -UseBasicParsing
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -RunAsAdmin
    Refresh-SetupEnvironment
}

if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    throw 'Scoop is not available after installation.'
}

$null = & scoop config aria2-enabled false
Write-Host "Updating Scoop..." -ForegroundColor Cyan
& scoop update
if ($LASTEXITCODE -ne 0) {
    throw 'Scoop update failed.'
}

if (-not (Invoke-Logged 'Git' { Install-ScoopPackage 'git' @('git') })) { throw 'Git Scoop install failed.' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is not available after Scoop install.'
}

foreach ($bucket in 'extras', 'versions', 'java', 'nerd-fonts') {
    $buckets = & scoop bucket list 2>$null | Out-String
    if ($buckets -notmatch "(?m)^\s*$bucket\s+") {
        Write-Host "Adding Scoop bucket: $bucket" -ForegroundColor Cyan
        & scoop bucket add $bucket
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add Scoop bucket: $bucket"
        }
    }
}

if (-not (Invoke-Logged '7-Zip' { Install-ScoopPackage '7zip' @('7z') })) { throw '7-Zip Scoop install failed.' }
if (-not (Invoke-Logged 'GitHub CLI' { Install-ScoopPackage 'gh' @('gh') })) { throw 'GitHub CLI Scoop install failed.' }
if (-not (Invoke-Logged 'Python' { Install-ScoopPackage 'python' @('python') })) { throw 'Python Scoop install failed.' }

if (-not (Install-FirstAvailableScoopPackage 'Visual C++ redistributables' @('vcredist-aio', 'vcredist2022', 'vcredist') @())) {
    Install-WingetPackage 'Microsoft.VCRedist.2015+.x64' 'Visual C++ Redistributable x64' | Out-Null
    Install-WingetPackage 'Microsoft.VCRedist.2015+.x86' 'Visual C++ Redistributable x86' | Out-Null
}

Write-Host "Enabling .NET Framework 3.5 feature if available..." -ForegroundColor Cyan
try {
    & dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart
}
catch {
    Write-Host ".NET Framework 3.5 enablement skipped: $($_.Exception.Message)" -ForegroundColor Yellow
}

foreach ($runtime in @(
    @{ Id = 'Microsoft.DotNet.DesktopRuntime.6'; Name = '.NET 6 Desktop Runtime' },
    @{ Id = 'Microsoft.DotNet.DesktopRuntime.8'; Name = '.NET 8 Desktop Runtime' },
    @{ Id = 'Microsoft.DotNet.DesktopRuntime.9'; Name = '.NET 9 Desktop Runtime' }
)) {
    Install-WingetPackage $runtime.Id $runtime.Name | Out-Null
}

if (-not (Invoke-Logged 'Temurin Java 17' { Install-ScoopPackage 'temurin17-jdk' @() })) { throw 'Temurin Java 17 Scoop install failed.' }
if (-not (Invoke-Logged 'Temurin Java 8' { Install-ScoopPackage 'temurin8-jdk' @() })) { throw 'Temurin Java 8 Scoop install failed.' }

if (-not (Invoke-Logged 'nvm' { Install-ScoopPackage 'nvm' @('nvm') })) { throw 'nvm Scoop install failed.' }
Refresh-SetupEnvironment

if (-not (Get-Command nvm -ErrorAction SilentlyContinue)) {
    throw 'nvm is not available after Scoop install.'
}

Write-Host "Installing/checking Node.js LTS via nvm..." -ForegroundColor Cyan
& nvm install lts
if ($LASTEXITCODE -ne 0) {
    throw 'Node.js LTS install via nvm failed.'
}
Refresh-SetupEnvironment
Write-Host "Activating Node.js LTS via nvm..." -ForegroundColor Cyan
& nvm use lts
if ($LASTEXITCODE -ne 0) {
    throw 'Node.js LTS activation via nvm failed.'
}
Refresh-SetupEnvironment

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'node is not available after nvm use lts.'
}

if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
    throw 'npm is not available after nvm use lts.'
}

if ($env:PCSETUP_CI -eq '1') {
    # A Server Core container has no hypervisor, no Appx surface and no winget, so every step
    # in here can only warn. Skipping keeps the CI build from spending minutes on dism and
    # winget calls whose failure is a foregone conclusion.
    Write-Host "SKIP: CI mode - skipping WSL prerequisites." -ForegroundColor Yellow
}
else {
    Enable-WslPrerequisites
}

Write-Host "Prerequisite initialization complete." -ForegroundColor Green
