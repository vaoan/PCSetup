# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ============================================================================
# THE Cloudflare setup - the one entry point (setup-cloudflare.bat runs this).
# ============================================================================
# Brings every Cloudflare-served thing on this PC online after a format:
#   - web tunnel   ffxivbe-tunnel  www / chat.ffxiv.be
#   - SSH tunnel   ssh-tunnel      pc.ffxiv.be   (+ OpenSSH Server, Mac key)
#   - console      dev-console     console / dev / code / ttyd / tools / git.ffxiv.be
#                  (WSL services, sshwifty, proxies, Access gating, scheduled tasks)
#   - watchdog     ConsoleHealth   restarts dead origin pieces every 5 min
# and then verifies the lot. Safe to re-run: every step checks before it acts.
#
# The other scripts in this folder are its building blocks, not entry points.
# This replaced install-all.ps1 + post-format-recovery.ps1, which duplicated
# the tunnel installers with tasks that skipped tunnel-supervisor.ps1 (so the
# tunnels died at every reboot) and stopped to wait for a key press.
#
# If WSL is not ready yet (a reboot is pending), it schedules itself to run
# again at the next sign-in and says so - there is still only one thing to run.
# ============================================================================

# Continue, not Stop: under Stop, Windows PowerShell 5.1 turns any stderr line of a native command
# (wsl, cloudflared, curl) into a terminating error. Every step checks its result explicitly.
$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

$scriptDir   = $PSScriptRoot
$repoRoot    = Split-Path -Parent $scriptDir
$secretsPath = Join-Path $repoRoot '.secrets'
$distro      = 'Ubuntu-24.04'
$cfExe       = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$adminKeys   = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$resumeName  = 'PCSetup-Cloudflare'
$logDir      = Join-Path $env:LOCALAPPDATA 'PCSetup'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
try { Start-Transcript -Path (Join-Path $logDir 'setup-cloudflare.log') -Append | Out-Null } catch { }

$failures = New-Object System.Collections.Generic.List[string]
$started  = Get-Date

# QuickEdit off for this console: one click inside the window starts a text selection and conhost
# then blocks every write until Esc/Enter, so the run looks frozen (title "Select Administrator:").
# That froze the third real run of this script at step 3. Same guard as step 0 and remote-call.ps1.
try {
    Add-Type -Namespace PCSetup -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@ -ErrorAction Stop
    $stdin = [PCSetup.ConsoleMode]::GetStdHandle(-10)
    $mode = [uint32]0
    if ([PCSetup.ConsoleMode]::GetConsoleMode($stdin, [ref]$mode)) {
        [void][PCSetup.ConsoleMode]::SetConsoleMode($stdin, (($mode -band (-bnot [uint32]0x40)) -bor [uint32]0x80))
    }
} catch { }

function Write-Step([string]$n, [string]$text) { Write-Host ""; Write-Host "[$n] $text" -ForegroundColor Cyan }
function Write-Ok([string]$text)   { Write-Host "  OK  $text" -ForegroundColor Green }
function Write-Warn([string]$text) { Write-Host "  !!  $text" -ForegroundColor Yellow }
function Write-Bad([string]$text)  { Write-Host "  XX  $text" -ForegroundColor Red }

# Every building block runs in its own Windows PowerShell so its own `exit` cannot end this
# script; the exit code is the only thing trusted, and the step then re-checks the result.
# Started with Start-Process -NoNewWindow and awaited with WaitForExit(), never piped or captured:
# setup-console-windows.ps1 starts long-lived services (sshwifty, the node proxies, cloudflared)
# that inherit the child's stdout. When this script read that stdout through a pipe (`| Out-Host`,
# or `$rc = & ...` inside a function, which captures too) it waited for EOF - until those services
# exit, i.e. forever. That hung the first real run right after step 7. Here the child shares the
# console and only the process itself is awaited. `.Handle` is touched before waiting, or ExitCode
# comes back $null after the process has exited.
# The child's output goes to a per-step FILE (a file, not a pipe: services that inherit the handle
# cannot block anything by holding it) and is tailed live into this window, so it is both visible
# and in the transcript. The file name is unique per run because a service can keep it open.
$partLogDir = Join-Path $logDir 'setup-cloudflare-parts'
New-Item -ItemType Directory -Path $partLogDir -Force | Out-Null
Get-ChildItem -LiteralPath $partLogDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Show-NewLines($Reader) {
    while ($null -ne ($line = $Reader.ReadLine())) { Write-Host "    $line" }
}

