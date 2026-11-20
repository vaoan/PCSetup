param([string]$Branch = "main")

# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($PSCommandPath) {
        Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Branch `"$Branch`"" -Verb RunAs
    }
    else {
        # Under irm | iex there is no file to re-run ($PSCommandPath is empty), so the elevated
        # copy fetches the entry point again. -EncodedCommand: no quote or pipe has to survive.
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("irm i.ffxiv.be | iex"))
        Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" -Verb RunAs
    }
    exit
}

# The run after a reboot is started by this task (see the end of this file). Remove it first
# thing so it fires exactly once; it is registered again below only if yet another reboot is due.
$resumeTaskName = "PCSetup-resume"
try { Unregister-ScheduledTask -TaskName $resumeTaskName -Confirm:$false -ErrorAction Stop } catch { }
# Older versions resumed through HKCU RunOnce, which needed someone to accept a UAC prompt.
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "PCSetup-resume" -ErrorAction SilentlyContinue

$ErrorActionPreference = "Stop"

# One log per run on the system drive (C:\PCSetup-logs\run-<stamp>.log). Every window closes on
# its own, so this is the only record of what happened. run-all.bat and every numbered script
# append to the same file through PCSETUP_LOG - see sources\start-log.ps1.
if ([string]::IsNullOrWhiteSpace($env:PCSETUP_LOG)) {
    $env:PCSETUP_LOG = Join-Path $env:SystemDrive ("PCSetup-logs\run-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}
function Start-RunLog {
    try {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $env:PCSETUP_LOG) -Force -ErrorAction SilentlyContinue
        $null = Start-Transcript -LiteralPath $env:PCSETUP_LOG -Append -ErrorAction Stop
    }
    catch { }
}
function Stop-RunLog { try { $null = Stop-Transcript -ErrorAction Stop } catch { } }
Start-RunLog
Write-Host ("[remote-call] branch {0} | user {1}\{2} on {3} | {4}" -f $Branch, $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME, [Environment]::OSVersion.VersionString)
Write-Host ("[remote-call] log: {0}" -f $env:PCSETUP_LOG) -ForegroundColor Cyan

# QuickEdit off for this console: with it on, one click inside the window starts a selection
# and conhost blocks every write until Esc - the title reads "Select ..." and the whole run
# looks frozen. Every script run-all calls shares this console, so once here covers the run.
# Same code as Disable-ConsoleQuickEdit in sources\status-line.ps1, which is not downloaded yet.
try {
    if (-not ('PCSetup.ConsoleMode' -as [type])) {
        Add-Type -Namespace PCSetup -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
    }
    $consoleIn = [PCSetup.ConsoleMode]::GetStdHandle(-10)
    $consoleMode = [uint32]0
    if ([PCSetup.ConsoleMode]::GetConsoleMode($consoleIn, [ref]$consoleMode)) {
        [void][PCSetup.ConsoleMode]::SetConsoleMode($consoleIn, (($consoleMode -band (-bnot [uint32]0x40)) -bor [uint32]0x80))
    }
}
catch { }
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

# Server Core images do not always preload the compression assemblies used below.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoZipUrl = "https://github.com/vaoan/PCSetup/archive/refs/heads/$Branch.zip"
$workDir = Join-Path $env:TEMP ("PCSetup-remote-{0}-{1}" -f (Get-Date -Format "yyyyMMddHHmmss"), (Get-Random))
# NOTE: deliberately not "PCSetup-$Branch". GitHub replaces every '/' in a branch
# name with '-' in the archive's top-level folder, so branch fix/foo extracts to
# PCSetup-fix-foo. String-building the name matched zero entries for any branch
# with a slash, the workspace was materialized EMPTY, and the run died much later
# with the thoroughly misleading "run-all.bat was not found in the remote archive"
# - i.e. it looked like a broken download rather than a branch-name bug. The real
# root name is read from the archive itself below.
$repoRootName = $null
$allowedExtensions = @(".bat", ".config", ".v")
# One level of subfolder is materialized too: 0-init-prereqs.bat runs sources\init-prereqs.ps1,
# and a top-level-only workspace made script 0 abort with "Missing prerequisite script".
$allowedSubdirectories = @{ "sources" = @(".ps1", ".reg") }

try {
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    Write-Host "Downloading remote setup archive into memory..." -ForegroundColor Cyan
    $zipBytes = [System.Net.WebClient]::new().DownloadData($repoZipUrl)
    if (-not $zipBytes -or $zipBytes.Length -eq 0) {
        throw "Downloaded archive is empty."
    }

    $memStream = New-Object System.IO.MemoryStream(,$zipBytes)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($memStream, [System.IO.Compression.ZipArchiveMode]::Read)
        try {
            # Resolve the archive's actual top-level folder rather than assuming it.
            $repoRootName = $zip.Entries |
                Where-Object { $_.FullName -match '^[^/]+/' } |
                ForEach-Object { ($_.FullName -split '/')[0] } |
                Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($repoRootName)) {
                throw "Could not determine the archive root folder in $repoZipUrl (branch '$Branch')."
            }
            Write-Host "Archive root: $repoRootName" -ForegroundColor Cyan

            foreach ($entry in $zip.Entries) {
                if ([string]::IsNullOrWhiteSpace($entry.FullName)) { continue }
                if ($entry.FullName -notlike "$repoRootName/*") { continue }
                if ($entry.FullName.EndsWith("/")) { continue }

                $relativePath = ($entry.FullName.Substring($repoRootName.Length + 1)) -replace "/", "\"
                if ($relativePath -like "*..*") { continue }

                $segments = $relativePath.Split("\")
                $extension = [System.IO.Path]::GetExtension($relativePath)
                if ($segments.Count -eq 1) {
                    if ($allowedExtensions -notcontains $extension) { continue }
                }
                elseif ($segments.Count -eq 2 -and $allowedSubdirectories.ContainsKey($segments[0])) {
                    if ($allowedSubdirectories[$segments[0]] -notcontains $extension) { continue }
                }
                else { continue }

                $destinationPath = Join-Path $workDir $relativePath
                $destinationDir = Split-Path $destinationPath -Parent
                if (-not (Test-Path $destinationDir)) {
                    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
                }

                $entryStream = $entry.Open()
                try {
                    $fileStream = [System.IO.File]::Open($destinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $entryStream.CopyTo($fileStream)
                    }
                    finally {
                        $fileStream.Dispose()
                    }
                }
                finally {
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        $memStream.Dispose()
    }

    # Fail where the problem actually is. An empty workspace used to sail on and
    # only blow up much later at the run-all.bat check, which reads as a broken
    # download and sends you looking at the network rather than at the filter above.
    $materialized = @(Get-ChildItem -Path $workDir -File -Recurse)
    if ($materialized.Count -eq 0) {
        throw "No files were materialized from $repoZipUrl (archive root '$repoRootName'). The archive downloaded but nothing matched the allowlist."
    }
    Write-Host ("Materialized {0} files from the archive." -f $materialized.Count) -ForegroundColor Cyan

    $manifestPath = Join-Path $workDir "remote-call.manifest.json"
    $manifest = [ordered]@{
        source = $repoZipUrl
        downloaded_at_utc = (Get-Date).ToUniversalTime().ToString("o")
        workspace = $workDir
        execution_mode = "temp-materialized-from-memory"
        files = @(Get-ChildItem -Path $workDir -File -Recurse | ForEach-Object { $_.FullName.Substring($workDir.Length + 1) } | Sort-Object)
    } | ConvertTo-Json -Depth 4
    Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8

    $env:PCSETUP_REMOTE_CALL = "1"
    if ($env:PCSETUP_CI -eq '1') {
        Write-Host "CI mode detected. Installing container-safe toolchain prerequisites..." -ForegroundColor Cyan

        function Refresh-ProcessPath {
            $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $pathParts = @($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $env:Path = ($pathParts -join ';')
        }

        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            Write-Host "Installing Chocolatey..." -ForegroundColor Cyan
            $chocoInstallScript = (Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -UseBasicParsing -TimeoutSec 180).Content
            Invoke-Expression $chocoInstallScript
            Refresh-ProcessPath
        }

        Write-Host "Installing CI packages..." -ForegroundColor Cyan
        & choco install git python gh nvm -y --no-progress
        if ($LASTEXITCODE -ne 0) {
            throw "Chocolatey package install failed with exit code $LASTEXITCODE."
        }
        Refresh-ProcessPath

        $nvmCandidates = @(
            (Get-Command nvm -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
            (Join-Path $env:APPDATA 'nvm\nvm.exe'),
            'C:\ProgramData\nvm\nvm.exe'
        ) | Where-Object { $_ } | Select-Object -Unique

        $nvmExe = $nvmCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $nvmExe) {
            throw "nvm was not installed successfully."
        }

        $nvmHome = [Environment]::GetEnvironmentVariable('NVM_HOME', 'Machine')
        $nvmSymlink = [Environment]::GetEnvironmentVariable('NVM_SYMLINK', 'Machine')
        if ([string]::IsNullOrWhiteSpace($nvmHome)) {
            $nvmHome = Split-Path $nvmExe -Parent
        }
        if ([string]::IsNullOrWhiteSpace($nvmSymlink)) {
            $nvmSymlink = 'C:\nvm4w\nodejs'
        }

        $env:NVM_HOME = $nvmHome
        $env:NVM_SYMLINK = $nvmSymlink

        if (-not (Test-Path $env:NVM_HOME)) {
            New-Item -ItemType Directory -Path $env:NVM_HOME -Force | Out-Null
        }

        $nvmSymlinkParent = Split-Path $env:NVM_SYMLINK -Parent
        if (-not [string]::IsNullOrWhiteSpace($nvmSymlinkParent) -and -not (Test-Path $nvmSymlinkParent)) {
            New-Item -ItemType Directory -Path $nvmSymlinkParent -Force | Out-Null
        }
        if ((Test-Path $env:NVM_SYMLINK) -and (Get-Item $env:NVM_SYMLINK).PSIsContainer) {
            Remove-Item $env:NVM_SYMLINK -Recurse -Force
        }

        $nvmSettingsPath = Join-Path $env:NVM_HOME 'settings.txt'
        if (-not (Test-Path $nvmSettingsPath)) {
            @(
                "root: $env:NVM_HOME"
                "path: $env:NVM_SYMLINK"
                "arch: 64"
                "proxy: none"
            ) | Set-Content -Path $nvmSettingsPath -Encoding ASCII
        }

        $pathSegments = @(
            $env:NVM_HOME,
            $env:NVM_SYMLINK,
            [Environment]::GetEnvironmentVariable('Path', 'Machine'),
            [Environment]::GetEnvironmentVariable('Path', 'User')
        ) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ -split ';' } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
        $env:Path = $pathSegments -join ';'

        $nodeVersion = '22.19.0'
        Push-Location $env:NVM_HOME
        try {
            $nvmInstallSucceeded = $false
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                & $nvmExe install $nodeVersion
                if ($LASTEXITCODE -eq 0) {
                    $nvmInstallSucceeded = $true
                    break
                }

                if ($attempt -lt 3) {
                    Start-Sleep -Seconds (5 * $attempt)
                }
            }

            if (-not $nvmInstallSucceeded) {
                throw "nvm install $nodeVersion failed after 3 attempts. Last exit code: $LASTEXITCODE."
            }
            & $nvmExe use $nodeVersion
            if ($LASTEXITCODE -ne 0) {
                $versionDir = Join-Path $env:NVM_HOME ("v{0}" -f $nodeVersion)
                $nodeExePath = Join-Path $versionDir 'node.exe'
                # nvm 1.x keeps npm.cmd next to node.exe; nvm 2.x has no npm.cmd (npm is an .exe shim).
                $npmCmdPath = Join-Path $versionDir 'npm.cmd'
                if (-not (Test-Path $nodeExePath) -or -not ((Test-Path $npmCmdPath) -or (Get-Command npm -ErrorAction SilentlyContinue))) {
                    throw "nvm use $nodeVersion failed with exit code $LASTEXITCODE."
                }

                $env:Path = (@($versionDir, $env:Path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
            }
        }
        finally {
            Pop-Location
        }
        Refresh-ProcessPath

        foreach ($commandName in 'choco', 'git', 'python', 'gh', 'nvm', 'node', 'npm') {
            if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
                throw "Required CI command '$commandName' was not available after bootstrap."
            }
        }
    }

    # CI used to `return` here, so the container installed a handful of packages and never ran a
    # single numbered script - the "full install" test asserted against a machine that had only
    # been bootstrapped. The bootstrap above is a prerequisite for the run, not a substitute for
    # it, so both paths now fall through to the runner. Scripts that cannot work in Server Core
    # (2, 5, 6, 10, 11, 99) skip their own bodies on PCSETUP_CI=1.
    $runAllPath = Join-Path $workDir "run-all.bat"
    if (-not (Test-Path $runAllPath)) {
        throw "run-all.bat was not found in the remote archive."
    }

    Write-Host "Executing remote runner from temp workspace: $workDir" -ForegroundColor Cyan
    # The transcript holds the log open; run-all.bat and the scripts append to it themselves.
    Stop-RunLog
    $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$runAllPath`"" -WorkingDirectory $workDir -Wait -PassThru -NoNewWindow
    Start-RunLog
    Write-Host ("[remote-call] run-all.bat exited with code {0}" -f $proc.ExitCode)

    # A fresh machine needs a reboot after the WSL features are enabled, and until then step 0
    # skips the Ubuntu registration (and script 2 skips Claude Code in WSL). On 2026-11-17/18 the
    # setup ran four times without a reboot in between, so Ubuntu was never installed and nothing
    # said why. step 0 now leaves a flag; when it is there the machine reboots by itself and the
    # run resumes at the next sign-in. Capped at 2 resumes so a machine that can never start WSL
    # (virtualization off in the firmware) does not reboot-loop.
    # UNATTENDED: the resume is a scheduled task at logon with RunLevel Highest - it starts
    # elevated with no UAC prompt (HKCU RunOnce + Start-Process -Verb RunAs, the old way, sat at
    # a UAC prompt until someone clicked it). Then shutdown /r /t 60 reboots on its own; a
    # person at the keyboard can cancel with: shutdown /a
    $rebootFlag = Join-Path $env:ProgramData "PCSetup\reboot-required.flag"
    $resumeCountFile = Join-Path $env:ProgramData "PCSetup\resume-count"
    if (Test-Path -LiteralPath $rebootFlag) {
        $resumeCount = 0
        if (Test-Path -LiteralPath $resumeCountFile) { [int]::TryParse((Get-Content -LiteralPath $resumeCountFile -Raw).Trim(), [ref]$resumeCount) | Out-Null }
        if ($Branch -eq "main" -and $resumeCount -lt 2) {
            # The inner command is -EncodedCommand so no quote or pipe has to survive nesting.
            $inner = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("irm i.ffxiv.be | iex"))
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $inner"
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
            $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
            Register-ScheduledTask -TaskName $resumeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            if (-not (Get-ScheduledTask -TaskName $resumeTaskName -ErrorAction SilentlyContinue)) { throw "could not register the $resumeTaskName task" }
            Set-Content -LiteralPath $resumeCountFile -Value ($resumeCount + 1) -Encoding ASCII
            Write-Host ""
            Write-Host "==================================================================" -ForegroundColor Yellow
            Write-Host "  Windows needs a restart to finish WSL/Ubuntu." -ForegroundColor Yellow
            if ($env:PCSETUP_NO_REBOOT -eq "1" -or $env:PCSETUP_CI -eq "1") {
                Write-Host "  PCSETUP_NO_REBOOT/CI set: not rebooting. Reboot when ready;" -ForegroundColor Yellow
                Write-Host "  the setup continues by itself after you sign in." -ForegroundColor Yellow
            }
            else {
                Write-Host "  Rebooting automatically in 60 seconds (cancel: shutdown /a)." -ForegroundColor Yellow
                Write-Host "  The setup continues by itself after you sign in, no prompts." -ForegroundColor Yellow
                & shutdown.exe /r /t 60 /c "PCSetup: reboot to finish WSL/Ubuntu. The setup resumes after sign-in."
            }
            Write-Host "==================================================================" -ForegroundColor Yellow
        }
        else {
            Write-Host "A reboot is still required, but the automatic resume is used up (or this is not main)." -ForegroundColor Yellow
            Write-Host "Reboot, then run again: irm i.ffxiv.be | iex" -ForegroundColor Yellow
        }
    }
    else {
        Remove-Item -LiteralPath $resumeCountFile -Force -ErrorAction SilentlyContinue
    }

    if ($proc.ExitCode -ne 0) {
        throw "Remote runner failed with exit code $($proc.ExitCode)."
    }
}
catch {
    Write-Host ("[remote-call] FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    throw
}
finally {
    Write-Host ("[remote-call] finished {0:yyyy-MM-dd HH:mm:ss}. Log: {1}" -f (Get-Date), $env:PCSETUP_LOG)
    Stop-RunLog
    Remove-Item Env:PCSETUP_REMOTE_CALL -ErrorAction SilentlyContinue
    if (Test-Path $workDir) {
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
