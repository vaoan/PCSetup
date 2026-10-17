# Per-user apps: the programs that can only be installed into one account's own profile.
#
# Everything else is installed once for the whole PC (machine-wide winget installers, scoop
# --global). These cannot be: Discord and Discord Canary are Squirrel apps that only ever install
# into %LOCALAPPDATA%, and the winget packages below ship per-user installers only (or, for CurseForge/Claude Desktop, the per-user one is what this PC
# always used). So 2-setup-windows.bat registers this file as the "PCSetup per-user apps"
# scheduled task, which runs at EVERY user's sign-in as that user, unelevated and hidden. A new
# Windows account therefore gets all of this on its first sign-in without anyone running a setup
# script there. 2-setup-windows.bat also runs it once, right away, for the account doing the setup.
#
# DELIBERATELY NOT AUTO-ELEVATED, unlike every other .ps1 in this repo: it installs into the
# signed-in user's profile, and an elevated Discord installer ends up running the app as
# administrator (drag-and-drop and the overlay break). -AllowElevated is the fallback 2-setup-windows.bat uses when
# the one-shot task cannot start (no interactive session, e.g. PowerShell Direct in the VM test).
#
# Check -> act -> verify per item; a failure is recorded and the rest still runs; exit 1 lists
# what failed, and the next sign-in simply tries again. Log: %LOCALAPPDATA%\PCSetup\per-user-apps.log
#
# Everything here is ASCII on purpose: Windows PowerShell 5.1 reads a BOM-less file as CP1252.
param([switch]$AllowElevated)

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin -and -not $AllowElevated) {
    Write-Host "per-user-apps.ps1 runs as the signed-in user, not elevated. Use -AllowElevated to force it." -ForegroundColor Yellow
    exit 2
}

# The sign-in task and the one-shot run from 2-setup-windows.bat can overlap; one at a time.
$mutex = New-Object System.Threading.Mutex($false, 'Local\PCSetup-per-user-apps')
if (-not $mutex.WaitOne(0)) { Write-Host "Already running in this session." -ForegroundColor Yellow; exit 0 }

$logDir = Join-Path $env:LOCALAPPDATA 'PCSetup'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path (Join-Path $logDir 'per-user-apps.log') -Append | Out-Null } catch { }

$failures = New-Object System.Collections.ArrayList
function Add-Failure([string]$name) { if (-not $failures.Contains($name)) { $null = $failures.Add($name) } }

# Squirrel-style installers hand off to an updater and return before the app is registered, so
# every post-install check polls (same rule as 2-setup-windows.bat).
function Wait-InstalledCheck([scriptblock]$check, [int]$seconds = 90) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ($true) {
        if (& $check) { return $true }
        if ((Get-Date) -gt $deadline) { return $false }
        Start-Sleep -Seconds 5
    }
}

# On a brand-new account winget (App Installer) is registered a few minutes after the first
# sign-in, so the command may not exist yet when this starts. Wait for it rather than failing.
function Wait-Winget([int]$seconds = 600) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) { return $false }
        Start-Sleep -Seconds 15
    }
    return $true
}

function Test-WingetApp([string]$id) {
    & winget list --id $id -e --accept-source-agreements --disable-interactivity > $null 2>&1
    return ($LASTEXITCODE -eq 0)
}

# Not a GetNewClosure() scriptblock: a closure is bound to its own module scope and cannot see the
# script's functions (Test-WingetApp). Plain dynamic scoping finds $id/$installedCheck instead.
function Test-UserApp([string]$id, [scriptblock]$installedCheck) {
    if ($installedCheck) { return [bool](& $installedCheck) }
    return (Test-WingetApp $id)
}