function Invoke-Part([string]$File, [string[]]$Arguments = @()) {
    $path = Join-Path $scriptDir $File
    if (-not (Test-Path -LiteralPath $path)) { throw "$File is missing from $scriptDir" }
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$path`""
    foreach ($a in $Arguments) { $argLine += if ($a -match '\s') { " `"$a`"" } else { " $a" } }
    $out = Join-Path $partLogDir "$runStamp-$([IO.Path]::GetFileNameWithoutExtension($File)).log"
    $err = "$out.err"
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle
    $reader = $null
    try {
        while (-not $p.HasExited) {
            if (-not $reader -and (Test-Path -LiteralPath $out)) {
                $fs = [IO.File]::Open($out, 'Open', 'Read', 'ReadWrite, Delete')
                $reader = New-Object IO.StreamReader($fs)
            }
            if ($reader) { Show-NewLines $reader }
            Start-Sleep -Milliseconds 500
        }
        $p.WaitForExit()
        if (-not $reader -and (Test-Path -LiteralPath $out)) {
            $reader = New-Object IO.StreamReader([IO.File]::Open($out, 'Open', 'Read', 'ReadWrite, Delete'))
        }
        if ($reader) { Show-NewLines $reader }
    } finally {
        if ($reader) { $reader.Dispose() }
    }
    if ((Test-Path -LiteralPath $err) -and (Get-Item -LiteralPath $err).Length -gt 0) {
        Get-Content -LiteralPath $err -Tail 15 | ForEach-Object { Write-Host "    [stderr] $_" -ForegroundColor DarkYellow }
    }
    return $p.ExitCode
}

function Test-TaskRunning([string]$Name) {
    $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    return ($t -and $t.State -eq 'Running')
}

function Wait-For([scriptblock]$Condition, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Seconds 2 }
    return [bool](& $Condition)
}

function Get-SecretKeys {
    if (-not (Test-Path -LiteralPath $secretsPath)) { return @() }
    return @(Get-Content -LiteralPath $secretsPath | Where-Object { $_ -match '^[A-Z0-9_]+=\S' } | ForEach-Object { ($_ -split '=', 2)[0] })
}

function Register-Resume {
    $bat = Join-Path $scriptDir 'setup-cloudflare.bat'
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    Set-ItemProperty -Path $key -Name $resumeName -Value "cmd.exe /c `"$bat`""
    return ((Get-ItemProperty -Path $key -Name $resumeName -ErrorAction SilentlyContinue).$resumeName -like "*setup-cloudflare.bat*")
}

function Complete([int]$Code) {
    $mins = [int]((Get-Date) - $started).TotalMinutes
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    if ($Code -eq 0) {
        Write-Host "  Cloudflare setup complete ($mins min) - everything verified." -ForegroundColor Green
    } elseif ($Code -eq 2) {
        Write-Host "  Paused for a reboot ($mins min)." -ForegroundColor Yellow
    } else {
        Write-Host "  Cloudflare setup finished with $($failures.Count) problem(s) ($mins min):" -ForegroundColor Red
        foreach ($f in $failures) { Write-Host "    - $f" -ForegroundColor Red }
        Write-Host "  Re-run setup-cloudflare.bat after fixing; finished steps are skipped." -ForegroundColor Gray
    }
    Write-Host "  Log: $(Join-Path $logDir 'setup-cloudflare.log')" -ForegroundColor Gray
    Write-Host "============================================" -ForegroundColor Cyan
    try { Stop-Transcript | Out-Null } catch { }
    exit $Code
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Cloudflare setup (tunnels + web console)" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name $resumeName -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------------------------
# 1. Secrets - everything below reads .secrets; without them nothing can be provisioned.
# ---------------------------------------------------------------------------------------------
Write-Step '1/8' 'Secrets'
$required = 'CLOUDFLARE_ACCOUNT_API_TOKEN', 'FFXIVBE_PEM_B64', 'SSHWIFTY_CONF_B64'
$missing = @($required | Where-Object { $_ -notin (Get-SecretKeys) })
if ($missing.Count -gt 0) {
    Write-Warn "missing from .secrets: $($missing -join ', ') - syncing from GitHub"
    $rc = Invoke-Part 'sync-secrets.ps1'
    $missing = @($required | Where-Object { $_ -notin (Get-SecretKeys) })
}
if ($missing.Count -gt 0) {
    $failures.Add("secrets missing: $($missing -join ', ') (sync-secrets needs 'gh auth login' and %USERPROFILE%\.pcsetup-sync-passphrase)")
    Write-Bad 'cannot continue without them'
    Complete 1
}
Write-Ok ".secrets has $($required -join ', ')"

# ---------------------------------------------------------------------------------------------
# 2. cloudflared - the official MSI. Smart App Control blocks unsigned builds, and every script
#    here uses the MSI path, so a Scoop/Chocolatey copy on PATH does not count.
# ---------------------------------------------------------------------------------------------
Write-Step '2/8' 'cloudflared (official MSI)'
if (-not (Test-Path -LiteralPath $cfExe)) {
    $msi = Join-Path $env:TEMP 'cloudflared-windows-amd64.msi'
    & curl.exe -sSL --fail --retry 3 --retry-all-errors -o $msi 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi'
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $msi)) {
        $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$msi`"", '/quiet', '/norestart' -Wait -PassThru
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
    }
}
if (Test-Path -LiteralPath $cfExe) {
    Write-Ok ((& $cfExe --version 2>&1 | Select-Object -First 1) -as [string])
} else {
    $failures.Add('cloudflared MSI did not install')
    Write-Bad 'cloudflared is not installed; nothing else can work'
    Complete 1
}

