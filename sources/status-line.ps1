# One-line live status for long-running native commands. Dot-sourced by sources\init-prereqs.ps1
# and by the PowerShell that 2-setup-windows.bat, 3-setup-node.bat and 6-setup-games.bat generate
# (`. "<repo>\sources\status-line.ps1"`), so the generated scripts never have to carry this
# through CMD's echo escaping. Lives under sources\ because remote-call.ps1 already materializes
# sources\*.ps1 into the temp workspace.
#
# Everything here is ASCII on purpose: Windows PowerShell 5.1 reads a BOM-less file as CP1252.

function Get-ProgressPercent {
    # Last "NN.N%" in a tool's captured output, or $null. DISM keeps printing its bar when
    # redirected ("[=====   35.0%   ]" lines separated by CR), so this is its real progress.
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Matches($Text, '(\d{1,3}(?:\.\d+)?)%')
    if ($m.Count -eq 0) { return $null }
    return [double]$m[$m.Count - 1].Groups[1].Value
}

function Get-DismLogMessage {
    # The last message in dism.log, without the timestamp/PID/TID noise, so the status line can
    # say what DISM is doing while its own percentage sits still (downloading from Windows
    # Update, staging the payload, ...). Reads only the tail of the file, which grows to MBs.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $take = [Math]::Min(8192, $fs.Length)
            $fs.Seek(-$take, [IO.SeekOrigin]::End) | Out-Null
            $buf = New-Object byte[] $take
            $read = $fs.Read($buf, 0, $take)
            $tail = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        }
        finally { $fs.Close() }
    }
    catch { return '' }
    # Walk back from the end to the last DISM-provider line that still says something once the
    # "PID=.. TID=.." and trailing "- CClass::Method" are gone. CSI lines are shim/WinSxS noise,
    # and the session footer is a bare "DISM.EXE:" - both are skipped.
    $lines = @($tail -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -notmatch '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d, +\w+ +DISM +(.+)$') { continue }
        $msg = $Matches[1] -replace 'PID=\d+ TID=\d+ ', '' -replace ' - \S+\s*$', '' -replace '\s+', ' '
        $msg = $msg.Trim()
        if ($msg -match '\S:\s*$' -or $msg.Length -lt 8) { continue }
        return $msg
    }
    return ''
}

function Get-LastOutputLine {
    # Last non-blank line a tool has printed so far, whitespace squeezed and cut to 100 chars.
    # For a tool that prints no percentage this is the phase indicator: winget's "Downloading
    # https://.../wsl.2.6.1.0.x64.msi" or "Starting package install...", wsl.exe's
    # "Downloading: Ubuntu 24.04 LTS", an installer's own status text. CR-separated progress
    # fragments count as lines too, so the newest one wins.
    param([string]$Text)
    if (-not $Text) { return '' }
    $lines = $Text -split "[`r`n]+" | Where-Object { $_ -match '\S' }
    if (-not $lines) { return '' }
    $last = ($lines[-1] -replace '\s+', ' ').Trim()
    if ($last.Length -gt 100) { $last = $last.Substring(0, 100) }
    return $last
}

function Get-NetworkBytesReceived {
    # Sum of bytes received on every non-loopback interface that is up. Pure .NET, no counters
    # to sample, so it is cheap enough to call twice a second.
    $total = [long]0
    try {
        foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($nic.NetworkInterfaceType -eq 'Loopback') { continue }
            if ($nic.OperationalStatus -ne 'Up') { continue }
            try { $total += $nic.GetIPv4Statistics().BytesReceived } catch { }
        }
    }
    catch { }
    return $total
}

function Get-ServiceProcessIds {
    # PIDs of the processes hosting the named services (Win32_Service). Costs ~220 ms even when
    # warm, so Invoke-CommandWithStatus refreshes it every 5 s rather than on every sample -
    # a service restarting mid-install is picked up on the next refresh.
    param([string[]]$Services)
    $ids = @()
    if (-not $Services) { return $ids }
    $filter = (@($Services | ForEach-Object { "Name='$_'" })) -join ' OR '
    try {
        foreach ($svc in @(Get-CimInstance -ClassName Win32_Service -Filter $filter -ErrorAction Stop)) {
            if ($svc.ProcessId) { $ids += [int]$svc.ProcessId }
        }
    }
    catch { }
    return $ids
}

