# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Strips everything IObit's Driver Booster runs on its own: scheduled tasks, services, kernel
# drivers, Run/RunOnce values, Startup-folder shortcuts and the background processes. The app
# itself stays installed and still runs when opened from its shortcut (with a UAC prompt, since
# the "SkipUAC" task is one of the things removed).
#
# Matched by install path (anything under an "\IObit\" folder), not by a fixed list of names:
# the installer registered "Driver Booster Scheduler", "Driver Booster Update" (both at every
# logon, elevated) and "Driver Booster SkipUAC (<user>)" on 14.0.1, and the names change between
# versions. Every upgrade re-runs the installer and puts them back, which is why
# 2-setup-windows.bat runs this after installing and update-all.bat after the winget step.
#
# Check -> act -> verify: the scan runs again at the end and anything still present is a failure
# (exit 1). Idempotent - a clean machine prints "nothing to remove" and exits 0.

$ErrorActionPreference = 'Continue'
$failures = New-Object System.Collections.ArrayList
$iobitPattern = '\\IObit\\'

function Test-IObitPath([string]$text) { return ($text -and $text -match $iobitPattern) }

$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
$startupFolders = @(
    [Environment]::GetFolderPath('Startup'),
    [Environment]::GetFolderPath('CommonStartup')
)

function Get-IObitAutostarts {
    $items = New-Object System.Collections.ArrayList

    foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $exes = @($task.Actions | ForEach-Object { $_.Execute }) -join ' '
        if ((Test-IObitPath $exes) -or $task.TaskName -match 'Driver Booster|IObit') {
            $null = $items.Add([pscustomobject]@{ Kind = 'Task'; Name = $task.TaskPath + $task.TaskName; Ref = $task })
        }
    }
    foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
        if (Test-IObitPath $svc.PathName) { $null = $items.Add([pscustomobject]@{ Kind = 'Service'; Name = $svc.Name; Ref = $svc }) }
    }
    foreach ($drv in @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue)) {
        if (Test-IObitPath $drv.PathName) { $null = $items.Add([pscustomobject]@{ Kind = 'Driver'; Name = $drv.Name; Ref = $drv }) }
    }
    foreach ($key in $runKeys) {
        $props = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if (Test-IObitPath ([string]$p.Value)) {
                $null = $items.Add([pscustomobject]@{ Kind = 'RunValue'; Name = "$key\$($p.Name)"; Ref = @{ Key = $key; Value = $p.Name } })
            }
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in $startupFolders) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($lnk in @(Get-ChildItem -LiteralPath $folder -Filter *.lnk -ErrorAction SilentlyContinue)) {
            $target = $shell.CreateShortcut($lnk.FullName).TargetPath
            if (Test-IObitPath $target) { $null = $items.Add([pscustomobject]@{ Kind = 'Startup'; Name = $lnk.FullName; Ref = $lnk.FullName }) }
        }
    }
    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $proc.Path } catch {}
        if (Test-IObitPath $path) { $null = $items.Add([pscustomobject]@{ Kind = 'Process'; Name = "$($proc.Name) ($($proc.Id))"; Ref = $proc }) }
    }
    return ,$items
}

function Remove-IObitItem($item) {
    switch ($item.Kind) {
        'Process' { Stop-Process -Id $item.Ref.Id -Force -ErrorAction SilentlyContinue }
        'Task'    { Unregister-ScheduledTask -TaskName $item.Ref.TaskName -TaskPath $item.Ref.TaskPath -Confirm:$false -ErrorAction SilentlyContinue }
        'RunValue' { Remove-ItemProperty -Path $item.Ref.Key -Name $item.Ref.Value -ErrorAction SilentlyContinue }
        'Startup' { Remove-Item -LiteralPath $item.Ref -Force -ErrorAction SilentlyContinue }
        default {
            # Service or kernel driver: stop, disable, delete. A driver still loaded is only
            # marked for deletion until the next reboot; Disabled means it will not load again.
            $name = $item.Ref.Name
            $null = & sc.exe stop $name 2>&1
            $null = & sc.exe config $name start= disabled 2>&1
            $null = & sc.exe delete $name 2>&1
        }
    }
}

# Background processes go first: the scheduler and updater would otherwise re-register what is
# being removed while this runs.
$found = Get-IObitAutostarts
if ($found.Count -eq 0) {
    Write-Host "Driver Booster: no IObit tasks, services, autostarts or background processes - nothing to remove." -ForegroundColor Green
    exit 0
}
$order = 'Process', 'Task', 'Service', 'Driver', 'RunValue', 'Startup'
foreach ($kind in $order) {
    foreach ($item in @($found | Where-Object { $_.Kind -eq $kind })) {
        Write-Host "Removing IObit $($item.Kind.ToLower()): $($item.Name)" -ForegroundColor Cyan
        Remove-IObitItem $item
    }
}
Start-Sleep -Seconds 2

# Verify. A service/driver that is gone or Disabled is done (a loaded driver only disappears at
# reboot); everything else must be gone.
$left = Get-IObitAutostarts
foreach ($item in $left) {
    if ($item.Kind -in 'Service', 'Driver' -and $item.Ref.StartMode -eq 'Disabled') {
        Write-Host "IObit $($item.Kind.ToLower()) $($item.Name) disabled; removed at the next reboot." -ForegroundColor Yellow
        continue
    }
    $null = $failures.Add("$($item.Kind) $($item.Name)")
}

$removedCount = $found.Count - $left.Count
if ($failures.Count -gt 0) {
    Write-Host "Driver Booster cleanup: removed $removedCount of $($found.Count); still present: $($failures -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "Driver Booster cleanup: removed $removedCount item(s); no IObit autostarts left." -ForegroundColor Green
exit 0