# ---------------------------------------------------------------------------------------------
# 3. Web tunnel (www / chat) and 4. SSH tunnel (pc) - both run under tunnel-supervisor.ps1.
# ---------------------------------------------------------------------------------------------
# One retry each: the installers call the Cloudflare API, and a single timeout there
# ("Client.Timeout exceeded while awaiting headers", seen on a real run) is a blip, not a verdict.
Write-Step '3/8' 'Web tunnel: www.ffxiv.be, chat.ffxiv.be'
$rc = Invoke-Part 'install-tunnel.ps1'
if ($rc -ne 0 -or -not (Wait-For { Test-TaskRunning 'ffxivbe-tunnel' } 30)) {
    Write-Warn "install-tunnel.ps1 exited $rc; retrying once in 20 s"
    Start-Sleep -Seconds 20
    $rc = Invoke-Part 'install-tunnel.ps1'
}
if ($rc -eq 0 -and (Wait-For { Test-TaskRunning 'ffxivbe-tunnel' } 30)) { Write-Ok 'ffxivbe-tunnel task running' }
else { $failures.Add("web tunnel: installer exit $rc, task running=$(Test-TaskRunning 'ffxivbe-tunnel')"); Write-Bad 'web tunnel incomplete' }

Write-Step '4/8' 'SSH tunnel: pc.ffxiv.be (+ OpenSSH Server)'
$sshOk = { ((Get-Service sshd -ErrorAction SilentlyContinue).Status -eq 'Running') -and (Test-TaskRunning 'ssh-tunnel') }
# The Mac's public key is read at run time, never written in this file (its comment names the
# owner): MAC_SSH_PUBLIC_KEY in .secrets, else the key already installed on this PC.
$macKey = ''
if (Test-Path -LiteralPath $secretsPath) {
    $line = Get-Content -LiteralPath $secretsPath | Where-Object { $_ -match '^MAC_SSH_PUBLIC_KEY=ssh-' } | Select-Object -First 1
    if ($line) { $macKey = ($line -split '=', 2)[1].Trim() }
}
if (-not $macKey -and (Test-Path -LiteralPath $adminKeys)) {
    $macKey = [string](Get-Content -LiteralPath $adminKeys | Where-Object { $_ -match '^ssh-' } | Select-Object -First 1)
}
$sshArgs = @()
if ($macKey) { $sshArgs = @('-MacPublicKey', $macKey) }
else { Write-Warn 'no MAC_SSH_PUBLIC_KEY in .secrets and no installed key - SSH from the Mac will be denied until one is added' }
$rc = Invoke-Part 'install-ssh-tunnel.ps1' $sshArgs
if ($rc -ne 0 -or -not (Wait-For $sshOk 30)) {
    Write-Warn "install-ssh-tunnel.ps1 exited $rc; retrying once in 20 s"
    Start-Sleep -Seconds 20
    $rc = Invoke-Part 'install-ssh-tunnel.ps1' $sshArgs
}
if ($rc -eq 0 -and (Wait-For $sshOk 30)) { Write-Ok 'ssh-tunnel task running, sshd running' }
else { $failures.Add("SSH tunnel: installer exit $rc, task running=$(Test-TaskRunning 'ssh-tunnel'), sshd=$((Get-Service sshd -ErrorAction SilentlyContinue).Status)"); Write-Bad 'SSH tunnel incomplete' }

