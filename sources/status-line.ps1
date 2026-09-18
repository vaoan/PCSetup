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

function Get-WatchedCpuSeconds {
    # Total CPU seconds burned so far by the launched process plus any named helper processes
    # (TiWorker/TrustedInstaller for DISM, msiexec's service for an MSI). Processes come and go
    # during an install, so a negative delta is clamped to 0 by the caller.
    param([int]$ProcessId, [string[]]$Names)
    $secs = 0.0
    $procs = @()
    if ($ProcessId) { $procs += @(Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) }
    if ($Names) { $procs += @(Get-Process -Name $Names -ErrorAction SilentlyContinue) }
    foreach ($p in $procs) {
        try { $secs += $p.TotalProcessorTime.TotalSeconds } catch { }
    }
    return $secs
}

function Invoke-CommandWithStatus {
    # Runs a native command with stdout/stderr captured to files and redraws ONE status line in
    # place while it runs. Nothing is drawn for the first second, so quick commands stay silent;
    # once drawing starts the line is cut to the window width and overwritten with `r, so a
    # 20-minute step still occupies one row of the log. When output is redirected (CI) a plain
    # line goes out only when the whole percentage changes or every 30 s.
    #
    #   Enabling .NET Framework 3.5 [#######-------------]  37.8% / | 4m 12s | net 2.4 MB/s (61 MB) | cpu 43% | CBS.log +18.3 MB | DISM Package Manager: ...
    #
    # Signals, most important first (the tail is what gets cut on a narrow window):
    #   - the tool's own percentage, when it prints one (DISM does; most installers do not);
    #   - a spinner that ticks every redraw, so the line moves even when every number is flat;
    #   - elapsed time;
    #   - network receive rate and total since the step began - the one thing that moves while
    #     DISM sits at 37.8 % fetching .NET 3.5 from Windows Update, or wsl --install downloads;
    #   - CPU of the launched process plus -WatchProcess names (TiWorker, msiexec): idle while a
    #     download runs, busy while it installs, so the two together say which phase this is;
    #   - growth of -GrowthLog (CBS.log grows the whole time servicing works);
    #   - the last real message in -ActivityLog (dism.log).
    #
    # Why: `dism /Enable-Feature NetFx3` sat at 37.8 % for minutes in the VirtualBox run and the
    # bar alone cannot tell "downloading" from "hung"; Start-Process -Wait on an installer or
    # wsl --install showed nothing at all. Returns @{ ExitCode; Output; Error; Elapsed }.
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string[]]$WatchProcess = @(),
        [string]$ActivityLog = '',
        [string]$GrowthLog = '',
        [double]$QuietSeconds = 1.0
    )
    $stdout = Join-Path $env:TEMP ("pcsetup-status-{0}.out" -f [guid]::NewGuid().ToString('N'))
    $stderr = "$stdout.err"
    $redirected = try { [Console]::IsOutputRedirected } catch { $true }
    $spinner = '|/-\'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $growthStart = if ($GrowthLog -and (Test-Path -LiteralPath $GrowthLog)) { (Get-Item -LiteralPath $GrowthLog).Length } else { 0 }
    $netStart = Get-NetworkBytesReceived
    $netLast = $netStart
    $netLastAt = 0.0
    $netRate = 0.0
    $cpuLast = 0.0
    $cpuLastAt = 0.0
    $cpuPct = 0.0
    $cores = [Math]::Max(1, [Environment]::ProcessorCount)
    $lastLen = 0
    $lastWholePct = -1
    $lastPlainAt = -60.0
    $tick = 0

    $readOut = {
        if (-not (Test-Path -LiteralPath $stdout)) { return '' }
        try {
            $fs = [IO.File]::Open($stdout, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::Default); $sr.ReadToEnd() } finally { $fs.Close() }
        }
        catch { '' }
    }
    $fmtElapsed = {
        param([double]$s)
        if ($s -ge 3600) { '{0}h {1:00}m' -f [int][Math]::Floor($s / 3600), [int]([Math]::Floor($s / 60) % 60) }
        else { '{0}m {1:00}s' -f [int][Math]::Floor($s / 60), [int]($s % 60) }
    }
    $fmtBytes = {
        param([double]$b)
        if ($b -ge 1GB) { '{0:0.00} GB' -f ($b / 1GB) } else { '{0:0.0} MB' -f ($b / 1MB) }
    }

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
    $cpuLast = Get-WatchedCpuSeconds -ProcessId $proc.Id -Names $WatchProcess
    try {
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 500
            $tick++
            $now = $clock.Elapsed.TotalSeconds
            if ($now -lt $QuietSeconds) { continue }

            $pct = Get-ProgressPercent (& $readOut)
            if ($null -ne $pct) {
                $filled = [int][Math]::Round($pct / 5)
                $head = '{0} [{1}{2}] {3,5:0.0}% {4}' -f $Label, ('#' * $filled), ('-' * (20 - $filled)), $pct, $spinner[$tick % 4]
            }
            else {
                $head = '{0} {1}' -f $Label, $spinner[$tick % 4]
            }
            $parts = New-Object System.Collections.Generic.List[string]
            $parts.Add((& $fmtElapsed $now))

            # Rates are sampled once a second, not per tick, so they do not flicker.
            $netNow = Get-NetworkBytesReceived
            if (($now - $netLastAt) -ge 1.0) {
                $netRate = [Math]::Max(0.0, ($netNow - $netLast) / ($now - $netLastAt))
                $netLast = $netNow
                $netLastAt = $now
            }
            $parts.Add(('net {0:0.0} MB/s ({1})' -f ($netRate / 1MB), (& $fmtBytes ([Math]::Max(0, $netNow - $netStart)))))

            if (($now - $cpuLastAt) -ge 1.0) {
                $cpuNow = Get-WatchedCpuSeconds -ProcessId $proc.Id -Names $WatchProcess
                $cpuPct = [Math]::Min(100.0, [Math]::Max(0.0, ($cpuNow - $cpuLast) / ($now - $cpuLastAt) / $cores * 100.0))
                $cpuLast = $cpuNow
                $cpuLastAt = $now
            }
            $parts.Add(('cpu {0:0}%' -f $cpuPct))

            if ($GrowthLog -and (Test-Path -LiteralPath $GrowthLog)) {
                $grown = (Get-Item -LiteralPath $GrowthLog).Length - $growthStart
                $parts.Add(('{0} +{1}' -f (Split-Path -Leaf $GrowthLog), (& $fmtBytes ([Math]::Max(0, $grown)))))
            }
            if ($ActivityLog) {
                $msg = Get-DismLogMessage $ActivityLog
                if ($msg) { $parts.Add($msg) }
            }
            $line = $head + ' | ' + ($parts -join ' | ')

            if ($redirected) {
                $whole = if ($null -ne $pct) { [int][Math]::Floor($pct) } else { -1 }
                if ($whole -ne $lastWholePct -or ($now - $lastPlainAt) -ge 30) {
                    Write-Host $line
                    $lastWholePct = $whole
                    $lastPlainAt = $now
                }
            }
            else {
                $width = try { [Console]::WindowWidth - 1 } catch { 119 }
                if ($width -lt 40) { $width = 40 }
                if ($line.Length -gt $width) { $line = $line.Substring(0, $width) }
                $pad = if ($lastLen -gt $line.Length) { ' ' * ($lastLen - $line.Length) } else { '' }
                Write-Host ("`r" + $line + $pad) -NoNewline
                $lastLen = $line.Length
            }
        }
        $proc.WaitForExit()
        if (-not $redirected -and $lastLen -gt 0) { Write-Host '' }
        # wsl.exe writes UTF-16, which arrives here as text full of NULs; strip them so callers
        # can regex the output.
        $output = (& $readOut) -replace "`0", ''
        $errText = if (Test-Path -LiteralPath $stderr) { try { ([IO.File]::ReadAllText($stderr)) -replace "`0", '' } catch { '' } } else { '' }
        return @{
            ExitCode = $proc.ExitCode
            Output   = $output
            Error    = $errText
            Elapsed  = $clock.Elapsed
        }
    }
    finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}