function Get-WatchedCpuSeconds {
    # Total CPU seconds burned so far by the launched process, any named helper processes
    # (TiWorker/TrustedInstaller for DISM, msiexec for an MSI) and the processes hosting the
    # named services. Services matter because the download half of a DISM enable happens in
    # Windows Update / Delivery Optimization / BITS, which live in svchost.exe and cannot be
    # picked by process name - without them "cpu 0%" showed while the payload was streaming in.
    # Service PIDs come from Get-ServiceProcessIds; the caller passes them as -ExtraIds.
    # Processes come and go during an install, so a negative delta is clamped to 0 by the caller.
    param([int]$ProcessId, [string[]]$Names, [int[]]$ExtraIds)
    $ids = New-Object System.Collections.Generic.HashSet[int]
    if ($ProcessId) { [void]$ids.Add($ProcessId) }
    if ($Names) {
        foreach ($p in @(Get-Process -Name $Names -ErrorAction SilentlyContinue)) { [void]$ids.Add($p.Id) }
    }
    foreach ($id in @($ExtraIds)) { if ($id) { [void]$ids.Add([int]$id) } }
    $secs = 0.0
    foreach ($id in $ids) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p) { try { $secs += $p.TotalProcessorTime.TotalSeconds } catch { } }
    }
    return $secs
}

function Start-CommandCapture {
    # Launches a native command with stdout/stderr captured to temp files and returns a job
    # (a hashtable) that Wait-CommandWithStatus can draw the status line for - now, or minutes
    # later. Splitting start from wait is what lets step 0 kick off the .NET 3.5 enable at the
    # top, install everything else meanwhile, and attach the same line to it only if it is
    # still running when something needs it.
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string[]]$WatchProcess = @(),
        [string[]]$WatchService = @(),
        [string]$ActivityLog = '',
        [string]$GrowthLog = '',
        [double]$QuietSeconds = 1.0
    )
    $stdout = Join-Path $env:TEMP ("pcsetup-status-{0}.out" -f [guid]::NewGuid().ToString('N'))
    $stderr = "$stdout.err"

    # Start-Process rejects an empty string inside -ArgumentList, and a caller that builds its
    # arguments from a variable can easily hand one over.
    $args = @($ArgumentList | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $startParams = @{
        FilePath               = $FilePath
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $stdout
        RedirectStandardError  = $stderr
    }
    if ($args.Count -gt 0) { $startParams['ArgumentList'] = $args }
    $proc = Start-Process @startParams
    # Touch the handle now, or .ExitCode is $null after the process exits (PowerShell only
    # caches the handle on first access; without this DISM's 3010 "reboot required" is lost).
    $null = $proc.Handle

    $job = @{
        Label        = $Label
        Process      = $proc
        Stdout       = $stdout
        Stderr       = $stderr
        WatchProcess = $WatchProcess
        WatchService = $WatchService
        ActivityLog  = $ActivityLog
        GrowthLog    = $GrowthLog
        QuietSeconds = $QuietSeconds
        Clock        = [Diagnostics.Stopwatch]::StartNew()
        GrowthStart  = if ($GrowthLog -and (Test-Path -LiteralPath $GrowthLog)) { (Get-Item -LiteralPath $GrowthLog).Length } else { 0 }
        NetStart     = 0
        NetLast      = 0
        NetLastAt    = 0.0
        NetRate      = 0.0
        CpuLast      = 0.0
        CpuLastAt    = 0.0
        CpuPct       = 0.0
        SvcIds       = @(Get-ServiceProcessIds $WatchService)
        SvcIdsAt     = 0.0
        Tick         = 0
        LastLen      = 0
        LastWholePct = -1
        LastPlainAt  = -60.0
    }
    $job.NetStart = Get-NetworkBytesReceived
    $job.NetLast = $job.NetStart
    $job.CpuLast = Get-WatchedCpuSeconds -ProcessId $proc.Id -Names $WatchProcess -ExtraIds $job.SvcIds
    return $job
}

function Test-CommandCaptureRunning {
    param([Parameter(Mandatory)][hashtable]$Job)
    return (-not $Job.Process.HasExited)
}

function Read-CommandCaptureOutput {
    # The tool still holds the file, so it is opened shared; wsl.exe writes UTF-16, which
    # arrives as text full of NULs, so those are stripped.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::Default); ($sr.ReadToEnd()) -replace "`0", '' } finally { $fs.Close() }
    }
    catch { '' }
}

