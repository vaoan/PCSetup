# repair-discord.ps1
# Repairs a Discord install that opens and closes itself, or dies at first launch with
# "A fatal Javascript error occured" (InconsistentInstallerState). Launched by repair-discord.bat.
#
# Both failures were seen on this PC on 2026-09-18 and neither is fixed by a plain reinstall:
#
#   1. Self-quit seconds after the main window loads.
#      %APPDATA%\discord\settings.json carried USE_PINNED_UPDATE_MANIFEST=true (plus
#      SKIP_HOST_UPDATE=true), left behind by Discord's own x86-to-x64 migration. With that key set
#      Discord reads pinned_update.json at startup and, when the file is gone, calls its fatal()
#      handler: message box, then app.quit(). Fix: drop both keys.
#
#   2. "Attempt to install host that is currently running" on the first launch.
#      A silent install (DiscordSetup.exe -s, what 2-setup-windows.bat uses) lays down the files but
#      does not register the host in installer.db. The first launch builds an empty database, asks
#      for the latest build and, when that equals the installed one, refuses to install over itself.
#      Fix: reinstall with the installer in its normal mode, which registers the host and launches
#      the app itself.
#
# Check -> act -> verify: each fix runs only when its symptom is present (so a healthy install is
# left alone), is re-read afterwards, and the app is finally launched and watched for 30 s. A
# self-quit inside that window is a failure, with the log paths to look at. Exit 0 = healthy.
#
# Parameters:
#   -Channel    stable (default), canary or ptb
#   -Reinstall  force the reinstall even when installer.db looks registered
#   -NoLaunch   repair only; do not launch Discord afterwards (skips the 30 s watch)
#
# Discord must not run elevated (drag-and-drop and the overlay break), so the installer and the
# app are launched through explorer.exe, which runs them at the desktop's normal integrity level
# even though this script is elevated.

param(
    [ValidateSet('stable', 'canary', 'ptb')]
    [string]$Channel = 'stable',
    [switch]$Reinstall,
    [switch]$NoLaunch
)

# Auto-elevate to Administrator (forwarding any parameters)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $fwd = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Channel $Channel"
    if ($Reinstall) { $fwd += " -Reinstall" }
    if ($NoLaunch)  { $fwd += " -NoLaunch" }
    Start-Process PowerShell -ArgumentList $fwd -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:LOCALAPPDATA 'PCSetup'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir 'repair-discord.log'
try { Start-Transcript -Path $logFile -Append | Out-Null } catch { }

# ---------------------------------------------------------------------------------------------
# Channel layout
# ---------------------------------------------------------------------------------------------
$layouts = @{
    stable = @{ Local = 'Discord';       Roaming = 'discord';       Exe = 'Discord.exe';       Setup = 'DiscordSetup.exe' }
    canary = @{ Local = 'DiscordCanary'; Roaming = 'discordcanary'; Exe = 'DiscordCanary.exe'; Setup = 'DiscordCanarySetup.exe' }
    ptb    = @{ Local = 'DiscordPTB';    Roaming = 'discordptb';    Exe = 'DiscordPTB.exe';    Setup = 'DiscordPTBSetup.exe' }
}
$layout      = $layouts[$Channel]
$installDir  = Join-Path $env:LOCALAPPDATA $layout.Local
$userData    = Join-Path $env:APPDATA $layout.Roaming
$processName = [IO.Path]::GetFileNameWithoutExtension($layout.Exe)
$setupName   = [IO.Path]::GetFileNameWithoutExtension($layout.Setup)
$settingsPath = Join-Path $userData 'settings.json'
$pinnedPath   = Join-Path $userData 'pinned_update.json'
$dbPath       = Join-Path $installDir 'installer.db'
$installerUrl = "https://discord.com/api/downloads/distributions/app/installers/latest?channel=$Channel&platform=win&arch=x64"
# An unregistered installer.db is 12 KB (one empty schema); a registered one is several hundred KB.
$dbRegisteredMinBytes = 65536

