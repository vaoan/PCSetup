# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($args -join ' ')" -Verb RunAs
    exit
}

# Registers sources\per-user-apps.ps1 as the "PCSetup per-user apps" scheduled task, which runs at
# EVERY user's sign-in as that user (group principal BUILTIN\Users, unelevated, hidden). That is
# what lets a new Windows account start with Discord, Claude Code, XIVLauncher and the other apps
# that can only be installed per user, without anyone running a setup script in it.
#
# The task runs a copy in %ProgramData%\PCSetup, not the file next to this one: setup usually runs
# from remote-call.ps1's temp workspace, which is deleted afterwards.
#
# -RunNow then also runs it for the account doing the setup, unelevated, through a one-shot task in
# that user's interactive session, and waits for it, streaming its log here - so
# 2-setup-windows.bat still reports failures for this account the way it always did. When that
# task cannot start (no interactive session, e.g. PowerShell Direct in the VM test) it falls back
# to running the script in this elevated process with -AllowElevated.
#
# Check -> act -> verify; exit 1 if the task is not registered, or the -RunNow pass failed.
#
# Everything here is ASCII on purpose: Windows PowerShell 5.1 reads a BOM-less file as CP1252.
param([switch]$RunNow)

$ErrorActionPreference = 'Continue'
$taskName = 'PCSetup per-user apps'
$source = Join-Path $PSScriptRoot 'per-user-apps.ps1'
$installDir = Join-Path $env:ProgramData 'PCSetup'
$installed = Join-Path $installDir 'per-user-apps.ps1'
$exitCode = 0

if (-not (Test-Path -LiteralPath $source)) { Write-Host "per-user-apps.ps1 not found next to this script." -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $installed -Force
if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $installed).Hash) {
    Write-Host "Could not copy per-user-apps.ps1 to $installDir." -ForegroundColor Red
    exit 1
}

$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installed`""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew -StartWhenAvailable

try {
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    # S-1-5-32-545 = BUILTIN\Users by SID, so a non-English Windows (where the group has another
    # name) resolves it too. Limited = never elevated.
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Installs the per-user-only apps (Discord, Claude Code, ...) for whoever signs in. From PCSetup.' -Force -ErrorAction Stop | Out-Null
} catch { Write-Host "Registering '$taskName' failed: $($_.Exception.Message)" -ForegroundColor Red }

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Write-Host "'$taskName' runs at every user's sign-in." -ForegroundColor Green }
else { Write-Host "'$taskName' is NOT registered." -ForegroundColor Red; exit 1 }

if (-not $RunNow) { exit 0 }

# --- run it now for this account -------------------------------------------------------------
$log = Join-Path $env:LOCALAPPDATA 'PCSetup\per-user-apps.log'
$logStart = if (Test-Path -LiteralPath $log) { (Get-Item -LiteralPath $log).Length } else { 0 }
$oneShot = 'PCSetup per-user apps (setup run)'
$user = "$env:USERDOMAIN\$env:USERNAME"
$started = $false
try {
    $onePrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $oneShot -Action $action -Principal $onePrincipal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $oneShot -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ((Get-ScheduledTask -TaskName $oneShot).State -eq 'Running') { $started = $true; break }
        if ((Get-ScheduledTaskInfo -TaskName $oneShot).LastTaskResult -notin 267011, 267009) { $started = $true; break }  # 0x41303 not yet run, 0x41301 running
        Start-Sleep -Milliseconds 500
    }
} catch { Write-Host "Could not start the per-user run as $user ($($_.Exception.Message))." -ForegroundColor Yellow }

function Show-NewLog {
    if (-not (Test-Path -LiteralPath $log)) { return }
    try {
        $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            if ($fs.Length -le $script:logStart) { return }
            $null = $fs.Seek($script:logStart, 'Begin')
            $text = (New-Object IO.StreamReader($fs)).ReadToEnd()
            $script:logStart = $fs.Length
            if ($text) { Write-Host $text.TrimEnd() }
        } finally { $fs.Dispose() }
    } catch { }
}

if ($started) {
    Write-Host "Installing the per-user apps for $env:USERNAME (unelevated, log: $log)..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes(90)
    while ((Get-ScheduledTask -TaskName $oneShot).State -eq 'Running' -and (Get-Date) -lt $deadline) {
        Show-NewLog
        Start-Sleep -Seconds 3
    }
    Show-NewLog
    $result = (Get-ScheduledTaskInfo -TaskName $oneShot).LastTaskResult
    if ($result -ne 0) { Write-Host "The per-user apps run ended with code $result." -ForegroundColor Red; $exitCode = 1 }
}
else {
    Write-Host "No interactive session to run in; running the per-user apps in this window instead." -ForegroundColor Yellow
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installed -AllowElevated
    if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
}
Unregister-ScheduledTask -TaskName $oneShot -Confirm:$false -ErrorAction SilentlyContinue
exit $exitCode