function Wait-CommandWithStatus {
    # Draws ONE status line in place for a job from Start-CommandCapture until its process
    # exits, then returns @{ ExitCode; Output; Error; Elapsed } and removes the temp files.
    # Nothing is drawn for the job's first QuietSeconds, so quick commands stay silent; a job
    # attached to later than that draws immediately. The line is cut to the window width and
    # overwritten with `r, so a 20-minute step still occupies one row of the log. When output
    # is redirected (CI) a plain line goes out only when the whole percentage changes or every
    # 30 s.
    #
    #   Enabling .NET Framework 3.5 [#######-------------]  37.8% / | 4m 12s | net 2.4 MB/s (61 MB) | cpu 43% | CBS.log +18.3 MB | DISM Package Manager: ...
    #
    # Signals, most important first (the tail is what gets cut on a narrow window):
    #   - the tool's own percentage, when it prints one (DISM does; most installers do not);
    #   - a spinner that ticks every redraw, so the line moves even when every number is flat;
    #   - elapsed time since the job started;
    #   - network receive rate and total since the job began - the one thing that moves while
    #     DISM sits at 37.8 % fetching .NET 3.5 from Windows Update, or wsl --install downloads;
    #   - CPU of the launched process plus -WatchProcess names (TiWorker, msiexec) plus the
    #     svchost processes hosting -WatchService names (wuauserv, DoSvc, BITS): together with
    #     the network figure this says which phase the step is in;
    #   - growth of -GrowthLog (CBS.log grows the whole time servicing works);
    #   - the last real message in -ActivityLog (dism.log).
    param([Parameter(Mandatory)][hashtable]$Job)
    $redirected = try { [Console]::IsOutputRedirected } catch { $true }
    $spinner = '|/-\'
    $cores = [Math]::Max(1, [Environment]::ProcessorCount)
    $proc = $Job.Process
    $fmtElapsed = {
        param([double]$s)
        if ($s -ge 3600) { '{0}h {1:00}m' -f [int][Math]::Floor($s / 3600), [int]([Math]::Floor($s / 60) % 60) }
        else { '{0}m {1:00}s' -f [int][Math]::Floor($s / 60), [int]($s % 60) }
    }
    $fmtBytes = {
        param([double]$b)
        if ($b -ge 1GB) { '{0:0.00} GB' -f ($b / 1GB) } else { '{0:0.0} MB' -f ($b / 1MB) }
    }
    try {
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 500
            $Job.Tick++
            $now = $Job.Clock.Elapsed.TotalSeconds
            if ($now -lt $Job.QuietSeconds) { continue }

            $outText = Read-CommandCaptureOutput $Job.Stdout
            $pct = Get-ProgressPercent $outText
            if ($null -ne $pct) {
                $filled = [int][Math]::Round($pct / 5)
                $head = '{0} [{1}{2}] {3,5:0.0}% {4}' -f $Job.Label, ('#' * $filled), ('-' * (20 - $filled)), $pct, $spinner[$Job.Tick % 4]
            }
            else {
                $head = '{0} {1}' -f $Job.Label, $spinner[$Job.Tick % 4]
            }
            $parts = New-Object System.Collections.Generic.List[string]
            $parts.Add((& $fmtElapsed $now))

            # Rates are sampled once a second, not per tick, so they do not flicker.
            $netNow = Get-NetworkBytesReceived
            if (($now - $Job.NetLastAt) -ge 1.0) {
                $Job.NetRate = [Math]::Max(0.0, ($netNow - $Job.NetLast) / ($now - $Job.NetLastAt))
                $Job.NetLast = $netNow
                $Job.NetLastAt = $now
            }
            $parts.Add(('net {0:0.0} MB/s ({1})' -f ($Job.NetRate / 1MB), (& $fmtBytes ([Math]::Max(0, $netNow - $Job.NetStart)))))

            if (($now - $Job.CpuLastAt) -ge 1.0) {
                if ($Job.WatchService -and ($now - $Job.SvcIdsAt) -ge 5.0) {
                    $Job.SvcIds = @(Get-ServiceProcessIds $Job.WatchService)
                    $Job.SvcIdsAt = $now
                }
                $cpuNow = Get-WatchedCpuSeconds -ProcessId $proc.Id -Names $Job.WatchProcess -ExtraIds $Job.SvcIds
                $Job.CpuPct = [Math]::Min(100.0, [Math]::Max(0.0, ($cpuNow - $Job.CpuLast) / ($now - $Job.CpuLastAt) / $cores * 100.0))
                $Job.CpuLast = $cpuNow
                $Job.CpuLastAt = $now
            }
            $parts.Add(('cpu {0:0}%' -f $Job.CpuPct))

            if ($Job.GrowthLog -and (Test-Path -LiteralPath $Job.GrowthLog)) {
                $grown = (Get-Item -LiteralPath $Job.GrowthLog).Length - $Job.GrowthStart
                $parts.Add(('{0} +{1}' -f (Split-Path -Leaf $Job.GrowthLog), (& $fmtBytes ([Math]::Max(0, $grown)))))
            }
            if ($Job.ActivityLog) {
                $msg = Get-DismLogMessage $Job.ActivityLog
                if ($msg) { $parts.Add($msg) }
            }
            else {
                $tailLine = Get-LastOutputLine $outText
                if ($tailLine) { $parts.Add($tailLine) }
            }
            $line = $head + ' | ' + ($parts -join ' | ')

            if ($redirected) {
                $whole = if ($null -ne $pct) { [int][Math]::Floor($pct) } else { -1 }
                if ($whole -ne $Job.LastWholePct -or ($now - $Job.LastPlainAt) -ge 30) {
                    Write-Host $line
                    $Job.LastWholePct = $whole
                    $Job.LastPlainAt = $now
                }
            }
            else {
                $width = try { [Console]::WindowWidth - 1 } catch { 119 }
                if ($width -lt 40) { $width = 40 }
                if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
                $pad = if ($Job.LastLen -gt $line.Length) { ' ' * ($Job.LastLen - $line.Length) } else { '' }
                Write-Host ("`r" + $line + $pad) -NoNewline
                $Job.LastLen = $line.Length
            }
        }
        $proc.WaitForExit()
        if (-not $redirected -and $Job.LastLen -gt 0) { Write-Host '' }
        $output = Read-CommandCaptureOutput $Job.Stdout
        $errText = Read-CommandCaptureOutput $Job.Stderr
        return @{
            ExitCode = $proc.ExitCode
            Output   = $output
            Error    = $errText
            Elapsed  = $Job.Clock.Elapsed
        }
    }
    finally {
        Remove-Item -LiteralPath $Job.Stdout, $Job.Stderr -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CommandWithStatus {
    # Start-CommandCapture + Wait-CommandWithStatus in one call: run a native command to
    # completion behind the one-line status. Why this exists at all: `dism /Enable-Feature
    # NetFx3` sat at 37.8 % for minutes in the VirtualBox run and the bar alone cannot tell
    # "downloading" from "hung"; Start-Process -Wait on an installer or wsl --install showed
    # nothing at all. Returns @{ ExitCode; Output; Error; Elapsed }.
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string[]]$WatchProcess = @(),
        [string[]]$WatchService = @(),
        [string]$ActivityLog = '',
        [string]$GrowthLog = '',
        [double]$QuietSeconds = 1.0
    )
    $job = Start-CommandCapture -Label $Label -FilePath $FilePath -ArgumentList $ArgumentList `
        -WatchProcess $WatchProcess -WatchService $WatchService -ActivityLog $ActivityLog `
        -GrowthLog $GrowthLog -QuietSeconds $QuietSeconds
    return (Wait-CommandWithStatus -Job $job)
}