$failures = New-Object System.Collections.Generic.List[string]
$actions  = New-Object System.Collections.Generic.List[string]

function Write-Step  { param([string]$Text) Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Text) Write-Host "  OK  $Text" -ForegroundColor Green }
function Write-Info  { param([string]$Text) Write-Host "      $Text" -ForegroundColor Gray }
function Write-Warn  { param([string]$Text) Write-Host "  !!  $Text" -ForegroundColor Yellow }
function Write-Fail  { param([string]$Text) Write-Host "  XX  $Text" -ForegroundColor Red }

function Get-AppFolder {
    # Newest app-<version> folder that actually contains the executable.
    Get-ChildItem -Path $installDir -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName $layout.Exe) } |
        Sort-Object { try { [version]($_.Name -replace '^app-', '') } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
}

function Get-ChannelProcesses {
    Get-Process -Name $processName -ErrorAction SilentlyContinue
}

function Start-Unelevated {
    # explorer.exe launches the target at the desktop's integrity level, not ours.
    param([string]$Path)
    Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "`"$Path`"" | Out-Null
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSeconds, [int]$IntervalSeconds = 2)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return (& $Condition)
}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $settingsPath)) { return $null }
    try { return (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json) }
    catch { Write-Warn "settings.json could not be parsed: $($_.Exception.Message)"; return $null }
}

function Test-SettingTrue {
    param($Settings, [string]$Name)
    if ($null -eq $Settings) { return $false }
    $prop = $Settings.PSObject.Properties[$Name]
    return ($null -ne $prop -and [bool]$prop.Value)
}

function Get-LatestCrashlog {
    Get-ChildItem -Path (Join-Path $userData 'module_data\crashlogs') -Filter '*-events.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Test-CurrentSessionQuit {
    # The crashlog is a sequence of sessions, each opened by a "Discord starting:" line. Only a
    # before-quit inside the LAST session is the running app quitting. Earlier sessions are not:
    # the normal-mode installer runs Discord once with --squirrel-install (one full session that
    # ends in before-quit) seconds before the real launch, and counting that reported a healthy
    # reinstall as "quit within 30 s". Timestamps are not compared for the same reason.
    param([string]$Path)
    $lines = @(Get-Content -LiteralPath $Path -Tail 200)
    $lastStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match 'Discord starting:') { $lastStart = $i } }
    if ($lastStart -lt 0) { return $false }
    foreach ($line in $lines[$lastStart..($lines.Count - 1)]) { if ($line -match 'before-quit') { return $true } }
    return $false
}

Write-Host "Discord repair ($Channel)" -ForegroundColor White
Write-Info "install dir : $installDir"
Write-Info "user data   : $userData"
Write-Info "log         : $logFile"

# ---------------------------------------------------------------------------------------------
# 1. Settings: stale pinned-manifest keys
# ---------------------------------------------------------------------------------------------
Write-Step "settings.json"
$settings = Read-Settings
if ($null -eq $settings) {
    Write-Ok "no settings.json (nothing to repair)"
}
else {
    $pinned = Test-SettingTrue $settings 'USE_PINNED_UPDATE_MANIFEST'
    $skip   = Test-SettingTrue $settings 'SKIP_HOST_UPDATE'
    $pinnedFileExists = Test-Path -LiteralPath $pinnedPath
    if ($pinned -and -not $pinnedFileExists) {
        Write-Warn "USE_PINNED_UPDATE_MANIFEST is set but pinned_update.json is missing: Discord quits itself at startup"
        $backup = "$settingsPath.bak-$(Get-Date -Format 'yyyy-MM-dd-HHmmss')"
        Copy-Item -LiteralPath $settingsPath -Destination $backup -Force
        foreach ($key in 'USE_PINNED_UPDATE_MANIFEST', 'SKIP_HOST_UPDATE') {
            if ($settings.PSObject.Properties[$key]) { $settings.PSObject.Properties.Remove($key) }
        }
        # No BOM: Discord reads this with Node's fs + JSON.parse, which rejects a leading U+FEFF.
        [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
        $actions.Add("removed USE_PINNED_UPDATE_MANIFEST/SKIP_HOST_UPDATE from settings.json (backup: $backup)")

        $after = Read-Settings
        if ((Test-SettingTrue $after 'USE_PINNED_UPDATE_MANIFEST') -or (Test-SettingTrue $after 'SKIP_HOST_UPDATE')) {
            $failures.Add("settings.json still contains the pinned-manifest keys after the rewrite")
            Write-Fail "keys still present after rewrite"
        }
        else {
            Write-Ok "keys removed; backup at $backup"
        }
    }
    elseif ($pinned) {
        Write-Ok "USE_PINNED_UPDATE_MANIFEST is set and pinned_update.json exists (a valid pin; left alone)"
    }
    else {
        $note = if ($skip) { " (SKIP_HOST_UPDATE is set on its own; harmless, left alone)" } else { "" }
        Write-Ok "no pinned-manifest keys$note"
    }
}

# ---------------------------------------------------------------------------------------------
# 2. Install registration
# ---------------------------------------------------------------------------------------------
Write-Step "install registration"
$appFolder = Get-AppFolder
$dbSize = if (Test-Path -LiteralPath $dbPath) { (Get-Item -LiteralPath $dbPath).Length } else { -1 }
$reasons = New-Object System.Collections.Generic.List[string]
if ($Reinstall)                                            { $reasons.Add("-Reinstall requested") }
if (-not (Test-Path (Join-Path $installDir 'Update.exe'))) { $reasons.Add("Update.exe is missing") }
if ($null -eq $appFolder)                                  { $reasons.Add("no app-<version> folder contains $($layout.Exe)") }
if ($dbSize -lt 0)                                         { $reasons.Add("installer.db is missing (first launch would build an empty one and refuse to install over itself)") }
elseif ($dbSize -lt $dbRegisteredMinBytes)                 { $reasons.Add("installer.db is only $dbSize bytes: the host is not registered") }

if ($reasons.Count -eq 0) {
    Write-Ok "$($appFolder.Name) present, installer.db $dbSize bytes"
}
else {
    foreach ($r in $reasons) { Write-Warn $r }

    $installer = Join-Path $env:TEMP $layout.Setup
    Write-Info "downloading the x64 installer..."
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    & curl.exe -sSL --fail -o $installer $installerUrl
    $downloaded = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $installer) -and ((Get-Item -LiteralPath $installer).Length -gt 50MB)
    $signature = if ($downloaded) { Get-AuthenticodeSignature -LiteralPath $installer } else { $null }
    $signedByDiscord = $signature -and $signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'Discord'

    if (-not $downloaded) {
        $failures.Add("installer download failed (curl exit $LASTEXITCODE)")
        Write-Fail "download failed"
    }
    elseif (-not $signedByDiscord) {
        $failures.Add("installer signature is not a valid Discord signature (status: $($signature.Status), signer: $($signature.SignerCertificate.Subject))")
        Write-Fail "installer signature check failed; not running it"
    }
    else {
        Write-Ok "installer downloaded and signed by $($signature.SignerCertificate.Subject -replace '^CN=([^,]+).*', '$1')"

        $running = Get-ChannelProcesses
        if ($running) {
            Write-Info "closing $($running.Count) $processName process(es)"
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Wait-Until -Condition { -not (Get-ChannelProcesses) } -TimeoutSeconds 20 | Out-Null
        }
        if (Test-Path -LiteralPath $installDir) {
            Remove-Item -LiteralPath $installDir -Recurse -Force
        }
        # Normal mode on purpose: the silent -s install is what leaves installer.db unregistered.
        Write-Info "running the installer (normal mode; it launches Discord itself when done)"
        Start-Unelevated -Path $installer
        $actions.Add("reinstalled from $installerUrl")

        if (-not (Wait-Until -Condition { Get-Process -Name $setupName -ErrorAction SilentlyContinue } -TimeoutSeconds 30 -IntervalSeconds 1)) {
            $failures.Add("the installer never started (explorer.exe launch failed?)")
            Write-Fail "installer did not start"
        }
        elseif (-not (Wait-Until -Condition { -not (Get-Process -Name $setupName -ErrorAction SilentlyContinue) } -TimeoutSeconds 600 -IntervalSeconds 3)) {
            $failures.Add("the installer is still running after 10 minutes")
            Write-Fail "installer did not finish"
        }
        else {
            $registered = Wait-Until -TimeoutSeconds 90 -Condition {
                (Get-AppFolder) -and (Test-Path -LiteralPath $dbPath) -and ((Get-Item -LiteralPath $dbPath).Length -ge $dbRegisteredMinBytes)
            }
            $appFolder = Get-AppFolder
            $dbSize = if (Test-Path -LiteralPath $dbPath) { (Get-Item -LiteralPath $dbPath).Length } else { -1 }
            if ($registered) {
                Write-Ok "$($appFolder.Name) installed, installer.db $dbSize bytes"
            }
            else {
                $failures.Add("after the reinstall installer.db is $dbSize bytes and app folder is '$(if ($appFolder) { $appFolder.Name } else { 'missing' })'")
                Write-Fail "install still looks unregistered"
            }
        }
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------------------------
# 3. Launch and watch
# ---------------------------------------------------------------------------------------------
Write-Step "launch check"
if ($NoLaunch) {
    Write-Info "-NoLaunch: skipped"
}
elseif ($failures.Count -gt 0) {
    Write-Warn "skipped because a repair step failed"
}
else {
    $appFolder = Get-AppFolder
    $existing = Get-ChannelProcesses
    if ($existing) {
        Write-Info "$processName is already running (started $(($existing | Sort-Object StartTime | Select-Object -First 1).StartTime.ToString('HH:mm:ss'))); watching it"
    }
    else {
        Write-Info "starting $($layout.Exe) at normal integrity"
        Start-Unelevated -Path (Join-Path $appFolder.FullName $layout.Exe)
        if (-not (Wait-Until -Condition { Get-ChannelProcesses } -TimeoutSeconds 20 -IntervalSeconds 1)) {
            $failures.Add("$processName did not start")
            Write-Fail "did not start"
        }
    }

    if ($failures.Count -eq 0) {
        Write-Info "watching for 30 s..."
        Start-Sleep -Seconds 30
        $alive = Get-ChannelProcesses
        $crashlog = Get-LatestCrashlog
        $quitLogged = $false
        if ($crashlog) { $quitLogged = Test-CurrentSessionQuit -Path $crashlog.FullName }
        if ($alive -and -not $quitLogged) {
            $main = $alive | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
            Write-Ok "$processName is still running after 30 s$(if ($main) { " (window: '$($main.MainWindowTitle)')" })"
        }
        else {
            $failures.Add("$processName quit within 30 s of launching")
            Write-Fail "$processName quit within 30 s of launching"
            Write-Info "look at: $userData\sentry\scope_v3.json (breadcrumbs; search for 'fatal:')"
            Write-Info "         $userData\logs\Discord_updater_rCURRENT.log"
            if ($crashlog) { Write-Info "         $($crashlog.FullName)" }
        }
    }
}

# ---------------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------------
Write-Host ""
if ($actions.Count -gt 0) {
    Write-Host "Actions:" -ForegroundColor White
    foreach ($a in $actions) { Write-Host "  - $a" }
}
else {
    Write-Host "Nothing needed repairing." -ForegroundColor White
}
if ($failures.Count -gt 0) {
    Write-Host "FAILED:" -ForegroundColor Red
    foreach ($f in $failures) { Write-Host "  - $f" -ForegroundColor Red }
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
Write-Host "Discord ($Channel) is healthy." -ForegroundColor Green
try { Stop-Transcript | Out-Null } catch { }
exit 0