# ---------------------------------------------------------------------------------------------
# 5. WSL - the console lives in Ubuntu-24.04. If it is not usable yet, the usual cause is a
#    pending reboot after 0-init-prereqs enabled the features: resume after it, automatically.
# ---------------------------------------------------------------------------------------------
Write-Step '5/8' "WSL ($distro)"
function Test-DistroUsable {
    $out = & wsl.exe -d $distro --user root -- echo ok 2>$null
    return ((($out | Out-String) -replace "`0", '').Trim() -eq 'ok')
}
if (-not (Test-DistroUsable)) {
    Write-Warn "$distro does not start; trying to install it"
    & wsl.exe --install -d $distro --no-launch 2>&1 | Out-Host
}
if (Test-DistroUsable) {
    Write-Ok "$distro starts"
} else {
    if (Register-Resume) {
        Write-Warn "$distro still does not start - usually a reboot is pending after WSL was enabled."
        Write-Warn 'REBOOT NOW. This setup runs again by itself at the next sign-in and finishes the console.'
        Write-Host "  (The two tunnels above are already up.)" -ForegroundColor Gray
        Complete 2
    }
    $failures.Add("$distro does not start and the resume entry could not be written")
    Complete 1
}

# ---------------------------------------------------------------------------------------------
# 6. Console, WSL side (sshd, code-server, ttyd, dashboard, ungit, keys) then Windows side
#    (dev-console tunnel + DNS, Access gating, sshwifty, proxies, scheduled tasks).
# ---------------------------------------------------------------------------------------------
Write-Step '6/8' 'Web console: WSL services'
$wslScript = '/mnt/' + $scriptDir.Substring(0, 1).ToLower() + ($scriptDir.Substring(2) -replace '\\', '/') + '/setup-console-wsl.sh'
& wsl.exe -d $distro --user root -- bash $wslScript | Out-Host
if ($LASTEXITCODE -eq 0) { Write-Ok 'setup-console-wsl.sh finished' }
else { $failures.Add("setup-console-wsl.sh exited $LASTEXITCODE"); Write-Bad "setup-console-wsl.sh exited $LASTEXITCODE" }

Write-Step '7/8' 'Web console: tunnel, DNS, Access, sshwifty, tasks'
$rc = Invoke-Part 'setup-console-windows.ps1' @('-SkipVerification')
$missingTasks = @('web-console', 'UpdateWSLPortProxy', 'WSLKeepAlive' | Where-Object { -not (Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue) })
if ($rc -eq 0 -and $missingTasks.Count -eq 0) { Write-Ok 'dev-console tunnel and console tasks installed' }
else {
    $why = "setup-console-windows.ps1 exited $rc"
    if ($missingTasks.Count -gt 0) { $why += "; missing tasks: $($missingTasks -join ', ')" }
    $failures.Add($why); Write-Bad 'console setup incomplete (its output is above)'
}

# The watchdog: without it a dead relay stays dead until someone notices the 502.
$rc = Invoke-Part 'console-health.ps1' @('-Install')
if (Get-ScheduledTask -TaskName 'ConsoleHealth' -ErrorAction SilentlyContinue) { Write-Ok 'ConsoleHealth watchdog scheduled (every 5 min)' }
else { $failures.Add("ConsoleHealth task not installed (exit $rc)"); Write-Bad 'ConsoleHealth watchdog missing' }

# ---------------------------------------------------------------------------------------------
# 8. Verify everything end to end: ports, services, deployed copies, public routes.
# ---------------------------------------------------------------------------------------------
Write-Step '8/8' 'Verification'
$rc = Invoke-Part 'verify-console.ps1'
# www.ffxiv.be is served by the separate web app on 7542, which this repo does not install (see
# CLAUDE.md, "A 530 and a 502 on www/chat mean different things"). When it is the ONLY thing
# failing, everything this setup owns is up: say so plainly instead of calling the setup failed.
$reportJson = Join-Path $env:USERPROFILE '.cloudflared\reports\latest.json'
$failed = @()
if (Test-Path -LiteralPath $reportJson) {
    try { $failed = @((Get-Content -LiteralPath $reportJson -Raw | ConvertFrom-Json).Results | Where-Object { -not $_.Passed }) } catch { }
}
$notOwned = @($failed | Where-Object { ($_.Group -eq 'LocalHTTP' -and $_.Name -eq 'web origin') -or ($_.Group -eq 'Public' -and $_.Name -eq 'www.ffxiv.be') })
if ($rc -eq 0) {
    Write-Ok 'verify-console.ps1 passed (report in %USERPROFILE%\.cloudflared\reports)'
} elseif ($failed.Count -gt 0 -and $failed.Count -eq $notOwned.Count) {
    Write-Ok 'everything this setup owns verified'
    Write-Warn 'www.ffxiv.be answers 502: your web app on 127.0.0.1:7542 is not running (not installed by this setup). The tunnel for it is up.'
} else {
    foreach ($f in $failed) { Write-Bad "$($f.Group) / $($f.Name): $($f.Actual)" }
    $failures.Add("verify-console.ps1 exited $rc - see %USERPROFILE%\.cloudflared\reports\latest.md")
}

Complete $(if ($failures.Count -eq 0) { 0 } else { 1 })