function Disable-ConsoleQuickEdit {
    # Turns off QuickEdit mode for THIS console (shared by every script run-all calls in it). With
    # QuickEdit on, a single click inside the window starts a text selection and conhost blocks
    # every write until Esc/Enter ends it - the title reads "Select Administrator: Windows
    # PowerShell" and the whole run looks frozen. That happened twice in the VirtualBox test run.
    # SetConsoleMode(STD_INPUT_HANDLE) without ENABLE_QUICK_EDIT_MODE (0x40), with
    # ENABLE_EXTENDED_FLAGS (0x80) so the change is honoured; nothing is persisted and other
    # windows are untouched. Returns $true when the flag is verified off, $false when there is
    # no console (redirected/CI) or the call is refused.
    if (-not ('PCSetup.ConsoleMode' -as [type])) {
        Add-Type -Namespace PCSetup -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
    }
    try {
        $h = [PCSetup.ConsoleMode]::GetStdHandle(-10)
        $mode = [uint32]0
        if (-not [PCSetup.ConsoleMode]::GetConsoleMode($h, [ref]$mode)) { return $false }
        $wanted = ($mode -band (-bnot [uint32]0x40)) -bor [uint32]0x80
        if (-not [PCSetup.ConsoleMode]::SetConsoleMode($h, $wanted)) { return $false }
        $check = [uint32]0
        if (-not [PCSetup.ConsoleMode]::GetConsoleMode($h, [ref]$check)) { return $false }
        return (($check -band 0x40) -eq 0)
    }
    catch { return $false }
}