function Install-UserWingetApp([string]$id, [string]$name, [string]$scope, [scriptblock]$installedCheck) {
    $check = { Test-UserApp $id $installedCheck }
    if (& $check) { Write-Host "$name already installed, skipping..." -ForegroundColor Yellow; return }
    if (-not $script:wingetReady) { Write-Host "$name skipped: winget is not available yet." -ForegroundColor Yellow; Add-Failure $name; return }
    Write-Host "Installing $name via winget..." -ForegroundColor Cyan
    # Never trust winget's exit code (nonzero for benign states); verify instead.
    $wingetArgs = @('install', '--id', $id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($scope) { $wingetArgs += @('--scope', $scope) }
    & winget @wingetArgs | Out-Host
    if (Wait-InstalledCheck $check) { Write-Host "$name installed." -ForegroundColor Green }
    else { Write-Host "$name FAILED to install." -ForegroundColor Red; Add-Failure $name }
}

function Install-DirectExe([string]$name, [string]$url, [string]$silentArgs, [string]$installedPath) {
    if (Test-Path -LiteralPath $installedPath) { Write-Host "$name already installed, skipping..." -ForegroundColor Yellow; return }
    Write-Host "Installing $name..." -ForegroundColor Cyan
    try {
        $tmp = Join-Path $env:TEMP (($name -replace '\W', '') + 'Setup.exe')
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        & curl.exe -fL --retry 3 --retry-all-errors -sS -o $tmp $url
        Start-Process -FilePath $tmp -ArgumentList $silentArgs -Wait
    } catch { Write-Host "$name install error: $($_.Exception.Message)" -ForegroundColor Yellow }
    if (Wait-InstalledCheck { Test-Path -LiteralPath $installedPath }) { Write-Host "$name installed." -ForegroundColor Green }
    else { Write-Host "$name FAILED to install." -ForegroundColor Red; Add-Failure $name }
}

Write-Host "=== $(Get-Date -Format s) per-user apps for $env:USERNAME ===" -ForegroundColor Cyan
$script:wingetReady = Wait-Winget

# Discord and Discord Canary: Discord's own -s (silent, launches nothing). winget's manifests carry
# no switches, so winget would show the installer UI. Only the distributions endpoint honours the
# architecture - api/download?platform=win serves x86 even with arch=x64.
$discordArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
Install-DirectExe 'Discord' "https://discord.com/api/downloads/distributions/app/installers/latest?channel=stable&platform=win&arch=$discordArch" '-s' "$env:LOCALAPPDATA\Discord\Update.exe"
Install-DirectExe 'Discord Canary' "https://discord.com/api/downloads/distributions/app/installers/latest?channel=canary&platform=win&arch=$discordArch" '-s' "$env:LOCALAPPDATA\DiscordCanary\Update.exe"

# Per-user winget packages. Where the app has a known per-user location the check looks there
# rather than at "winget list", which does not always correlate these installers.
Install-UserWingetApp 'Anthropic.Claude' 'Claude Desktop' 'user' { Test-Path -LiteralPath "$env:LOCALAPPDATA\AnthropicClaude" }
Install-UserWingetApp 'Amazon.Kiro' 'Kiro' 'user' $null
Install-UserWingetApp 'timokoessler.2FAGuard' '2FAGuard' 'user' $null
Install-UserWingetApp 'Rufus.Rufus' 'Rufus' 'user' $null
Install-UserWingetApp 'Overwolf.CurseForge' 'CurseForge' 'user' $null
Install-UserWingetApp 'goatcorp.XIVLauncher' 'XIVLauncher' '' { Test-Path -LiteralPath "$env:LOCALAPPDATA\XIVLauncher\XIVLauncher.exe" }

# Rufus is a portable winget package: no Start-menu entry, so give it a desktop shortcut.
$rufusExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Rufus.Rufus_Microsoft.Winget.Source_8wekyb3d8bbwe\rufus.exe'
$rufusShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Rufus.lnk'
if ((Test-Path -LiteralPath $rufusExe) -and -not (Test-Path -LiteralPath $rufusShortcut)) {
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($rufusShortcut)
    $shortcut.TargetPath = $rufusExe
    $shortcut.WorkingDirectory = Split-Path $rufusExe
    $shortcut.IconLocation = "$rufusExe,0"
    $shortcut.Save()
    Write-Host "Rufus desktop shortcut created." -ForegroundColor Green
}

# FFXIV TexTools - not on any package manager. Releases since v3.1.1.3b ship the portable zip
# only (no top-level folder), so extract it when there is no installer asset.
$ttPath = Join-Path $env:LOCALAPPDATA 'TexTools'
$ttExe = Join-Path $ttPath 'FFXIV_TexTools.exe'
if (Test-Path -LiteralPath $ttExe) { Write-Host "TexTools already installed, skipping..." -ForegroundColor Yellow }
else {
    Write-Host "Installing TexTools..." -ForegroundColor Cyan
    try {
        $ttRel = Invoke-RestMethod 'https://api.github.com/repos/TexTools/FFXIV_TexTools_UI/releases/latest' -Headers @{ 'User-Agent' = 'PCSetup' }
        $ttInst = $ttRel.assets | Where-Object { $_.name -like 'Install_TexTools*.exe' } | Select-Object -First 1
        if ($ttInst) {
            $ttFile = Join-Path $env:TEMP 'Install_TexTools.exe'
            & curl.exe -fL -sS -o $ttFile $ttInst.browser_download_url
            Start-Process -FilePath $ttFile -ArgumentList '/S' -Wait
        }
        else {
            $ttZipAsset = $ttRel.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
            if (-not $ttZipAsset) { throw "No TexTools installer or zip asset in release $($ttRel.tag_name)" }
            $ttZip = Join-Path $env:TEMP 'FFXIV_TexTools.zip'
            & curl.exe -fL -sS -o $ttZip $ttZipAsset.browser_download_url
            New-Item -ItemType Directory -Path $ttPath -Force | Out-Null
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($ttZip)
            try {
                foreach ($entry in $zip.Entries) {
                    $dest = Join-Path $ttPath $entry.FullName
                    if ($entry.FullName.EndsWith('/')) { New-Item -ItemType Directory -Path $dest -Force | Out-Null; continue }
                    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
                }
            }
            finally { $zip.Dispose() }
            Remove-Item -LiteralPath $ttZip -Force -ErrorAction SilentlyContinue
        }
    } catch { Write-Host "TexTools install error: $($_.Exception.Message)" -ForegroundColor Yellow }
    if (Test-Path -LiteralPath $ttExe) { Write-Host "TexTools installed." -ForegroundColor Green }
    else { Write-Host "TexTools FAILED to install." -ForegroundColor Red; Add-Failure 'TexTools' }
}

# FFLogs Uploader - not on any package manager; electron-builder lands in "Programs\FF Logs Uploader".
$ffDirs = @("$env:LOCALAPPDATA\Programs\FF Logs Uploader", "$env:LOCALAPPDATA\Programs\fflogs", "$env:LOCALAPPDATA\FFLogs")
if ($ffDirs | Where-Object { Test-Path -LiteralPath $_ }) { Write-Host "FFLogs Uploader already installed, skipping..." -ForegroundColor Yellow }
else {
    Write-Host "Installing FFLogs Uploader..." -ForegroundColor Cyan
    try {
        $ffRel = Invoke-RestMethod 'https://api.github.com/repos/RPGLogs/Uploaders-fflogs/releases/latest' -Headers @{ 'User-Agent' = 'PCSetup' }
        $ffAsset = $ffRel.assets | Where-Object { $_.name -like '*.exe' } | Select-Object -First 1
        if (-not $ffAsset) { throw "No FFLogs installer asset in release $($ffRel.tag_name)" }
        $ffFile = Join-Path $env:TEMP 'FFLogs-Setup.exe'
        & curl.exe -fL -sS -o $ffFile $ffAsset.browser_download_url
        Start-Process -FilePath $ffFile -ArgumentList '/S' -Wait
    } catch { Write-Host "FFLogs install error: $($_.Exception.Message)" -ForegroundColor Yellow }
    if (Wait-InstalledCheck { [bool]($ffDirs | Where-Object { Test-Path -LiteralPath $_ }) }) { Write-Host "FFLogs Uploader installed." -ForegroundColor Green }
    else { Write-Host "FFLogs Uploader FAILED to install." -ForegroundColor Red; Add-Failure 'FFLogs Uploader' }
}

# Claude Code (native installer, ~\.local\bin, updates itself).
$localBin = Join-Path $env:USERPROFILE '.local\bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (@($userPath -split ';') -contains $localBin)) {
    [Environment]::SetEnvironmentVariable('Path', (@(@($userPath -split ';' | Where-Object { $_ }) + $localBin) -join ';'), 'User')
}
if (-not (@($env:Path -split ';') -contains $localBin)) { $env:Path = "$env:Path;$localBin" }
if (Test-Path -LiteralPath (Join-Path $localBin 'claude.exe')) { Write-Host "Claude Code already installed, skipping..." -ForegroundColor Yellow }
else {
    Write-Host "Installing Claude Code..." -ForegroundColor Cyan
    try {
        $installer = Join-Path $env:TEMP 'claude-install.ps1'
        & curl.exe -fL -sS -o $installer 'https://claude.ai/install.ps1'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer | Out-Host
    } catch { Write-Host "Claude Code install error: $($_.Exception.Message)" -ForegroundColor Yellow }
    if (Test-Path -LiteralPath (Join-Path $localBin 'claude.exe')) { Write-Host "Claude Code installed." -ForegroundColor Green }
    else { Write-Host "Claude Code FAILED to install." -ForegroundColor Red; Add-Failure 'Claude Code' }
}

Write-Host ""
$exitCode = 0
if ($failures.Count -gt 0) {
    Write-Host "Per-user apps finished with failures: $($failures -join ', ') - the next sign-in tries again." -ForegroundColor Red
    $exitCode = 1
}
else { Write-Host "Per-user apps: everything is installed." -ForegroundColor Green }
try { Stop-Transcript | Out-Null } catch { }
$mutex.ReleaseMutex()
exit $exitCode
