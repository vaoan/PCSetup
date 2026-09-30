# download-video.ps1
# One clipboard-driven downloader for Twitch VODs, YouTube videos, Instagram reels/posts and X (Twitter) posts.
# Reads the link from the clipboard, detects the site, installs only the tools that site needs
# (scoop itself included, so it works on a freshly formatted PC), downloads into the Videos
# folder (Pictures for Instagram photo posts), shows progress in the window, opens Explorer on
# the finished file, and reports failures in a message box. Launched by download-video.bat.
# Twitch/YouTube names end in a quality tag ([1080p60]); an earlier download of the same video at a
# different quality is kept and the new quality lands next to it - only an identical version is skipped.
# Every video download is then re-encoded to AV1 (about half the size, no visible loss - see
# "AV1 compression"); -NoCompress keeps the file as the site served it.
#
#   Twitch     TwitchDownloaderCLI + ffmpeg   highest quality available, 24 threads, disk-space check first
#   YouTube    yt-dlp + deno + ffmpeg         highest quality available (h264/aac preferred at equal resolution), 16 fragment connections
#   Instagram  yt-dlp + gallery-dl + ffmpeg   best quality; needs a one-time cookie export (see below)
#   X          yt-dlp + ffmpeg                highest quality; a post flagged sensitive is hidden from guests, so it
#                                             falls back to the public embed services (fxtwitter, vxtwitter) whose
#                                             CDN links need no login - or to a cookie export, like Instagram
#
# Instagram serves almost nothing without a login (X only hides sensitive-flagged posts) and no tool
# can read Chrome/Edge cookies on current Windows, so: install the Chrome extension "Get cookies.txt
# LOCALLY", open instagram.com (or x.com) logged in, click Export, leave the file in Downloads. This
# script adopts it automatically.
#
# Optional parameters (for manual runs):
#   -Url           use this link instead of the clipboard
#   -MaxHeight     Twitch/YouTube/X resolution cap in pixels, e.g. 720 (default 0 = no cap, best available)
#   -NoCompress    keep the download as the site serves it (skip the AV1 step)
#   -Gpu           encode AV1 with NVENC on the GPU instead of SVT-AV1 on the CPU: ~2.5x faster, ~30% bigger files at the same quality
#   -MinVmaf       the VMAF score (against the source) an encode must keep to replace the original; default 95 = no visible difference
#   -Recheck       ignore the verdict stamped in a file's comment tag (see "stamps" below) and test it again
#   -CompressFile  re-encode an existing video file to AV1 in place (any h264 .mp4, e.g. an earlier download) and stop
#   -CompressFolder <dir>  re-encode every video directly inside a folder (largest first, one background job) and stop
#   -CompressDownloads     the same for the Downloads folder (what compress-folder.bat does with no argument)
#   -Ending        test aid: only the first part - Twitch "20s", YouTube seconds like "30" (re-encodes)
#   -NoMessageBox  failures go to the console only (tests)
#   -Inline        do the work in this window instead of a background job (tests; the old behaviour)
#
# The work itself runs in a hidden, detached, below-normal-priority worker process (this script
# with -Worker) so it never chugs the PC and survives the window being closed; the window is only
# a viewer. Run the launcher again while a job runs and it re-attaches to it. One job at a time.

param(
    [string]$Url,
    [int]$MaxHeight = 0,
    [switch]$NoCompress,
    [switch]$Gpu,
    [double]$MinVmaf = 95,
    [switch]$Recheck,
    [string]$CompressFile,
    [string]$CompressFolder,
    [switch]$CompressDownloads,
    [string]$Ending,
    [switch]$NoMessageBox,
    [switch]$Inline,
    [switch]$Worker
)

# Auto-elevate to Administrator (forwarding any parameters)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $fwd = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -MaxHeight $MaxHeight"
    if ($Url)          { $fwd += " -Url `"$Url`"" }
    if ($NoCompress)   { $fwd += " -NoCompress" }
    if ($Gpu)          { $fwd += " -Gpu" }
    if ($Recheck)      { $fwd += " -Recheck" }
    if ($PSBoundParameters.ContainsKey('MinVmaf')) { $fwd += " -MinVmaf $MinVmaf" }
    if ($CompressFile) { $fwd += " -CompressFile `"$CompressFile`"" }
    if ($CompressFolder)    { $fwd += " -CompressFolder `"$CompressFolder`"" }
    if ($CompressDownloads) { $fwd += " -CompressDownloads" }
    if ($Ending)       { $fwd += " -Ending `"$Ending`"" }
    if ($NoMessageBox) { $fwd += " -NoMessageBox" }
    if ($Inline)       { $fwd += " -Inline" }
    if ($Worker)       { $fwd += " -Worker" }
    Start-Process PowerShell -ArgumentList $fwd -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = 'Download Video'

# ============================================================================ shared helpers
# Every line goes through Out-Line. In the background worker the console is a log file that the
# viewer tails, so the colour travels as a one-letter marker ("K|text") the viewer turns back into
# colour; in a real console it is just coloured text.
function Out-Line([string]$Mark, [string]$Text, [ConsoleColor]$Color) {
    if ($Worker) { Write-Host "$Mark|$Text" } else { Write-Host $Text -ForegroundColor $Color }
}
function Write-Step([string]$Text) { Write-Host ''; Out-Line 'S' "== $Text" Cyan }
# Cancelling differs by where the work runs: X in the viewer for a background job, closing the
# window for an -Inline run.
function Get-CancelHint { if ($Worker) { 'Press X in this window to cancel' } else { 'Closing this window cancels' } }
function Write-Ok([string]$Text)   { Out-Line 'K' "   $Text" Green }
function Write-Info([string]$Text) { Out-Line 'I' "   $Text" Gray }
function Write-Warn([string]$Text) { Out-Line 'W' "   $Text" Yellow }

# QuickEdit off for this window. With it on (the conhost default) one click inside the window
# starts a text selection and conhost blocks every write until Esc/Enter: the title reads
# "Select 27% Encoding - Download Video" and the viewer looks stuck while the worker carries on
# and finishes - which is exactly how the first Downloads batch was reported as "stuck" nine
# hours after it had completed. Same code as Disable-ConsoleQuickEdit in sources\status-line.ps1
# (not dot-sourced here: this script carries its own progress code). Nothing is persisted and
# other windows keep their setting; a redirected stdin (tests) just returns $false.
function Disable-ConsoleQuickEdit {
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

function Fail([string]$Message) {
    Write-Host ''
    foreach ($l in ("FAILED: $Message" -split "`r?`n")) { Out-Line 'F' $l Red }
    if ($NoMessageBox) { exit 1 }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Message, 'Download Video failed',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {}
    exit 1
}

function Format-Duration([int]$Seconds) {
    $t = [TimeSpan]::FromSeconds($Seconds)
    if ($t.TotalHours -ge 1) { return ('{0}h {1:00}m {2:00}s' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds) }
    return ('{0}m {1:00}s' -f $t.Minutes, $t.Seconds)
}

function Get-SafeName([string]$Text, [int]$Max = 120) {
    $invalid = [IO.Path]::GetInvalidFileNameChars() -join ''
    $s = (($Text -replace "[$([regex]::Escape($invalid))]", '') -replace '[\r\n]+', ' ' -replace '\s+', ' ').Trim()
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max).Trim() }
    return $s
}

function Get-KnownFolder([string]$Name, [string]$Fallback) {
    $p = [Environment]::GetFolderPath($Name)
    if (-not $p) { $p = Join-Path $env:USERPROFILE $Fallback }
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}

# ---------------------------------------------------------------------------- link routing
# Which site a link belongs to and the id its handler needs: Site, Id and Kind (Instagram: p or
# reel), or $null for anything else. Pure, so the tests can run every link shape without a download.
function Resolve-VideoLink([string]$Url) {
    if (-not $Url) { return $null }
    if ($Url -match '(?i)twitch\.tv/(?:videos|[^/\s]+/v(?:ideo)?)/(\d+)') {
        return [pscustomobject]@{ Site = 'twitch'; Id = $Matches[1]; Kind = 'vod' }
    }
    if ($Url -match '(?i)(?:youtube\.com/(?:watch\?(?:[^#\s]*&)?v=|shorts/|live/|embed/|v/)|youtu\.be/)([A-Za-z0-9_-]{11})') {
        return [pscustomobject]@{ Site = 'youtube'; Id = $Matches[1]; Kind = 'video' }
    }
    if ($Url -match '(?i)instagram\.com/(?:[A-Za-z0-9_.]+/)?(reels?|p|tv)/([A-Za-z0-9_-]{5,})') {
        $kind = if ($Matches[1] -ieq 'p') { 'p' } else { 'reel' }
        return [pscustomobject]@{ Site = 'instagram'; Id = $Matches[2]; Kind = $kind }
    }
    # x.com and twitter.com (also mobile.), plus the fxtwitter/vxtwitter/fixupx embed mirrors people
    # paste from Discord; "/i/status/<id>" and "/i/web/status/<id>" carry no user name. The
    # lookbehind keeps "netflix.com/.../status/..." out.
    if ($Url -match '(?i)(?<![A-Za-z0-9-])(?:x|twitter|fxtwitter|vxtwitter|fixupx|fixvx)\.com/(?:i/(?:web/)?status|[A-Za-z0-9_]{1,15}/status(?:es)?)/(\d{5,})') {
        return [pscustomobject]@{ Site = 'x'; Id = $Matches[1]; Kind = 'post' }
    }
    return $null
}

# The Downloads folder, from the User Shell Folders key (it is relocated on this PC), else the default.
function Get-DownloadsFolder {
    $dir = $null
    try { $dir = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders').'{374DE290-123F-4565-9164-39C4925E467B}' } catch {}
    if ($dir) { return [Environment]::ExpandEnvironmentVariables($dir) }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

# ---------------------------------------------------------------------------- login sources
# Cookie sets to try, best first, for a site that hides posts behind a login: the adopted export
# file, then Firefox's own cookies, then none. Chrome and Edge cookies cannot be read by any tool
# on current Windows builds (Chrome locks the DB while it runs, Edge uses app-bound encryption),
# so the supported way is a one-time export with the Chrome extension "Get cookies.txt LOCALLY".
# Its file lands in Downloads as "<host>_cookies.txt"; the newest one matching $ExportFilters that
# really holds a cookie for $DomainPattern is copied to $CookieFile when it is newer than the copy.
function Get-LoginSources([string]$CookieFile, [string[]]$ExportFilters, [string]$DomainPattern) {
    $downloadsDir = Get-DownloadsFolder
    $candidates = @()
    foreach ($filter in $ExportFilters) { $candidates += @(Get-ChildItem -LiteralPath $downloadsDir -Filter $filter -File -ErrorAction SilentlyContinue) }
    $exported = $candidates | Sort-Object LastWriteTime -Descending | Where-Object {
        try { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop) -match "(?m)^\.?(?:[\w-]+\.)*(?:$DomainPattern)\t" } catch { $false }
    } | Select-Object -First 1
    if ($exported -and (-not (Test-Path -LiteralPath $CookieFile) -or $exported.LastWriteTime -gt (Get-Item -LiteralPath $CookieFile).LastWriteTime)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $CookieFile) | Out-Null
        Copy-Item -LiteralPath $exported.FullName -Destination $CookieFile -Force
        Write-Ok "Adopted new cookie export from Downloads: $($exported.Name) -> $CookieFile"
    }
    $sets = @()
    if (Test-Path -LiteralPath $CookieFile) { $sets += ,@{ Args = @('--cookies', $CookieFile); Name = 'cookies file' } }
    if (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles')) { $sets += ,@{ Args = @('--cookies-from-browser', 'firefox'); Name = 'Firefox cookies' } }
    $sets += ,@{ Args = @(); Name = 'no cookies' }
    Write-Info ("Login sources to try: " + (($sets | ForEach-Object { $_.Name }) -join ', '))
    return ,$sets
}

# Run a native command / external script and echo its output (stdout AND stderr) as info lines.
# With $ErrorActionPreference = 'Stop', anything a child writes to stderr through '2>&1' becomes a
# terminating NativeCommandError - the scoop installer's progress chatter killed a script that way.
function Invoke-Native([scriptblock]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command 2>&1 | ForEach-Object { Write-Info ("$_".TrimEnd()) } }
    finally { $ErrorActionPreference = $prev }
}

# Run a native command and return its combined output as string lines, never throwing.
function Get-NativeOutput([scriptblock]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $prev }
}

# Run a download tool and show its progress as ONE bar redrawn in place, returning the exit code.
# The tools refresh their progress with "\r", but through the pipe every refresh arrives as its own
# line, so the window used to fill with hundreds of "[download]  43.7% of ..." lines. Lines that
# look like progress are folded into the bar; anything else (errors, destination, merge notices)
# is printed above it and the bar redraws on the next update. When output is redirected (tests,
# logs) the bar is written as a plain line, only when the whole-number percentage or stage changes.
# Recognised shapes, captured from the real tools under Windows PowerShell 5.1:
#   TwitchDownloaderCLI  [STATUS] - Downloading 45% [2/4]        (stages 1/4..4/4, some without a %)
#   yt-dlp               [download]  43.7% of   11.28MiB at  257.95KiB/s ETA 00:25
#                        ...occasionally with a message glued on: "ETA 00:25[download] Got error: ..."
#   ffmpeg               frame=  135 fps= 65 q=31.0 size=  256KiB time=00:00:02.46 bitrate=... speed=1.08x
#                        (-Ending cuts and the AV1 step; with -TotalSeconds the time becomes a percentage)
# Two console lines owned by a running job - the status bar and, under it, the tool's latest raw
# output line - redrawn in place with SetCursorPosition. They are reserved with two newlines the
# first time so any scrolling happens then, never while writing at fixed rows. Hosts whose cursor
# cannot be moved fall back to a single "\r" line. Used by Invoke-Streaming in a real console and
# by the job viewer, which gets the two strings from the worker's status file.
function New-StatusPair {
    $width = try { [Math]::Max(60, [Console]::WindowWidth) } catch { 120 }
    $st = @{ Shown = $false; Row = -1; Cursor = $true; Width = $width; Bar = ''; Raw = '' }
    $writeAt = {
        param([int]$Row, [string]$Text, [ConsoleColor]$Color)
        if ($Text.Length -gt $st.Width - 1) { $Text = $Text.Substring(0, $st.Width - 1) }
        [Console]::SetCursorPosition(0, $Row)
        Write-Host -NoNewline $Text.PadRight($st.Width - 1) -ForegroundColor $Color
    }.GetNewClosure()
    $pair = @{}
    $pair.Draw = {
        param([string]$Bar, [string]$Raw)
        $st.Bar = $Bar; $st.Raw = $Raw
        try {
            if ($st.Cursor) {
                if (-not $st.Shown) {
                    if ([Console]::CursorLeft -gt 0) { Write-Host '' }
                    Write-Host ''; Write-Host ''
                    $st.Row = [Console]::CursorTop - 2
                    $st.Shown = $true
                }
                & $writeAt $st.Row $st.Bar Cyan
                & $writeAt ($st.Row + 1) $st.Raw DarkGray
                return
            }
        } catch { $st.Cursor = $false }
        $text = $st.Bar
        if ($text.Length -gt $st.Width - 1) { $text = $text.Substring(0, $st.Width - 1) }
        Write-Host -NoNewline ("`r" + $text.PadRight($st.Width - 1)) -ForegroundColor Cyan
        $st.Shown = $true
    }.GetNewClosure()
    $pair.Clear = {
        if (-not $st.Shown) { return }
        if ($st.Cursor) {
            try { & $writeAt $st.Row '' Gray; & $writeAt ($st.Row + 1) '' Gray; [Console]::SetCursorPosition(0, $st.Row) } catch {}
        } else {
            Write-Host -NoNewline ("`r" + (' ' * ($st.Width - 1)) + "`r")
        }
        $st.Shown = $false
    }.GetNewClosure()
    $pair.Redraw = { if ($st.Bar) { & $pair.Draw $st.Bar $st.Raw } }.GetNewClosure()
    $pair.End = {
        if (-not $st.Shown) { return }
        if ($st.Cursor) { try { [Console]::SetCursorPosition(0, $st.Row + 1) } catch {} }
        Write-Host ''
        $st.Shown = $false; $st.Bar = ''; $st.Raw = ''
    }.GetNewClosure()
    return $pair
}

# A status pair for a console, or $null where there is none (worker, redirected output): what a
# caller hands to several Invoke-Streaming calls as -Pair so they share the same two lines instead
# of each leaving its own behind - the crf search runs dozens of short ffmpeg passes per file.
function New-StatusPairIfConsole {
    if ($Worker) { return $null }
    $redirected = try { [Console]::IsOutputRedirected } catch { $true }
    if ($redirected) { return $null }
    return New-StatusPair
}

function Invoke-Streaming([scriptblock]$Command, [string]$Tool = 'tool', [string]$FfmpegLabel = 'Re-encoding', [double]$TotalSeconds = 0, [string]$StartLabel = 'Starting', $Pair = $null) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # Three output modes: a real console owns the two status lines; the background worker writes
    # them to the status file for the viewer (its own stdout is the log); plain redirected output
    # (tests, logs) prints one line per whole percent and no raw lines.
    $redirected = try { [Console]::IsOutputRedirected } catch { $true }
    $mode       = if ($Worker) { 'worker' } elseif ($redirected) { 'plain' } else { 'console' }
    $barWidth   = 20      # the full line ("... | ETA | time of total | fps speed | MB | elapsed") must fit a 120-column window
    $spinner    = '|/-\'
    $clock      = [Diagnostics.Stopwatch]::StartNew()
    $title      = try { $Host.UI.RawUI.WindowTitle } catch { '' }
    $pair       = if ($Pair) { $Pair } elseif ($mode -eq 'console') { New-StatusPair } else { $null }
    $st = @{ LastPct = -1; LastLabel = ''; Spin = 0; Stage = ''; StageStart = 0.0; Bar = ''; Raw = ''; Title = ''; StatusAt = -1.0 }

    $show = {
        # Push the current pair out: draw it (console), or write the status file (worker, at most
        # ~5 times a second so a fast tool does not spend its time on file writes).
        if ($mode -eq 'console') { & $pair.Draw $st.Bar $st.Raw; return }
        if ($mode -eq 'worker') {
            $now = $clock.Elapsed.TotalSeconds
            if ($now - $st.StatusAt -ge 0.2) { Write-JobStatus $st.Bar $st.Raw $st.Title; $st.StatusAt = $now }
        }
    }
    $clearPair = { if ($mode -eq 'console') { & $pair.Clear } }
    $hms = { param([double]$Seconds) $t = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds)); '{0}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds }
    # Status line: "<label> [####------]  12.0% | ETA 1h 05m | <detail> | 12m 11s elapsed".
    # $Pct < 0 draws a spinner instead of a bar, so a stage without a percentage still visibly moves.
    # $Eta in seconds; -1 = estimate it from this stage's own pace (each label restarts the clock),
    # -2 = the detail already carries one (yt-dlp), so print none.
    $render = {
        param([string]$Label, [double]$Pct, [string]$Detail, [double]$Eta = -1)
        $now = $clock.Elapsed.TotalSeconds
        if ($Label -ne $st.Stage) { $st.Stage = $Label; $st.StageStart = $now }
        $stageElapsed = $now - $st.StageStart
        if ($Pct -ge 0) {
            $filled = [int][Math]::Round($barWidth * [Math]::Min(100.0, $Pct) / 100.0)
            $text = "$Label [" + ('#' * $filled) + ('-' * ($barWidth - $filled)) + '] ' + ('{0,5:0.0}%' -f $Pct)
            if ($Eta -eq -1 -and $Pct -ge 1 -and $stageElapsed -ge 3) { $Eta = $stageElapsed * (100.0 - $Pct) / $Pct }
        } else {
            $st.Spin = ($st.Spin + 1) % $spinner.Length
            $text = "$Label $($spinner[$st.Spin])"
        }
        # ETA first: the line is cut at the window width, and that is the part nobody wants cut.
        # Durations drop the seconds once they reach an hour, so a 5-hour VOD's line still fits.
        $dur = { param([double]$S) if ($S -ge 3600) { '{0}h {1:00}m' -f [int][Math]::Floor($S / 3600), [int][Math]::Floor(($S % 3600) / 60) } else { Format-Duration ([int]$S) } }
        if ($Eta -ge 0) { $text += " | ETA $(& $dur $Eta)" }
        if ($Detail) { $text += " | $Detail" }
        $text += " | $(& $dur $now) elapsed"
        $st.Title = if ($Pct -ge 0) { '{0:0}% {1} - Download Video' -f $Pct, $Label } else { "$Label - Download Video" }
        if ($mode -eq 'console') { try { $Host.UI.RawUI.WindowTitle = $st.Title } catch {} }
        if ($mode -eq 'plain') {
            $whole = if ($Pct -ge 0) { [int][Math]::Floor($Pct) } else { -1 }
            if ($whole -ne $st.LastPct -or $Label -ne $st.LastLabel) { Write-Host $text; $st.LastPct = $whole; $st.LastLabel = $Label }
        } else {
            $st.Bar = $text
            & $show
        }
    }
    # The techy line: what the tool itself just said, verbatim apart from squeezed whitespace.
    $raw = {
        param([string]$Line)
        if ($mode -eq 'plain') { return }
        $st.Raw = '{0} {1} | {2}' -f (Get-Date -Format 'HH:mm:ss'), $Tool, ($Line -replace '\s+', ' ').Trim()
        if (-not $st.Bar) { $st.Spin = ($st.Spin + 1) % $spinner.Length; $st.Bar = "$StartLabel $($spinner[$st.Spin]) | $(Format-Duration ([int]$clock.Elapsed.TotalSeconds)) elapsed" }
        & $show
    }

    try {
        & $Command 2>&1 | ForEach-Object {
            $line = "$_"
            if (-not $line.Trim()) { return }
            $rest = ''
            if ($line -match '^\[STATUS\] - (.+?)(?: (\d+)%)? \[(\d+)/(\d+)\]\s*(.*)$') {
                $label = "$($Matches[1]) [$($Matches[3])/$($Matches[4])]"
                $pct   = if ($Matches[2]) { [double]$Matches[2] } else { -1 }
                $rest  = $Matches[5]
                & $raw $line.Substring(0, $line.Length - $rest.Length)
                & $render $label $pct ''
            } elseif ($line -match '^\[download\]\s+([\d.]+)% of\s+(~?\s*[\d.]+\w+)(?:\s+in\s+([\d:]+))?(?:\s+at\s+([^\s\[]+))?(?:\s+ETA\s+([^\s\[]+))?(.*)$') {
                # Fields stop at "[" because a message is sometimes glued on with no line break.
                $pct    = [double]$Matches[1]
                $detail = "of $($Matches[2] -replace '\s', '')"
                if ($Matches[3]) { $detail += " in $($Matches[3])" }
                if ($Matches[4]) { $detail += " at $($Matches[4])" }
                if ($Matches[5]) { $detail += " ETA $($Matches[5])" }
                $rest   = $Matches[6]
                $hasEta = [bool]$Matches[5]
                & $raw $line.Substring(0, $line.Length - $rest.Length)
                & $render 'Downloading' $pct $detail $(if ($hasEta) { -2 } else { -1 })
            } elseif ($line -match '^frame=\s*(\d+)\s+fps=\s*([\d.]+).*?size=\s*(\S+).*?time=(\S+)(?:.*?speed=\s*([\d.]+)x)?') {
                $fpsNow = [double]$Matches[2]; $size = $Matches[3]; $time = $Matches[4]
                $speed = if ($Matches[5]) { [double]$Matches[5] } else { 0.0 }
                $done = -1.0
                if ($time -match '^(\d+):(\d+):([\d.]+)$') { $done = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [double]$Matches[3] }
                $pct = if ($TotalSeconds -gt 0 -and $done -ge 0) { [Math]::Min(100.0, 100.0 * $done / $TotalSeconds) } else { -1 }
                $eta = if ($pct -ge 0 -and $speed -gt 0) { ($TotalSeconds - $done) / $speed } else { -1 }
                $detail = if ($done -ge 0) { & $hms $done } else { "time $time" }
                if ($TotalSeconds -gt 0) { $detail += "/$(& $hms $TotalSeconds)" }
                if ($fpsNow -gt 0) { $detail += " | $([int]$fpsNow) fps" }
                if ($speed -gt 0) { $detail += " $('{0:0.0}' -f $speed)x" }
                if ($size -match '^([\d.]+)(KiB|MiB|GiB|kB|MB|GB)') {
                    $mb = switch ($Matches[2]) { 'KiB' { [double]$Matches[1] / 1024 } 'MiB' { [double]$Matches[1] } 'GiB' { [double]$Matches[1] * 1024 } 'kB' { [double]$Matches[1] / 1000 } 'MB' { [double]$Matches[1] } 'GB' { [double]$Matches[1] * 1000 } }
                    $detail += " | $('{0:N0}' -f $mb) MB out"
                }
                & $raw $line
                & $render $FfmpegLabel $pct $detail $eta
            } elseif ($line -match '(?i)error|fail|warn|denied|cannot|could not|not found|invalid|unable|refused|timed out') {
                # Worth keeping: print it above the two owned lines, which redraw on the next update.
                & $clearPair
                Write-Host $line
            } elseif ($mode -eq 'plain') {
                Write-Host $line
            } else {
                & $raw $line
            }
            if ($rest.Trim()) { & $clearPair; Write-Host $rest.Trim() }
        }
        $code = $LASTEXITCODE
        if ($mode -eq 'console' -and -not $Pair) { & $pair.End }    # a shared pair is ended by its owner
        if ($mode -eq 'worker') { Write-JobStatus $st.Bar $st.Raw $st.Title 'end' }    # final pair, unthrottled; the viewer keeps it and moves below
        return $code
    }
    finally {
        $ErrorActionPreference = $prev
        try { $Host.UI.RawUI.WindowTitle = $title } catch {}
    }
}

function Show-Existing([string]$Path, [string]$Tag) {
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $Path).Length / 1MB)
    $at = if ($Tag) { " at $Tag" } else { '' }
    Write-Warn "Already downloaded$at ($sizeMb MB) - opening its folder instead."
    Start-Process explorer.exe -ArgumentList "/select,`"$Path`""
    if (-not $Worker) { Start-Sleep -Seconds 4 }    # the viewer does its own countdown
    exit 0
}

# ---------------------------------------------------------------------------- versions on disk
# Twitch and YouTube files carry a quality tag - "<date> <channel> - <title> [<id>] [1080p60].mp4" -
# so the same video can exist at several qualities and "already downloaded" means "already
# downloaded at THIS quality". Files from before the tag existed are recognised by their [id],
# probed with ffprobe, renamed to the tagged form, and only skipped when height, fps and length
# all match what is about to be downloaded. Anything that differs, or cannot be probed, is left
# alone and the requested quality is downloaded next to it.
function Format-QualityTag([int]$Height, [double]$Fps) {
    return ('{0}p{1}' -f $Height, [int][Math]::Round($Fps))
}

function Get-FfprobePath([string]$Ffmpeg) {
    $probe = Join-Path (Split-Path -Parent $Ffmpeg) 'ffprobe.exe'    # ships next to ffmpeg (scoop shim and bin alike)
    if (Test-Path -LiteralPath $probe) { return $probe }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Codec, height, rounded fps and duration of a video file, or $null when ffprobe cannot read it.
# ffprobe prints the stream fields in its own fixed order (codec_name before height before
# r_frame_rate), whatever order they are requested in: "h264,1080,60/1".
function Get-VideoSpec([string]$Path, [string]$Ffprobe) {
    if (-not $Ffprobe) { return $null }
    $lines = Get-NativeOutput { & $Ffprobe -v error -select_streams v:0 -show_entries 'stream=codec_name,height,r_frame_rate:format=duration' -of csv=p=0 $Path }
    $codec = ''; $height = 0; $fps = 0.0; $seconds = 0.0
    foreach ($line in $lines) {
        if ($line -match '^([\w-]*),(\d+),(\d+)/(\d+)\s*$') {
            $codec  = $Matches[1]
            $height = [int]$Matches[2]
            if ([int]$Matches[4] -ne 0) { $fps = [double]$Matches[3] / [double]$Matches[4] }
        } elseif ($line -match '^([\d.]+)\s*$') {
            $seconds = [double]$Matches[1]
        }
    }
    if ($height -le 0) { return $null }
    return [pscustomobject]@{ Codec = $codec; Height = $height; Fps = $fps; Tag = (Format-QualityTag $height $fps); Seconds = $seconds }
}

# Looks at every .mp4 in $Dir that carries [$Id] in its name. Exits through Show-Existing when the
# requested version is already there (renaming a legacy untagged file to the tagged name first);
# otherwise renames legacy files to their real quality and returns so the download proceeds.
# $ExpectedSeconds = 0 disables the length check (used for -Ending test runs). $BeforeShowExisting,
# when given, runs with the path of the already-downloaded file before the folder is opened - Twitch
# uses it to AV1-compress a file that was downloaded before the compression step existed.
function Resolve-ExistingVersions([string]$Dir, [string]$Id, [string]$BaseName, [string]$Tag, [int]$ExpectedSeconds, [string]$Ffprobe, [scriptblock]$BeforeShowExisting) {
    $specPath = Join-Path $Dir "$BaseName [$Tag].mp4"
    $files = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -eq '.mp4' -and $_.Name.Contains("[$Id]") })
    if (-not $files.Count) { return }
    if (-not $Ffprobe) { Write-Warn 'ffprobe not found - cannot compare the existing file(s), downloading anyway.' }

    $others = @()
    foreach ($f in $files) {
        $spec = Get-VideoSpec $f.FullName $Ffprobe
        if (-not $spec) {
            Write-Warn "Existing : $($f.Name) - unreadable, ignoring it"
            $others += $f.Name
            continue
        }
        $complete = ($ExpectedSeconds -le 0) -or ($spec.Seconds -ge $ExpectedSeconds * 0.95)
        $lenNote  = if ($complete) { Format-Duration ([int]$spec.Seconds) } else { "only $(Format-Duration ([int]$spec.Seconds)) of $(Format-Duration $ExpectedSeconds)" }
        Write-Info "Existing : $($f.Name) -> $($spec.Tag), $lenNote"

        if ($spec.Tag -eq $Tag -and $complete) {
            # Same version. Make sure it sits under the tagged name, then stop.
            $target = $specPath
            if ($f.FullName -ne $target) {
                try { Move-Item -LiteralPath $f.FullName -Destination $target -ErrorAction Stop; Write-Ok "Renamed : $(Split-Path $target -Leaf)" }
                catch { Write-Warn "Could not rename to the tagged name: $($_.Exception.Message)"; $target = $f.FullName }
            }
            if ($BeforeShowExisting) { & $BeforeShowExisting $target }
            Show-Existing $target $Tag
        }

        if ($f.FullName -eq $specPath) {
            # Right name, wrong content (partial or mis-tagged): the download replaces it.
            Write-Warn "Replacing it: it is not a complete $Tag download."
            continue
        }
        # A different quality (or a partial file). Keep it, but under a name that says what it is.
        $others += $f.Name
        $wanted = if ($complete) { "$BaseName [$($spec.Tag)].mp4" } else { $null }
        if ($wanted -and $f.Name -ne $wanted) {
            $dest = Join-Path $Dir $wanted
            if (Test-Path -LiteralPath $dest) { Write-Warn "Not renaming $($f.Name): $wanted already exists" }
            else {
                try { Move-Item -LiteralPath $f.FullName -Destination $dest -ErrorAction Stop; Write-Ok "Renamed : $wanted" }
                catch { Write-Warn "Could not rename $($f.Name): $($_.Exception.Message)" }
            }
        }
    }
    if ($others.Count) { Write-Ok "Downloading $Tag next to the $($others.Count) other version(s)." }
}

function Finish([string]$Path, [string]$Summary) {
    Write-Host ''
    Out-Line 'D' "DONE  $(Split-Path $Path -Leaf)" Green
    if ($Summary) { Out-Line 'D' "      $Summary" Green }
    Out-Line 'D' "      $Path" Green
    if (Test-Path -LiteralPath $Path -PathType Container) { Start-Process explorer.exe -ArgumentList "`"$Path`"" }
    else { Start-Process explorer.exe -ArgumentList "/select,`"$Path`"" }
    if ($Worker) { exit 0 }    # the viewer does the countdown
    for ($s = 8; $s -gt 0; $s--) {
        Write-Host -NoNewline "`r      Closing in $s s... "
        Start-Sleep -Seconds 1
    }
    exit 0
}

# ============================================================================ scoop bootstrap
$scoopDir   = Join-Path $env:USERPROFILE 'scoop'
$scoopShims = Join-Path $scoopDir 'shims'

# Make sure scoop itself exists (freshly formatted PC: nothing is installed yet).
# Mirrors sources\init-prereqs.ps1: download get.scoop.sh to a file, run it with -RunAsAdmin
# because this script is elevated, then put the shims folder on PATH for this process.
function Ensure-Scoop {
    $scoopCmd = Join-Path $scoopShims 'scoop.ps1'
    if ((Test-Path -LiteralPath $scoopCmd) -and ($env:Path -notlike "*$scoopShims*")) { $env:Path = "$scoopShims;$env:Path" }
    if (Get-Command scoop -ErrorAction SilentlyContinue) { Write-Ok "scoop: $scoopShims"; return }

    Write-Warn 'scoop (package manager) not found - installing it. This only happens on a fresh PC.'
    if (Test-Path -LiteralPath $scoopDir) {
        # A previous install died half-way; the installer refuses a non-empty folder. Move it aside, never delete.
        $aside = "$scoopDir.broken-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Write-Warn "Found an incomplete scoop folder - moving it to $aside"
        Move-Item -LiteralPath $scoopDir -Destination $aside
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $installer = Join-Path $env:TEMP 'scoop-install.ps1'
    try {
        Invoke-WebRequest -Uri 'https://get.scoop.sh' -OutFile $installer -UseBasicParsing -TimeoutSec 120
    } catch { Fail "Could not download the scoop installer: $($_.Exception.Message)`n`nIs the internet connected?" }
    if ((Get-Item -LiteralPath $installer).Length -lt 10KB) { Fail 'The scoop installer download is too small to be real (captive portal or blocked page?).' }

    # The installer runs in Windows PowerShell 5.1 and needs Expand-Archive from
    # Program Files\WindowsPowerShell\Modules. Hand it 5.1's stock module path explicitly so it
    # works no matter what shell launched us (a PS7 PSModulePath hides the 5.1 Archive module).
    $env:PSModulePath = (@(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $env:SystemRoot 'system32\WindowsPowerShell\v1.0\Modules')
    ) -join ';')
    Invoke-Native { & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -RunAsAdmin }

    $env:Path = "$scoopShims;$env:Path"
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) { Fail "scoop did not install (no 'scoop' command after running the installer).`n`nSee the window output for the installer's message." }
    Invoke-Native { & scoop config aria2-enabled false } | Out-Null
    Write-Ok "scoop installed: $scoopShims"

    # scoop needs git for bucket updates; install it now so later 'scoop update' calls work.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warn 'git not found - installing it with scoop'
        Invoke-Native { & scoop install git }
        if (Get-Command git -ErrorAction SilentlyContinue) { Write-Ok 'git installed' } else { Write-Warn 'git still missing - scoop updates may fail later, continuing anyway' }
    }
}

# Resolve a scoop-installed command, installing it if missing (check -> act -> verify).
function Resolve-ScoopTool([string]$Command, [string]$Package) {
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) { Write-Ok ("{0,-20}: {1}" -f $Command, $cmd.Source); return $cmd.Source }
    $shim = Join-Path $scoopShims "$Command.exe"
    if (Test-Path -LiteralPath $shim) { Write-Ok ("{0,-20}: {1}" -f $Command, $shim); return $shim }

    Write-Warn "$Command not found - installing '$Package' with scoop"
    Invoke-Native { & scoop install $Package }

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) { Write-Ok ("{0,-20}: {1}" -f $Command, $cmd.Source); return $cmd.Source }
    if (Test-Path -LiteralPath $shim) { Write-Ok ("{0,-20}: {1}" -f $Command, $shim); return $shim }
    Fail "'$Package' did not install correctly ($Command still missing).`n`nTry running in a terminal: scoop install $Package"
}

# ============================================================================ shortcuts
# Recreate the launcher shortcuts if they are gone (fresh PC). Both go through cmd.exe like the
# FFXIV profile launchers so Windows offers "Pin to Start" for them. Removes the shortcuts of the
# three per-site scripts this one replaced. Never fatal.
function Ensure-Shortcuts {
    $bat = Join-Path $PSScriptRoot 'download-video.bat'
    if (-not (Test-Path -LiteralPath $bat)) { return }
    $videos    = Get-KnownFolder 'MyVideos' 'Videos'
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $cmdExe    = Join-Path $env:SystemRoot 'System32\cmd.exe'
    try {
        foreach ($old in 'Download Twitch VOD.lnk', 'Download YouTube Video.lnk', 'Download Instagram Post.lnk') {
            foreach ($dir in $startMenu, $videos) {
                $p = Join-Path $dir $old
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Info "Removed old shortcut: $p" }
            }
        }
        $ws = New-Object -ComObject WScript.Shell
        foreach ($t in @(@{ Path = Join-Path $startMenu 'Download Video.lnk'; Where = 'Start Menu' },
                         @{ Path = Join-Path $videos 'Download Video.lnk';    Where = 'Videos folder' })) {
            if (Test-Path -LiteralPath $t.Path) { continue }
            New-Item -ItemType Directory -Force -Path (Split-Path $t.Path) | Out-Null
            $s = $ws.CreateShortcut($t.Path)
            $s.TargetPath = $cmdExe
            $s.Arguments = "/c `"$bat`""
            $s.WorkingDirectory = $PSScriptRoot
            $s.Description = 'Downloads the Twitch, YouTube, Instagram or X link in the clipboard'
            $icon = Join-Path $PSScriptRoot 'download-video.ico'
            $s.IconLocation = if (Test-Path -LiteralPath $icon) { "$icon,0" } else { '%SystemRoot%\System32\imageres.dll,175' }
            $s.Save()
            if (Test-Path -LiteralPath $t.Path) { Write-Ok "Recreated shortcut in $($t.Where): $($t.Path)" } else { Write-Warn "Could not create shortcut: $($t.Path)" }
        }
        # "Compress all videos here": in Videos and in Downloads, a shortcut with the compress icon
        # whose "Start in" is pinned to that folder (a .lnk cannot know its own folder - with a
        # blank "Start in" it runs in its TARGET's folder, tested through Explorer), plus a copy of
        # compress-here.bat with the path to this folder filled in, to be copied into any other
        # folder (a .bat knows its folder from %~dp0, but Windows gives it no icon of its own).
        $folderBat = Join-Path $PSScriptRoot 'compress-folder.bat'
        $template  = Join-Path $PSScriptRoot 'compress-here.bat'
        $compIcon  = Join-Path $PSScriptRoot 'compress-video.ico'
        $text = if (Test-Path -LiteralPath $template) { [IO.File]::ReadAllText($template).Replace('__PCSETUP_OPTIONAL__', $PSScriptRoot) } else { $null }
        foreach ($dir in @($videos, (Get-DownloadsFolder))) {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            $lnk = Join-Path $dir 'Compress all videos here.lnk'
            if ((Test-Path -LiteralPath $folderBat) -and -not (Test-Path -LiteralPath $lnk)) {
                $s = $ws.CreateShortcut($lnk)
                $s.TargetPath = $cmdExe
                $s.Arguments = "/c `"`"$folderBat`" `"$($dir.TrimEnd('\'))`"`""
                $s.WorkingDirectory = $dir
                $s.Description = "Compresses every video in $dir to AV1 at the smallest size that still looks the same (VMAF 95+)"
                $s.IconLocation = if (Test-Path -LiteralPath $compIcon) { "$compIcon,0" } else { '%SystemRoot%\System32\imageres.dll,165' }
                $s.Save()
                if (Test-Path -LiteralPath $lnk) { Write-Ok "Created shortcut: $lnk" } else { Write-Warn "Could not create shortcut: $lnk" }
            }
            if ($text) {
                $p = Join-Path $dir 'Compress all videos here (copy into any folder).bat'
                $stale = Join-Path $dir 'Compress all videos here.bat'
                if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue }
                $current = if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { $null }
                if ($current -eq $text) { continue }
                [IO.File]::WriteAllText($p, $text, [Text.Encoding]::ASCII)
                Write-Ok "$(if ($current) { 'Updated' } else { 'Created' }) launcher: $p"
            }
        }
    } catch { Write-Warn "Shortcut check skipped: $($_.Exception.Message)" }
}

# ============================================================================ AV1 compression
# Every download, and every file given to -CompressFile / -CompressFolder, is re-encoded to 10-bit
# AV1 at the smallest size that still measures VMAF >= -MinVmaf (95) against the source - "no
# visible difference" - and only replaces the original when it is smaller AND that check passes on
# the finished file. Not lossless: it is a second lossy generation, kept below what VMAF considers
# visible. Say so if asked.
#
# Why a per-file quality search instead of one fixed crf: a Twitch VOD is generous (h264 at
# ~6 Mbit/s) and a fixed crf 35 halves it above VMAF 96, but a clip saved from X or Instagram has
# already been squeezed by the site, and the same crf then comes out BIGGER than the source at a
# LOWER score. Measured on 30 s of three such clips (2026-09-22, ffmpeg 9.0.1 / SVT-AV1 4.2.0,
# Ryzen 9 9950X3D + RTX 5080, driver 616.92, VMAF vmaf_v0.6.1 against the h264 source):
#   1922x962 30 fps, 2.4 Mbit/s h264:   NVENC p7 hq cq36  102%  VMAF 94.5    SVT-AV1 p4 crf35   50%  VMAF 91.3
#   1280x720 30 fps, 0.9 Mbit/s h264:   NVENC p7 hq cq36  105%  VMAF 92.8    SVT-AV1 p4 crf35   52%  VMAF 89.5
#    608x1080 60 fps, 1.0 Mbit/s h264:  NVENC p7 hq cq36  137%  VMAF 92.1    SVT-AV1 p4 crf35   75%  VMAF 89.3
# That is why the first Downloads batch kept 79 of 100 files: the fixed cq was both too big and,
# unnoticed, below the 95 the step promised. So the crf is now found per file: 15 s windows spread
# over the file are encoded and scored at a few crf values (Find-QualityCrf: bisection, ~5-6
# probes), the highest crf that still meets the target on those samples encodes the whole file,
# and the finished file is scored again on DIFFERENT windows before it replaces the original.
# A file that cannot get smaller without dropping below the target is kept, and the search says
# so before any full encode is spent on it.
#
# Encoder: SVT-AV1 preset 4 on the CPU by default, NVENC AV1 on the GPU with -Gpu. At the same
# VMAF, SVT-AV1 preset 4 is ~30% smaller than NVENC (clip 1 above: NVENC cq40 = 70% at 91.7,
# SVT-AV1 crf35 = 50% at 91.3), preset 4 is ~1% smaller than preset 6 at the same score for ~20%
# more time, and preset 2 gains nothing more at a third of the speed. NVENC's -tune uhq,
# lookahead level 3 and temporal filtering made no difference on AV1 here (identical bytes).
# Speed on this machine: SVT-AV1 preset 4 ~80 fps at 1080p, ~140 at 720p; NVENC ~215 / ~375 fps.
# The worker runs at below-normal priority, so all cores busy still leaves the PC usable; -Gpu is
# for when the hours matter more than the bytes (a 6 h VOD: ~5 h on the CPU, ~1.7 h on the GPU).
# av1_nvenc needs an RTX 40/50 card and a driver at least as new as the nvenc API ffmpeg was built
# against (596.21 failed with ffmpeg 9.0.1, 616.92 works). Windows plays AV1 .mp4 in the stock
# player once the free "AV1 Video Extension" is installed. An AV1 source is left alone: a third
# generation is never "without losing quality".
$script:Av1SvtPreset = '4'
function Get-Av1EncoderArgs([bool]$UseGpu, [int]$Crf) {
    if ($UseGpu) {
        return @('-c:v', 'av1_nvenc', '-preset', 'p7', '-tune', 'hq', '-rc', 'vbr', '-cq', "$Crf", '-b:v', '0',
                 '-multipass', 'fullres', '-spatial-aq', '1', '-temporal-aq', '1', '-rc-lookahead', '32', '-pix_fmt', 'p010le')
    }
    return @('-c:v', 'libsvtav1', '-preset', $script:Av1SvtPreset, '-crf', "$Crf", '-pix_fmt', 'yuv420p10le', '-svtav1-params', 'tune=0')
}

# 10 synthetic frames through the GPU encoder (about a second). Fails on machines without an
# NVIDIA card or with a driver too old for this ffmpeg build.
function Test-Av1Nvenc([string]$Ffmpeg) {
    $encArgs = Get-Av1EncoderArgs $true 36
    $null = Get-NativeOutput { & $Ffmpeg -hide_banner -loglevel error -nostdin -f lavfi -i 'color=size=256x256:rate=30' -frames:v 10 @encArgs -f null - }
    return ($LASTEXITCODE -eq 0)
}

# Bytes that must be free on the drive before a file of $Bytes is encoded: the encode sits next to
# the original until it is verified, and AV1 output is at most ~80% of the source or it is refused.
function Get-EncodeHeadroom([long]$Bytes) { return [long]($Bytes * 0.8) }

# Where the AV1 encode of $Path ends up: the same name for an .mp4, otherwise the .mp4 next to it
# (the encode is always an mp4 container, so a .mov/.mkv/.webm source cannot keep its extension).
function Get-Av1TargetPath([string]$Path) {
    if ([IO.Path]::GetExtension($Path) -ieq '.mp4') { return $Path }
    return [IO.Path]::ChangeExtension($Path, '.mp4')
}

# The videos directly inside $Dir that the folder mode will offer to Compress-Video, largest first:
# containers ffmpeg reads and remuxes to mp4 with the audio copied. Encode leftovers (.av1-tmp,
# .h264-old) are not videos to compress, and subfolders are deliberately not searched.
function Get-CompressCandidates([string]$Dir) {
    $exts = @('.mp4', '.m4v', '.mov', '.mkv', '.webm')
    return @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
             Where-Object { $exts -contains $_.Extension.ToLowerInvariant() } |
             Sort-Object Length -Descending)
}

# ---------------------------------------------------------------------------- quality search
# The windows of a file that the crf search encodes and scores: one of $SampleSeconds per 30 s
# of file, two at least and six at most, one per equal part of the file - so a short clip is
# sampled densely (a 2.5-minute one: five windows, half of it) and a 6-hour VOD still costs 90 s
# of encoding per probe, not hours. -Verify gives a second set that sits BETWEEN the search
# windows of the same file, so the check on the finished encode looks at footage the crf was not
# tuned on. A file no longer than two windows is measured whole, both times - and so is any file
# up to $WholeFileMax (30 min) when verifying: the check seeks the source AND the encode to the
# same second, and on a clip with a start offset and jittery timestamps (an X post: start 0.083,
# pts 0.083, 0.211, 0.128, 0.086...) the two seeks land on different frames - the finished encode
# "scored" 37.9 while the same crf's search samples, cut from one file, scored 96.0. Scoring the
# whole file from frame 0 needs no seek at all and is the definitive number anyway; only a VOD
# too long for that keeps the windowed check, and a VOD is constant-rate footage that seeks true.
function Get-SampleWindows([double]$Seconds, [int]$SampleSeconds = 15, [int]$MaxSamples = 6, [switch]$Verify, [int]$WholeFileMax = 1800) {
    if ($Seconds -le 2 * $SampleSeconds -or ($Verify -and $Seconds -le $WholeFileMax)) { return @([pscustomobject]@{ Start = 0.0; Length = [double]$Seconds }) }
    $count = [int][Math]::Max(2, [Math]::Min($MaxSamples, [Math]::Floor($Seconds / 30)))
    $part  = $Seconds / $count
    $slack = [Math]::Max(0.0, $part - 2 * $SampleSeconds)
    $out = @()
    for ($i = 0; $i -lt $count; $i++) {
        $start = if ($Verify) { $i * $part + $SampleSeconds + $slack * 0.75 } else { $i * $part + $slack * 0.25 }
        $start = [Math]::Max(0.0, [Math]::Min($start, $Seconds - $SampleSeconds))
        $out += [pscustomobject]@{ Start = [Math]::Round($start, 1); Length = [double]$SampleSeconds }
    }
    return @($out)
}

# The highest crf (= smallest file) whose sample encode still scores at least $TargetVmaf, found
# by walking out from $StartCrf in steps of $Step until a passing and a failing crf bracket the
# answer and then bisecting - five or six probes instead of a ladder. $Measure is a scriptblock
# taking a crf and returning @{ Vmaf; Ratio } (Ratio = encoded video bytes / source video bytes
# over the samples). Two ways to come back empty, each with a Reason: even $MinCrf misses the
# target, or a FAILING crf already comes out at $MaxRatio of the source or more - every lower crf
# is bigger still, so the file cannot get smaller without visible loss and the search stops at
# that first probe rather than encoding its way down to the floor.
function Find-QualityCrf([scriptblock]$Measure, [double]$TargetVmaf, [int]$StartCrf = 35, [int]$MinCrf = 20, [int]$MaxCrf = 55, [double]$MaxRatio = 1.0, [int]$Step = 6) {
    $seen = @{}
    $probe = { param([int]$c) if (-not $seen.ContainsKey($c)) { $seen[$c] = & $Measure $c }; return $seen[$c] }
    $pass = $null; $fail = $null
    $crf = [Math]::Max($MinCrf, [Math]::Min($MaxCrf, $StartCrf))
    while ($true) {
        $m = & $probe $crf
        if ($m.Vmaf -ge $TargetVmaf) {
            $pass = $crf
            if ($crf -ge $MaxCrf -or $null -ne $fail) { break }
            $crf = [Math]::Min($MaxCrf, $crf + $Step)
        } else {
            $fail = $crf
            if ($m.Ratio -ge $MaxRatio) {
                return [pscustomobject]@{ Crf = $null; Vmaf = $m.Vmaf; Ratio = $m.Ratio; Probes = $seen.Count
                    Reason = ('crf {0} is already not smaller ({1:0}% of the source) and only reaches VMAF {2:0.00} of the {3:0.0} the samples must show - every lower crf is bigger still' -f $crf, (100 * $m.Ratio), $m.Vmaf, $TargetVmaf) }
            }
            if ($crf -le $MinCrf -or $null -ne $pass) { break }
            $crf = [Math]::Max($MinCrf, $crf - $Step)
        }
    }
    if ($null -eq $pass) {
        $m = $seen[$MinCrf]
        return [pscustomobject]@{ Crf = $null; Vmaf = $m.Vmaf; Ratio = $m.Ratio; Probes = $seen.Count
            Reason = ('even crf {0} only reaches VMAF {1:0.0} (target {2:0.0})' -f $MinCrf, $m.Vmaf, $TargetVmaf) }
    }
    if ($null -ne $fail) {
        while ($fail - $pass -gt 1) {
            $mid = [int][Math]::Floor(($pass + $fail) / 2)
            $m = & $probe $mid
            if ($m.Vmaf -ge $TargetVmaf) { $pass = $mid } else { $fail = $mid }
        }
    }
    $best = $seen[$pass]
    return [pscustomobject]@{ Crf = $pass; Vmaf = $best.Vmaf; Ratio = $best.Ratio; Probes = $seen.Count; Reason = $null }
}

# The size the whole file should come out at when its video shrinks by $VideoRatio: the audio is
# copied, so it is taken out before scaling and put back unchanged.
function Get-PredictedBytes([long]$SourceBytes, [double]$Seconds, [double]$AudioBitsPerSecond, [double]$VideoRatio) {
    $audio = [long]($AudioBitsPerSecond * $Seconds / 8)
    $video = [Math]::Max([long]0, $SourceBytes - $audio)
    return [long]($video * $VideoRatio + $audio)
}

# ---------------------------------------------------------------------------- stamps
# The verdict on a file lives in the file itself, in the standard "comment" tag (Explorer shows
# it under Properties > Details), so a re-run of a folder needs no cache and no side files:
#   PCSetup: AV1 crf 41, VMAF 96.1 at target 95, SVT-AV1 preset 4, 2026-09-23     <- an encode of ours
#   PCSetup: kept, cannot get smaller at VMAF 95 (crf 29 = 116% at 93.7), 2026-09-23  <- checked, refused
# A site's own comment is kept in front of the stamp ("<theirs> | PCSetup: ..."), a newer stamp
# replaces an older one, and -Recheck ignores them. The kept stamp is written by a stream copy of
# the container (Set-VideoStamp: nothing is re-encoded, and the copy is verified before it
# replaces the file, with the file's dates put back so the folder looks untouched); a stamped
# "kept" file is skipped as long as its target is at least the current -MinVmaf, so lowering the
# bar tests it again.
function New-PcSetupStamp([string]$Kind, [int]$Crf = 0, [double]$Vmaf = 0, [double]$Target = 0, [string]$Encoder = '', [string]$Reason = '', [string]$Date = '') {
    if (-not $Date) { $Date = Get-Date -Format 'yyyy-MM-dd' }
    if ($Kind -eq 'av1') { return ('PCSetup: AV1 crf {0}, VMAF {1:0.0} at target {2:0.#}, {3}, {4}' -f $Crf, $Vmaf, $Target, $Encoder, $Date) }
    return ('PCSetup: kept, cannot get smaller at VMAF {0:0.#} ({1}), {2}' -f $Target, $Reason, $Date)
}

function ConvertFrom-PcSetupStamp([string]$Comment) {
    if (-not $Comment) { return $null }
    if ($Comment -match 'PCSetup: AV1 crf (\d+), VMAF ([\d.]+) at target ([\d.]+), (.+?), (\d{4}-\d{2}-\d{2})') {
        return [pscustomobject]@{ Kind = 'av1'; Crf = [int]$Matches[1]; Vmaf = [double]$Matches[2]; Target = [double]$Matches[3]; Encoder = $Matches[4]; Date = $Matches[5] }
    }
    if ($Comment -match 'PCSetup: kept, cannot get smaller at VMAF ([\d.]+) \((.*?)\), (\d{4}-\d{2}-\d{2})') {
        return [pscustomobject]@{ Kind = 'kept'; Target = [double]$Matches[1]; Reason = $Matches[2]; Date = $Matches[3] }
    }
    return $null
}

function Join-PcSetupComment([string]$Existing, [string]$Stamp) {
    $rest = if ($Existing) { ($Existing -replace '\s*\|?\s*PCSetup: .*$', '').Trim() } else { '' }
    if ($rest) { return "$rest | $Stamp" }
    return $Stamp
}

# The container's comment tag, or '' (multi-line comments come back joined).
function Get-VideoComment([string]$Path, [string]$Ffprobe) {
    $lines = @(Get-NativeOutput { & $Ffprobe -v error -show_entries format_tags=comment -of default=nw=1:nk=1 $Path })
    return (($lines | Where-Object { $null -ne $_ }) -join "`n").Trim()
}

# Writes $Stamp into $Path's comment tag in place through a stream copy (-c copy, so nothing is
# re-encoded), verifies the copy (same codec, tag, length within half a second, size within 2 %,
# stamp readable) and only then swaps it in, putting the file's dates back. $Format is the ffmpeg
# muxer for the copy (mp4 / mov). Returns $true when the file now carries the stamp.
function Set-VideoStamp([string]$Path, [string]$Format, [string]$Ffmpeg, [string]$Ffprobe, $Before, [string]$Existing, [string]$Stamp) {
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item -or -not $Format -or -not $Before) { return $false }
    $tmp = "$Path.stamp-tmp"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    $comment = Join-PcSetupComment -Existing $Existing -Stamp $Stamp
    $ffArgs = @('-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-i', $Path, '-map', '0', '-c', 'copy', '-metadata', "comment=$comment", '-f', $Format, $tmp)
    $null = Get-NativeOutput { & $Ffmpeg @ffArgs }
    $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $tmp)
    if ($ok) {
        $after = Get-VideoSpec $tmp $Ffprobe
        $size  = (Get-Item -LiteralPath $tmp).Length
        $ok = $after -and $after.Codec -eq $Before.Codec -and $after.Tag -eq $Before.Tag -and
              [Math]::Abs($after.Seconds - $Before.Seconds) -le 0.5 -and
              $size -ge $item.Length * 0.98 -and $size -le $item.Length * 1.02 -and
              $null -ne (ConvertFrom-PcSetupStamp (Get-VideoComment $tmp $Ffprobe))
    }
    if (-not $ok) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
    $old = "$Path.pre-stamp"
    try {
        Move-Item -LiteralPath $Path -Destination $old -Force -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $Path -ErrorAction Stop
        Remove-Item -LiteralPath $old -Force -ErrorAction Stop
    } catch {
        if (-not (Test-Path -LiteralPath $Path) -and (Test-Path -LiteralPath $old)) { Move-Item -LiteralPath $old -Destination $Path -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
    try { $new = Get-Item -LiteralPath $Path; $new.CreationTime = $item.CreationTime; $new.LastWriteTime = $item.LastWriteTime } catch {}
    return $true
}

# The muxer Set-VideoStamp uses for a file, from its extension; $null for containers it leaves alone.
function Get-StampFormat([string]$Path) {
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) { '.mp4' { return 'mp4' } '.m4v' { return 'mp4' } '.mov' { return 'mov' } }
    return $null
}

function Get-AudioBitsPerSecond([string]$Path, [string]$Ffprobe) {
    $lines = Get-NativeOutput { & $Ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 $Path }
    foreach ($l in $lines) { if ($l -match '^\s*(\d+)\s*$') { return [double]$Matches[1] } }
    return 0.0
}

# Mean VMAF of $Length seconds of $Distorted (from $DistortedStart) against the same stretch of
# $Reference (from $ReferenceStart), through libvmaf with its JSON log, or $null when ffmpeg
# fails. Both sides are decoded to 10-bit 4:2:0 first so an 8-bit h264 source and a 10-bit AV1
# encode compare on equal terms, and both get fresh, evenly spaced timestamps (settb + setpts=N)
# so libvmaf pairs the frames BY ORDER: it syncs its two inputs by timestamp, and on a
# variable-frame-rate clip (an X post at "60 fps" averaging 43) the same encode scored 73.5 paired
# by time and 93.0 paired by order - every VFR file was being refused on a bogus score. $Fps only
# shapes those timestamps so ffmpeg's time= progress still reads as a percentage of $Length.
function Measure-Vmaf([string]$Ffmpeg, [string]$Reference, [double]$ReferenceStart, [string]$Distorted, [double]$DistortedStart, [double]$Length, [string]$Label, $Pair, [double]$Fps = 30) {
    $fpsArg = '{0:0.###}' -f [Math]::Max(1.0, $Fps)
    # The log is a bare file name and ffmpeg runs from its folder: a full Windows path cannot be
    # given to a filter option, because the drive colon is the option separator and neither "\:"
    # nor "\\:" survives the two rounds of filtergraph parsing (tried, "No option name near").
    $logName = 'pcsetup-vmaf-' + [guid]::NewGuid().ToString('N') + '.json'
    $log     = Join-Path $env:TEMP $logName
    $threads = [Math]::Max(2, [Environment]::ProcessorCount)
    $graph = "[0:v]settb=AVTB,setpts=N/$fpsArg/TB,format=yuv420p10le[r];[1:v]settb=AVTB,setpts=N/$fpsArg/TB,format=yuv420p10le[d];[d][r]libvmaf=n_threads=${threads}:log_fmt=json:log_path=$logName"
    $ffArgs = @('-hide_banner', '-loglevel', 'warning', '-stats', '-nostdin', '-y',
                '-ss', ('{0:0.###}' -f $ReferenceStart), '-t', ('{0:0.###}' -f $Length), '-i', $Reference,
                '-ss', ('{0:0.###}' -f $DistortedStart), '-t', ('{0:0.###}' -f $Length), '-i', $Distorted,
                '-lavfi', $graph, '-f', 'null', '-')
    Push-Location -LiteralPath $env:TEMP
    try {
        $exit = Invoke-Streaming -Tool 'vmaf' -FfmpegLabel $Label -TotalSeconds $Length -Pair $Pair { & $Ffmpeg @ffArgs }
        if ($exit -ne 0 -or -not (Test-Path -LiteralPath $log)) { return $null }
        $json = Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
        $mean = $json.pooled_metrics.vmaf.mean
        if ($null -eq $mean) { return $null }
        return [double]$mean
    } catch { return $null }
    finally {
        Pop-Location
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
}

# Re-encodes $Path to AV1 in place and returns a one-line summary, or $null when nothing changed.
# Check -> search -> act -> verify -> swap: the crf is found on sample windows (above), the encode
# goes to "<file>.av1-tmp" next to the original (not .mp4, so a crash leaves nothing the version
# scan could mistake for a download), is probed for codec, resolution, frame rate, length and
# size, scored with VMAF on windows the search did not use, and only then replaces the original -
# via a rename of the original first, so there is never a moment with no good file. Every failure
# is a warning that keeps the source file: the download itself succeeded and must not be reported
# as failed.
function Compress-Video([string]$Path, [string]$Ffmpeg) {
    Write-Step 'Compressing to AV1'
    if ($NoCompress) { Write-Info 'Skipped (-NoCompress): keeping the file as it was downloaded.'; return $null }
    $ffprobe = Get-FfprobePath $Ffmpeg
    if (-not $ffprobe) { Write-Warn 'ffprobe not found - cannot verify an encode, keeping the file as it is.'; return $null }
    $before = Get-VideoSpec $Path $ffprobe
    if (-not $before) { Write-Warn 'ffprobe cannot read the file - keeping it as it is.'; return $null }
    $target  = [double]$MinVmaf
    $comment = Get-VideoComment $Path $ffprobe
    $stamp   = ConvertFrom-PcSetupStamp $comment
    if ($stamp -and -not $Recheck) {
        if ($stamp.Kind -eq 'av1') { Write-Ok "Already compressed by this script on $($stamp.Date): crf $($stamp.Crf), VMAF $($stamp.Vmaf) - nothing to do."; return 'already compressed, nothing to do' }
        if ($stamp.Kind -eq 'kept' -and $stamp.Target -le $target) { Write-Ok "Checked on $($stamp.Date): cannot get smaller at VMAF $($stamp.Target) ($($stamp.Reason)) - skipping. Run with -Recheck to test it again."; return 'already checked, kept' }
    }
    if ($before.Codec -eq 'av1') { Write-Ok 'Already AV1 - nothing to do.'; return 'already AV1, nothing to do' }
    $final = Get-Av1TargetPath $Path
    if ($final -ne $Path -and (Test-Path -LiteralPath $final)) { Write-Warn "Not compressing: $(Split-Path $final -Leaf) already exists next to it - keeping both as they are."; return $null }
    $oldBytes = (Get-Item -LiteralPath $Path).Length
    $oldMb    = [Math]::Round($oldBytes / 1MB)
    $srcCodec = $before.Codec
    Write-Ok "Source  : $srcCodec $($before.Tag), $(Format-Duration ([int]$before.Seconds)), $oldMb MB"
    if ($before.Seconds -le 0) { Write-Warn 'ffprobe reports no length for the file - keeping it as it is.'; return $null }

    # The encode sits next to the original until it is verified, so the drive needs room for both.
    $root   = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path).ProviderPath)
    $free   = (New-Object IO.DriveInfo $root).AvailableFreeSpace
    $needMb = [Math]::Round((Get-EncodeHeadroom $oldBytes) / 1MB)
    if ($free -lt (Get-EncodeHeadroom $oldBytes)) {
        Write-Warn "Not enough free space on $root to compress: the encode needs up to ~$needMb MB next to the original, $([Math]::Round($free / 1MB)) MB free. Keeping the $srcCodec file; run again with -CompressFile after freeing space."
        return $null
    }

    $useGpu = $Gpu -and (Test-Av1Nvenc $Ffmpeg)
    if ($Gpu -and -not $useGpu) { Write-Info 'No working NVENC AV1 encoder (needs an RTX 40/50 GPU and a current driver) - encoding on the CPU instead.' }
    $encName = if ($useGpu) { 'NVENC AV1 (GPU)' } else { "SVT-AV1 preset $script:Av1SvtPreset (CPU)" }
    # A refusal on quality or size is stamped into the file so the next run skips it in a second.
    $keep = {
        param([string]$Reason)
        $stamped = Set-VideoStamp -Path $Path -Format (Get-StampFormat $Path) -Ffmpeg $Ffmpeg -Ffprobe $ffprobe -Before $before -Existing $comment -Stamp (New-PcSetupStamp -Kind kept -Target $target -Reason $Reason)
        if ($stamped) { Write-Info 'Stamped that verdict into the file''s comment tag, so the next run skips this file (-Recheck tests it again).' }
        else { Write-Info 'The verdict could not be stamped into the file; it will be checked again next time.' }
    }
    Write-Ok "Encoder : $encName"
    Write-Ok ("Target  : VMAF {0:0.0} or better against the source (95+ = no visible difference), at the smallest size that still gets there" -f $target)
    $frames  = [long]($before.Seconds * $before.Fps)
    $typical = if ($useGpu) { 215 } else { 80 }
    Write-Ok ("Work    : {0:N0} frames; a crf search on sample windows first, then at the usual ~{1} fps about {2} for the encode, then the quality check" -f $frames, $typical, (Format-Duration ([int]($frames / $typical))))
    Write-Info "Progress below. $(Get-CancelHint) - the original file is kept either way."
    Write-Host ''

    $env:SVT_LOG = '2'    # SVT-AV1 prints a 20-line config banner through its own logger, ignoring -loglevel; 2 = warnings only
    $audioBps = Get-AudioBitsPerSecond $Path $ffprobe
    $videoBytesPerSecond = [Math]::Max(1.0, ($oldBytes - $audioBps * $before.Seconds / 8) / $before.Seconds)
    $windows  = @(Get-SampleWindows -Seconds $before.Seconds)
    $checks   = @(Get-SampleWindows -Seconds $before.Seconds -Verify)
    $workDir  = Join-Path $env:TEMP ('pcsetup-crf-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    $pair = New-StatusPairIfConsole
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        # ---- search: encode + score the sample windows at each crf the bisection asks for
        $measure = {
            param([int]$crf)
            $encBytes = 0L; $scores = @(); $srcBytes = 0.0
            for ($i = 0; $i -lt $windows.Count; $i++) {
                $w = $windows[$i]
                $sample = Join-Path $workDir "crf$crf-$i.mp4"
                $encArgs = Get-Av1EncoderArgs $useGpu $crf
                $label = 'crf {0} sample {1}/{2} encode' -f $crf, ($i + 1), $windows.Count
                $ffArgs = @('-hide_banner', '-loglevel', 'warning', '-stats', '-nostdin', '-y', '-ss', ('{0:0.###}' -f $w.Start), '-i', $Path, '-t', ('{0:0.###}' -f $w.Length)) + $encArgs + @('-g', '300', '-an', '-f', 'mp4', $sample)
                $exit = Invoke-Streaming -Tool 'ffmpeg' -FfmpegLabel $label -TotalSeconds $w.Length -Pair $pair { & $Ffmpeg @ffArgs }
                if ($exit -ne 0 -or -not (Test-Path -LiteralPath $sample)) { throw "ffmpeg exited with code $exit encoding sample $($i + 1) at crf $crf" }
                $encBytes += (Get-Item -LiteralPath $sample).Length
                $srcBytes += $videoBytesPerSecond * $w.Length
                $v = Measure-Vmaf $Ffmpeg $Path $w.Start $sample 0 $w.Length ('crf {0} sample {1}/{2} score' -f $crf, ($i + 1), $windows.Count) $pair $before.Fps
                Remove-Item -LiteralPath $sample -Force -ErrorAction SilentlyContinue
                if ($null -eq $v) { throw "VMAF could not be measured for sample $($i + 1) at crf $crf" }
                $scores += $v
            }
            $mean  = ($scores | Measure-Object -Average).Average
            $ratio = if ($srcBytes -gt 0) { $encBytes / $srcBytes } else { 1.0 }
            if ($pair) { & $pair.Clear }
            Write-Info ('crf {0}: VMAF {1:0.0}, ~{2:0}% of the source video' -f $crf, $mean, (100 * $ratio))
            return [pscustomobject]@{ Vmaf = $mean; Ratio = $ratio }
        }
        # A point of margin on the samples, so the finished file (checked on other windows) lands on
        # the right side of the target. A probe that cannot be encoded or scored ends the search at
        # once (the measure throws) rather than being read as "fails the target".
        try { $found = Find-QualityCrf -Measure $measure -TargetVmaf ($target + 1.0) -StartCrf 35 -MinCrf 20 -MaxCrf 55 -MaxRatio 0.97 }
        catch { if ($pair) { & $pair.Clear }; Write-Warn "Compression skipped: $($_.Exception.Message) - keeping the $srcCodec file."; return $null }
        if ($pair) { & $pair.Clear }
        if ($null -eq $found.Crf) {
            Write-Warn "Not compressing: $($found.Reason). This file cannot get smaller without visible loss; keeping the $srcCodec file."
            $lastCrf = if ($found.Reason -match 'crf (\d+)') { $Matches[1] } else { '?' }
            & $keep ('crf {0} = {1:0}% at {2:0.0}' -f $lastCrf, (100 * $found.Ratio), $found.Vmaf)
            return $null
        }
        $predicted = Get-PredictedBytes $oldBytes $before.Seconds $audioBps $found.Ratio
        Write-Ok ('Chosen  : crf {0} - VMAF {1:0.0} on {2} sample window(s), predicted ~{3:0}% ({4:N0} MB) after {5} probes in {6}' -f $found.Crf, $found.Vmaf, $windows.Count, (100.0 * $predicted / $oldBytes), ($predicted / 1MB), $found.Probes, (Format-Duration ([int]$sw.Elapsed.TotalSeconds)))
        if ($predicted -ge $oldBytes * 0.97) {
            Write-Warn ('Not compressing: at crf {0} the file would come out at ~{1:0}% of its size - not worth a second generation. Keeping the {2} file.' -f $found.Crf, (100.0 * $predicted / $oldBytes), $srcCodec)
            & $keep ('crf {0} would be {1:0}% at {2:0.0}' -f $found.Crf, (100.0 * $predicted / $oldBytes), $found.Vmaf)
            return $null
        }

        # ---- act + verify: the whole file at the chosen crf, then what ffprobe says about the result
        # and its score on windows the search never saw. Samples can flatter a file (on the test
        # clip two windows averaged 95.9 while the whole file scored 93.0), so a finished encode
        # that misses the target gets ONE more try at a lower crf - two points per point short -
        # before the file is given up on.
        $temp = "$Path.av1-tmp"
        $crf  = [int]$found.Crf
        $checked = $null; $lowest = $null; $newBytes = 0; $newMb = 0
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
            $encArgs = Get-Av1EncoderArgs $useGpu $crf
            $ffArgs = @('-hide_banner', '-loglevel', 'warning', '-stats', '-nostdin', '-y', '-i', $Path) + $encArgs + @('-g', '300', '-c:a', 'copy', '-f', 'mp4', $temp)
            $exit = Invoke-Streaming -Tool 'ffmpeg' -FfmpegLabel "Encoding crf $crf" -TotalSeconds $before.Seconds -Pair $pair { & $Ffmpeg @ffArgs }

            $after    = if (Test-Path -LiteralPath $temp) { Get-VideoSpec $temp $ffprobe } else { $null }
            $newBytes = if (Test-Path -LiteralPath $temp) { (Get-Item -LiteralPath $temp).Length } else { 0 }
            $newMb    = [Math]::Round($newBytes / 1MB)
            $problem  = $null
            if ($exit -ne 0)                                   { $problem = "ffmpeg exited with code $exit" }
            elseif (-not $after)                               { $problem = 'ffprobe cannot read the encoded file' }
            elseif ($after.Codec -ne 'av1')                    { $problem = "the encoded file is $($after.Codec), not av1" }
            elseif ($after.Tag -ne $before.Tag)                { $problem = "the encoded file is $($after.Tag), the source is $($before.Tag)" }
            elseif ($after.Seconds -lt $before.Seconds * 0.99) { $problem = "the encoded file is $(Format-Duration ([int]$after.Seconds)) long, the source is $(Format-Duration ([int]$before.Seconds))" }
            elseif ($newBytes -ge $oldBytes)                   { $problem = "the encoded file is not smaller ($newMb MB vs $oldMb MB)" }
            $checked = $null
            if (-not $problem) {
                $scores = @()
                for ($i = 0; $i -lt $checks.Count; $i++) {
                    $w = $checks[$i]
                    $v = Measure-Vmaf $Ffmpeg $Path $w.Start $temp $w.Start $w.Length ('Checking crf {0} quality {1}/{2}' -f $crf, ($i + 1), $checks.Count) $pair $before.Fps
                    if ($null -eq $v) { $problem = "VMAF could not be measured on check window $($i + 1)"; break }
                    $scores += $v
                }
                if (-not $problem) {
                    $checked = ($scores | Measure-Object -Average).Average
                    $lowest  = ($scores | Measure-Object -Minimum).Minimum
                    if ($checked -lt $target) {
                        $problem = ('the finished encode at crf {0} scores VMAF {1:0.0} on the check windows (lowest {2:0.0}), under the {3:0.0} target' -f $crf, $checked, $lowest, $target)
                        if ($attempt -eq 1) {
                            $lower = [Math]::Max(20, $crf - [Math]::Max(2, [int][Math]::Ceiling(2 * ($target - $checked))))
                            if ($lower -lt $crf) {
                                if ($pair) { & $pair.Clear }
                                Write-Warn ('The samples flattered this file: {0}. Encoding it again at crf {1}.' -f $problem, $lower)
                                $crf = $lower
                                continue
                            }
                        }
                    }
                }
            }
            break
        }
        if ($pair) { & $pair.Clear }
        if ($problem) {
            Write-Warn "Compression failed: $problem - keeping the original $srcCodec file."
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            # A verdict on size or quality is final for this file; an ffmpeg/ffprobe failure is not.
            if ($problem -match '^the encoded file is not smaller') { & $keep ('crf {0} came out at {1:0}%' -f $crf, (100.0 * $newBytes / $oldBytes)) }
            elseif ($problem -match 'scores VMAF') { & $keep ('crf {0} scored {1:0.0} on the finished file' -f $crf, $checked) }
            return $null
        }
        $where = if ($checks.Count -eq 1 -and $checks[0].Start -eq 0 -and $checks[0].Length -ge $before.Seconds) { 'the whole file' } else { '{0} windows the search did not use (lowest {1:0.0})' -f $checks.Count, $lowest }
        Write-Ok ('Checked : VMAF {0:0.0} on {1}' -f $checked, $where)

        # ---- stamp the encode with its verdict (a stream copy of the temp file; seconds), then swap
        $stamped = Set-VideoStamp -Path $temp -Format 'mp4' -Ffmpeg $Ffmpeg -Ffprobe $ffprobe -Before $after -Existing $comment -Stamp (New-PcSetupStamp -Kind av1 -Crf $crf -Vmaf $checked -Target $target -Encoder $encName)
        if (-not $stamped) { Write-Info 'The encode could not be stamped with its verdict (it is still used); a re-run will see it as plain AV1.' }
        $newBytes = (Get-Item -LiteralPath $temp).Length
        $newMb    = [Math]::Round($newBytes / 1MB)
        $old = "$Path.h264-old"
        try {
            Move-Item -LiteralPath $Path -Destination $old -Force -ErrorAction Stop
            Move-Item -LiteralPath $temp -Destination $final -ErrorAction Stop
        } catch {
            Write-Warn "Could not replace the original: $($_.Exception.Message)"
            if (-not (Test-Path -LiteralPath $Path) -and (Test-Path -LiteralPath $old)) { Move-Item -LiteralPath $old -Destination $Path -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            return $null
        }
        try { Remove-Item -LiteralPath $old -Force -ErrorAction Stop }
        catch { Write-Warn "The AV1 file is in place but the $srcCodec original could not be deleted - remove it by hand: $old" }

        $pct     = [Math]::Round(100.0 * $newBytes / $oldBytes)
        $summary = ('AV1 crf {0} {1} MB from {2} MB {3} ({4}%), VMAF {5:0.0}, in {6} with {7}' -f $crf, $newMb, $oldMb, $srcCodec, $pct, $checked, (Format-Duration ([int]$sw.Elapsed.TotalSeconds)), $encName)
        if ($final -ne $Path) { $summary += ", now $(Split-Path $final -Leaf)" }
        Write-Ok "Result  : $summary"
        return $summary
    }
    finally {
        if ($pair) { & $pair.End }
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================ site: Twitch
function Invoke-Twitch([string]$VodId) {
    Write-Step 'Checking tools'
    Ensure-Shortcuts
    Ensure-Scoop
    $cli    = Resolve-ScoopTool 'TwitchDownloaderCLI' 'twitchdownloader-cli'
    $ffmpeg = Resolve-ScoopTool 'ffmpeg' 'ffmpeg'

    Write-Step 'Fetching VOD info'
    $infoLines = Get-NativeOutput { & $cli info --id $VodId --format Raw --banner false }
    $jsonLine = $infoLines | Where-Object { $_ -like '{"data":{"video":{"title"*' } | Select-Object -First 1
    if (-not $jsonLine) {
        $tail = ($infoLines | Select-Object -Last 8) -join "`n"
        Fail "Could not read VOD info for id $VodId. It may be deleted, sub-only, or the link is wrong.`n`n$tail"
    }
    $video = (ConvertFrom-Json $jsonLine).data.video
    if (-not $video) { Fail "Twitch returned no video for id $VodId (deleted or private?)." }
    $title   = [string]$video.title
    $channel = if ($video.owner.displayName) { [string]$video.owner.displayName } else { [string]$video.owner.login }
    $date    = ([DateTime]$video.createdAt).ToLocalTime().ToString('yyyy-MM-dd')
    $length  = [int]$video.lengthSeconds
    Write-Ok "Channel : $channel"
    Write-Ok "Title   : $title"
    Write-Ok "Streamed: $date"
    Write-Ok "Length  : $(Format-Duration $length)"
    if ($video.game.displayName) { Write-Ok "Game    : $($video.game.displayName)" }

    # Available qualities come from the m3u8 part of the info output:
    #   #EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="720p60",NAME="720p60",...
    #   #EXT-X-STREAM-INF:BANDWIDTH=...,RESOLUTION=1280x720,...,FRAME-RATE=60.000
    $qualities = @()
    for ($i = 0; $i -lt $infoLines.Count; $i++) {
        if ($infoLines[$i] -match '^#EXT-X-MEDIA:TYPE=VIDEO,.*NAME="([^"]+)"') {
            $name = $Matches[1]
            $next = if ($i + 1 -lt $infoLines.Count) { $infoLines[$i + 1] } else { '' }
            if ($next -match 'RESOLUTION=(\d+)x(\d+)') {
                $height = [int]$Matches[2]
                $fps = if ($next -match 'FRAME-RATE=([\d.]+)') { [double]$Matches[1] } else { 30 }
                $bw  = if ($next -match 'BANDWIDTH=(\d+)') { [long]$Matches[1] } else { 0 }
                $qualities += [pscustomobject]@{ Name = $name; Height = $height; Fps = $fps; Bandwidth = $bw }
            }
        }
    }
    if (-not $qualities) { Fail 'No video qualities were listed for this VOD.' }
    Write-Info ("Available: " + (($qualities | ForEach-Object { $_.Name }) -join ', '))
    # No cap by default: take the highest resolution, then the highest frame rate. With -MaxHeight,
    # take the best variant at or under it, falling back to the lowest one if nothing fits.
    $candidates = @($qualities)   # not `= if {...} else {...}`: a one-element array would unroll (5.1)
    if ($MaxHeight -gt 0) { $candidates = @($qualities | Where-Object { $_.Height -le $MaxHeight }) }
    $pick = $candidates | Sort-Object Height, Fps -Descending | Select-Object -First 1
    if (-not $pick) { $pick = $qualities | Sort-Object Height, Fps | Select-Object -First 1 }
    $capNote = if ($MaxHeight -gt 0) { "max allowed ${MaxHeight}p" } else { 'best available' }
    Write-Ok "Quality : $($pick.Name) ($($pick.Height)p, $capNote)"

    Write-Step 'Preparing output'
    $videosDir = Get-KnownFolder 'MyVideos' 'Videos'
    $safeTitle = Get-SafeName $title 120; if (-not $safeTitle) { $safeTitle = 'untitled' }
    $tag      = Format-QualityTag $pick.Height $pick.Fps     # from the resolution, not $pick.Name ("1080p60 (source)")
    $baseName = "$date $(Get-SafeName $channel 40) - $safeTitle [$VodId]"
    $fileName = "$baseName [$tag].mp4"
    $outPath  = Join-Path $videosDir $fileName
    Write-Ok "Folder  : $videosDir"
    Write-Ok "File    : $fileName"
    $expected = if ($Ending) { 0 } else { $length }
    # An earlier download of this exact quality that predates the AV1 step is compressed before
    # its folder is opened, so re-running the link on an old h264 file is the way to shrink it.
    Resolve-ExistingVersions -Dir $videosDir -Id $VodId -BaseName $baseName -Tag $tag -ExpectedSeconds $expected -Ffprobe (Get-FfprobePath $ffmpeg) `
        -BeforeShowExisting { param($existing) $null = Compress-Video $existing $ffmpeg }

    $tempDir = Join-Path $env:TEMP 'TwitchDownloader'
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    # The CLI writes every .ts part into a fresh "<id>_<ticks>" folder under the temp path and never
    # reuses or removes it when a run fails - two failed attempts at a 5-hour VOD left 15 GB behind.
    # Nothing in there is resumable, so clear it before and after every run.
    $clearTemp = {
        Get-ChildItem -LiteralPath $tempDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            try { [IO.Directory]::Delete($_.FullName, $true) } catch { Write-Warn "Could not remove old temp parts $($_.Name): $($_.Exception.Message)" }
        }
    }
    $stale = @(Get-ChildItem -LiteralPath $tempDir -Directory -ErrorAction SilentlyContinue)
    if ($stale.Count) {
        $staleGb = [Math]::Round((Get-ChildItem -LiteralPath $tempDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB, 1)
        Write-Warn "Removing $($stale.Count) leftover temp folder(s) from earlier runs ($staleGb GB)"
        & $clearTemp
    }

    # Free-space check: parts land on the temp drive, then ffmpeg writes the final file to the
    # Videos drive, so both need room. Estimate from the stream's declared bandwidth. Skipped for
    # -Ending test runs. This is what failed silently on a 5-hour VOD with 3 GB free on Z:.
    if (-not $Ending -and $pick.Bandwidth -gt 0) {
        $needBytes = [long]($pick.Bandwidth / 8 * $length * 1.15)
        $needGb    = [Math]::Round($needBytes / 1GB, 1)
        Write-Ok "Estimated size: ~$needGb GB"
        foreach ($check in @(@{ Path = $videosDir; What = 'Videos folder' }, @{ Path = $tempDir; What = 'temp folder (download parts)' })) {
            $root = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $check.Path).ProviderPath)
            $free = (New-Object IO.DriveInfo $root).AvailableFreeSpace
            $freeGb = [Math]::Round($free / 1GB, 1)
            if ($free -lt $needBytes) {
                Fail "Not enough disk space on $root for the $($check.What).`n`nNeeded: ~$needGb GB (${length}s at $($pick.Name))`nFree:   $freeGb GB on $root`n`nFree up space on $root or pick a lower quality with -MaxHeight 720 (or 480), then try again."
            }
            Write-Ok "Free on ${root}: $freeGb GB ($($check.What))"
        }
        # The AV1 step afterwards holds the h264 file and its encode side by side until the encode
        # is verified. Not a reason to refuse the download - the step skips itself if space is short.
        if (-not $NoCompress) {
            $videosRoot = [IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $videosDir).ProviderPath)
            $videosFree = (New-Object IO.DriveInfo $videosRoot).AvailableFreeSpace
            if ($videosFree -lt $needBytes * 1.8) { Write-Warn "AV1 compression afterwards needs ~$([Math]::Round($needBytes * 0.8 / 1GB, 1)) GB more on $videosRoot and will be skipped if that is not free by then." }
        }
    }

    Write-Step "Downloading $($pick.Name) with 24 parallel threads"
    Write-Info "Progress below. $(Get-CancelHint)."
    Write-Host ''
    $cliArgs = @('videodownload', '--id', $VodId, '-o', $outPath, '-q', $pick.Name, '--threads', '24',
                 '--ffmpeg-path', $ffmpeg, '--temp-path', $tempDir, '--collision', 'Overwrite', '--banner', 'false')
    if ($Ending) { $cliArgs += @('-e', $Ending) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $exit = Invoke-Streaming -Tool 'TwitchDownloaderCLI' { & $cli @cliArgs }
    $sw.Stop()
    & $clearTemp

    if (-not (Test-Path -LiteralPath $outPath) -or (Get-Item -LiteralPath $outPath).Length -lt 1MB) {
        $freeNow = [Math]::Round((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($videosDir))).AvailableFreeSpace / 1GB, 1)
        Fail "Download did not produce a usable file (exit code $exit).`n`nExpected: $outPath`nFree space on the Videos drive now: $freeNow GB`n`nScroll up in the window for the CLI's error."
    }
    if ($exit -ne 0) { Write-Warn "TwitchDownloaderCLI exited with code $exit but the file exists - check it plays." }
    $downloaded = "{0} MB downloaded in {1} at {2}" -f [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB), (Format-Duration ([int]$sw.Elapsed.TotalSeconds)), $pick.Name

    $compressed = Compress-Video $outPath $ffmpeg
    $summary = if ($compressed) { "$downloaded; $compressed" } else { $downloaded }
    Finish $outPath $summary
}

# ============================================================================ site: YouTube
function Invoke-YouTube([string]$VideoId) {
    $cleanUrl = "https://www.youtube.com/watch?v=$VideoId"
    Write-Step 'Checking tools'
    Ensure-Shortcuts
    Ensure-Scoop
    $ytdlp  = Resolve-ScoopTool 'yt-dlp' 'yt-dlp'
    $ffmpeg = Resolve-ScoopTool 'ffmpeg' 'ffmpeg'
    $deno   = Resolve-ScoopTool 'deno'   'deno'     # JS runtime yt-dlp needs to unlock all YouTube formats

    # Highest resolution available (or <= MaxHeight when given), then highest fps; at equal resolution
    # prefer h264 + aac in mp4: it plays in anything and is the cleanest source for the AV1 step that
    # follows (a download that is already AV1 is left as it is). Resolution outranks codec, so a
    # 1440p/4K VP9-only upload is still taken at full size. yt-dlp merges separate video/audio
    # streams with ffmpeg.
    $resKey = if ($MaxHeight -gt 0) { "res:$MaxHeight" } else { 'res' }
    $common = @('--no-playlist', '-f', 'bv*+ba/b', '-S', "$resKey,fps,vcodec:h264,acodec:m4a,ext:mp4",
                '--ffmpeg-location', $ffmpeg, '--js-runtimes', "deno:$deno")

    Write-Step 'Fetching video info'
    $cookieArgs = @(); $infoJson = $null; $lastErr = ''
    # Try without cookies first; if YouTube demands a sign-in ("confirm you're not a bot"), retry
    # with the cookies of an installed browser. Each attempt is one yt-dlp call.
    foreach ($attempt in @(@(), @('--cookies-from-browser', 'firefox'), @('--cookies-from-browser', 'chrome'), @('--cookies-from-browser', 'edge'))) {
        $raw = Get-NativeOutput { & $ytdlp @common @attempt --no-download --no-warnings --dump-single-json $cleanUrl }
        $line = $raw | Where-Object { $_ -like '{*' } | Select-Object -First 1
        if ($line) { $infoJson = $line; $cookieArgs = $attempt; break }
        $lastErr = ($raw | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1)
        if ($lastErr -notmatch 'sign in|not a bot|cookies') { break }
        if ($attempt.Count) { Write-Warn "Blocked with $($attempt[1]) cookies too" } else { Write-Warn 'YouTube asked for a sign-in - retrying with browser cookies' }
    }
    if (-not $infoJson) { Fail "Could not read the video info.`n`n$lastErr`n`nPrivate, removed, age-restricted, or YouTube is blocking downloads right now." }
    $info = ConvertFrom-Json $infoJson
    if ($cookieArgs.Count) { Write-Ok "Using $($cookieArgs[1]) cookies" }
    $title   = [string]$info.title
    $channel = if ($info.channel) { [string]$info.channel } elseif ($info.uploader) { [string]$info.uploader } else { 'YouTube' }
    $date    = if ($info.upload_date -match '^(\d{4})(\d{2})(\d{2})$') { "$($Matches[1])-$($Matches[2])-$($Matches[3])" } else { Get-Date -Format 'yyyy-MM-dd' }
    $length  = [int]$info.duration
    $sizeGuess = if ($info.filesize_approx) { [Math]::Round($info.filesize_approx / 1MB) } elseif ($info.filesize) { [Math]::Round($info.filesize / 1MB) } else { $null }
    Write-Ok "Channel : $channel"
    Write-Ok "Title   : $title"
    Write-Ok "Uploaded: $date"
    Write-Ok "Length  : $(Format-Duration $length)"
    $capNote = if ($MaxHeight -gt 0) { "max allowed ${MaxHeight}p" } else { 'best available' }
    Write-Ok "Quality : $($info.format_id) $($info.width)x$($info.height) $($info.fps)fps $($info.vcodec) + $($info.acodec) ($capNote)"
    if ($sizeGuess) { Write-Ok "Size    : ~$sizeGuess MB" }
    if ($info.is_live) { Fail 'This is a live stream that is still running. Wait until it ends, then download the recording.' }

    Write-Step 'Preparing output'
    $videosDir = Get-KnownFolder 'MyVideos' 'Videos'
    $safeTitle = Get-SafeName $title 120; if (-not $safeTitle) { $safeTitle = 'untitled' }
    $tag      = Format-QualityTag ([int]$info.height) ([double]$info.fps)
    $idBase   = "$date $(Get-SafeName $channel 40) - $safeTitle [$VideoId]"
    $baseName = "$idBase [$tag]"
    $outPath  = Join-Path $videosDir "$baseName.mp4"
    Write-Ok "Folder  : $videosDir"
    Write-Ok "File    : $baseName.mp4"
    $expected = if ($Ending) { 0 } else { $length }
    # An earlier download of this exact quality that predates the AV1 step is compressed before
    # its folder is opened, so re-running the link on an old h264 file is the way to shrink it.
    Resolve-ExistingVersions -Dir $videosDir -Id $VideoId -BaseName $idBase -Tag $tag -ExpectedSeconds $expected -Ffprobe (Get-FfprobePath $ffmpeg) `
        -BeforeShowExisting { param($existing) $null = Compress-Video $existing $ffmpeg }

    Write-Step 'Downloading with 16 parallel fragment connections'
    Write-Info "Progress below. $(Get-CancelHint)."
    Write-Host ''
    # yt-dlp needs %(ext)s in the template; with --merge-output-format mp4 the result is always .mp4.
    # --force-overwrites: a file already at this exact name was judged incomplete or mis-tagged above,
    # and yt-dlp would otherwise skip the download and report success.
    $dlArgs = $common + $cookieArgs + @('--merge-output-format', 'mp4', '-N', '16', '--no-mtime', '--progress', '--force-overwrites',
                                        '-o', (Join-Path $videosDir "$baseName.%(ext)s"))
    if ($Ending) { $dlArgs += @('--download-sections', "*0-$Ending", '--force-keyframes-at-cuts') }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $exit = Invoke-Streaming -Tool 'yt-dlp' { & $ytdlp @dlArgs $cleanUrl }
    $sw.Stop()

    if (-not (Test-Path -LiteralPath $outPath) -or (Get-Item -LiteralPath $outPath).Length -lt 200KB) {
        Fail "Download did not produce a usable file (exit code $exit).`n`nExpected: $outPath`n`nScroll up in the window for yt-dlp's error."
    }
    if ($exit -ne 0) { Write-Warn "yt-dlp exited with code $exit but the file exists - check it plays." }
    $downloaded = "{0} MB downloaded in {1} at {2}p" -f [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB), (Format-Duration ([int]$sw.Elapsed.TotalSeconds)), $info.height

    $compressed = Compress-Video $outPath $ffmpeg
    $summary = if ($compressed) { "$downloaded; $compressed" } else { $downloaded }
    Finish $outPath $summary
}

# ============================================================================ site: Instagram
function Invoke-Instagram([string]$Shortcode, [string]$Kind) {
    $cleanUrl = "https://www.instagram.com/$Kind/$Shortcode/"
    Write-Step 'Checking tools'
    Ensure-Shortcuts
    Ensure-Scoop
    $ytdlp     = Resolve-ScoopTool 'yt-dlp'     'yt-dlp'
    $ffmpeg    = Resolve-ScoopTool 'ffmpeg'     'ffmpeg'
    $gallerydl = Resolve-ScoopTool 'gallery-dl' 'gallery-dl'

    # Instagram needs a logged-in session for nearly every post; Get-LoginSources says how the login
    # gets here. The extension names the export "www.instagram.com_cookies.txt".
    $cookieSets = Get-LoginSources -CookieFile (Join-Path $env:APPDATA 'PCSetup\instagram-cookies.txt') -ExportFilters @('*instagram.com_cookies*.txt') -DomainPattern 'instagram\.com'
    $loginHelp = "Instagram only serves this post to a logged-in account, and Chrome does not let tools read its login.`n`n" +
                 "One-time setup (about a minute):`n" +
                 "1. In Chrome install the extension 'Get cookies.txt LOCALLY' (open source, works offline).`n" +
                 "2. Open instagram.com while logged in, click the extension icon, click Export.`n" +
                 "3. Leave the file in Downloads (www.instagram.com_cookies.txt) - this tool picks it up on the next run.`n`n" +
                 "The export stays valid until you log out of Instagram in Chrome. Re-export if downloads start failing again."

    Write-Step 'Fetching post info'
    $common = @('--no-playlist', '-f', 'bv*+ba/b', '-S', 'res,fps,vcodec:h264,acodec:m4a,ext:mp4', '--ffmpeg-location', $ffmpeg)
    $info = $null; $used = $null; $lastErr = ''; $sawLoginWall = $false
    foreach ($set in $cookieSets) {
        $raw = Get-NativeOutput { & $ytdlp @common @($set.Args) --no-download --no-warnings --dump-single-json $cleanUrl }
        $line = $raw | Where-Object { $_ -like '{*' } | Select-Object -First 1
        if ($line) { $info = ConvertFrom-Json $line; $used = $set; break }
        $lastErr = ($raw | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1)
        if ($lastErr -match 'empty media response|login|log in|cookies|not accessible|rate.?limit|403|401') { $sawLoginWall = $true }
        Write-Warn "yt-dlp with $($set.Name): $lastErr"
        if ($lastErr -match 'No video formats|no video|is not a video|image') { break }   # photo post - gallery-dl handles it
    }

    if ($info) {
        # ----- reel / video via yt-dlp -----
        Write-Ok "Using $($used.Name)"
        $user    = if ($info.uploader) { [string]$info.uploader } elseif ($info.channel) { [string]$info.channel } else { 'instagram' }
        $caption = if ($info.description) { [string]$info.description } elseif ($info.title) { [string]$info.title } else { '' }
        $date    = if ($info.upload_date -match '^(\d{4})(\d{2})(\d{2})$') { "$($Matches[1])-$($Matches[2])-$($Matches[3])" } else { Get-Date -Format 'yyyy-MM-dd' }
        Write-Ok "Account : $user"
        Write-Ok "Caption : $(Get-SafeName $caption 100)"
        Write-Ok "Posted  : $date"
        if ([int]$info.duration) { Write-Ok "Length  : $([int]$info.duration)s" }
        Write-Ok "Quality : $($info.format_id) $($info.width)x$($info.height) $($info.vcodec) + $($info.acodec)"

        Write-Step 'Preparing output'
        $videosDir = Get-KnownFolder 'MyVideos' 'Videos'
        $safeCaption = Get-SafeName $caption 60
        $baseName = if ($safeCaption) { "$date $(Get-SafeName $user 40) - $safeCaption [$Shortcode]" } else { "$date $(Get-SafeName $user 40) [$Shortcode]" }
        $outPath  = Join-Path $videosDir "$baseName.mp4"
        Write-Ok "Folder  : $videosDir"
        Write-Ok "File    : $baseName.mp4"
        if (Test-Path -LiteralPath $outPath) { $null = Compress-Video $outPath $ffmpeg; Show-Existing $outPath }   # an earlier h264 download is shrunk first

        Write-Step 'Downloading'
        Write-Host ''
        $dlArgs = $common + $used.Args + @('--merge-output-format', 'mp4', '-N', '8', '--no-mtime', '--progress', '-o', (Join-Path $videosDir "$baseName.%(ext)s"))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $exit = Invoke-Streaming -Tool 'yt-dlp' { & $ytdlp @dlArgs $cleanUrl }
        $sw.Stop()
        if (-not (Test-Path -LiteralPath $outPath) -or (Get-Item -LiteralPath $outPath).Length -lt 50KB) {
            Fail "Download did not produce a usable file (exit code $exit).`n`nExpected: $outPath`n`nScroll up in the window for yt-dlp's error."
        }
        if ($exit -ne 0) { Write-Warn "yt-dlp exited with code $exit but the file exists - check it plays." }
        $downloaded = "{0} MB downloaded in {1}s" -f [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB, 1), [int]$sw.Elapsed.TotalSeconds
        $compressed = Compress-Video $outPath $ffmpeg
        $summary = if ($compressed) { "$downloaded; $compressed" } else { $downloaded }
        Finish $outPath $summary
    }

    # ----- photo post / carousel via gallery-dl -----
    Write-Warn 'yt-dlp found no video - trying gallery-dl (photo posts and carousels)'
    $meta = $null; $used = $null; $gdErr = ''
    foreach ($set in $cookieSets) {
        $raw = Get-NativeOutput { & $gallerydl @($set.Args) -j $cleanUrl }
        $json = ($raw | Where-Object { $_ -notmatch '^\[' }) -join "`n"
        try { $parsed = ConvertFrom-Json $json } catch { $parsed = $null }
        if ($parsed -and $parsed.Count -and -not ($parsed | Where-Object { $_.error })) { $meta = $parsed; $used = $set; break }
        $gdErr = ($raw | Where-Object { $_ -match 'error' } | Select-Object -Last 1)
        if ($gdErr -match 'login|log in|cookies|401|403|Abort') { $sawLoginWall = $true }
        Write-Warn "gallery-dl with $($set.Name): $gdErr"
    }
    if (-not $meta) {
        if ($sawLoginWall) { Fail "$loginHelp`n`nLast error: $lastErr $gdErr" }
        Fail "Could not read this post.`n`nyt-dlp: $lastErr`ngallery-dl: $gdErr`n`nThe post may be private, deleted, or Instagram is blocking right now."
    }
    Write-Ok "Using $($used.Name)"
    # gallery-dl -j prints [[type, url, metadata], ...]; take metadata from the first file entry (type 3).
    $m = ($meta | Where-Object { $_[0] -eq 3 } | Select-Object -First 1)
    $md = if ($m) { $m[2] } else { $meta[-1][-1] }
    $user    = if ($md.username) { [string]$md.username } elseif ($md.fullname) { [string]$md.fullname } else { 'instagram' }
    $caption = if ($md.description) { [string]$md.description } else { '' }
    $date    = if ($md.date -and "$($md.date)" -match '^(\d{4}-\d{2}-\d{2})') { $Matches[1] } else { Get-Date -Format 'yyyy-MM-dd' }
    $count   = @($meta | Where-Object { $_[0] -eq 3 }).Count
    Write-Ok "Account : $user"
    Write-Ok "Caption : $(Get-SafeName $caption 100)"
    Write-Ok "Posted  : $date"
    Write-Ok "Files   : $count"

    Write-Step 'Preparing output'
    $picturesDir = Get-KnownFolder 'MyPictures' 'Pictures'
    $safeCaption = Get-SafeName $caption 60
    $baseName = if ($safeCaption) { "$date $(Get-SafeName $user 40) - $safeCaption [$Shortcode]" } else { "$date $(Get-SafeName $user 40) [$Shortcode]" }
    $tempDir = Join-Path $env:TEMP "InstagramDownload\$Shortcode"
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    Write-Ok "Folder  : $picturesDir"
    Write-Ok "Name    : $baseName"

    Write-Step 'Downloading'
    Invoke-Native { & $gallerydl @($used.Args) -D $tempDir -f '{num}.{extension}' $cleanUrl }
    $files = @(Get-ChildItem -LiteralPath $tempDir -File | Sort-Object { [int]($_.BaseName -replace '\D', '0') })
    if (-not $files.Count) { Fail "gallery-dl downloaded nothing.`n`nScroll up in the window for its error." }
    $finalPaths = @()
    for ($i = 0; $i -lt $files.Count; $i++) {
        $suffix = if ($files.Count -gt 1) { " ($($i + 1) of $($files.Count))" } else { '' }
        $dest = Join-Path $picturesDir "$baseName$suffix$($files[$i].Extension)"
        Move-Item -LiteralPath $files[$i].FullName -Destination $dest -Force
        $finalPaths += $dest
        Write-Ok "Saved: $(Split-Path $dest -Leaf)"
    }
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    Finish $finalPaths[0] "$($files.Count) file(s) in $picturesDir"
}

# ============================================================================ site: X (Twitter)
# Two ways in. yt-dlp's twitter extractor works for what X shows guests, and with a cookie export
# for everything a logged-in account can see. Without a login, a post the poster flagged as
# sensitive answers "No video could be found in this tweet" - yet the video files on
# video.twimg.com are public. The embed services fxtwitter and vxtwitter (the link fixers people
# paste in Discord) list those files for any public post, so they are the fallback: no login, no
# extension, and the exact same mp4 X serves. Verified 2026-09-20 on a sensitive-flagged post that
# yt-dlp could not see with any cookie set on this PC.

# Normalises a tweet from api.fxtwitter.com (tweet.media.videos[].formats, a bitrate per
# resolution) or api.vxtwitter.com (media_extended[], one URL per video) into one shape: Source,
# Author (the @handle), Name, Text (without the t.co media link X appends), Date (UTC), Sensitive
# and Videos[] with Seconds and Formats[] (Url, Width, Height, Bitrate) sorted small to large. $null
# for a body that is not JSON or holds no tweet (fxtwitter answers code 404 with tweet null from
# some edge nodes for a post that others serve); a post without video has an empty Videos list.
function ConvertFrom-TweetApi([string]$Json, [string]$Source) {
    if (-not $Json -or -not $Json.TrimStart().StartsWith('{')) { return $null }
    try { $data = ConvertFrom-Json $Json } catch { return $null }
    $videos = @(); $author = ''; $name = ''; $text = ''; $epoch = [long]0; $sensitive = $false
    if ($Source -eq 'fxtwitter') {
        $tweet = $data.tweet
        if (-not $tweet -or -not $tweet.id) { return $null }
        $author = [string]$tweet.author.screen_name; $name = [string]$tweet.author.name
        $text = [string]$tweet.text; $epoch = [long]$tweet.created_timestamp; $sensitive = [bool]$tweet.possibly_sensitive
        $list = @(); if ($tweet.media -and $tweet.media.videos) { $list = @($tweet.media.videos) }
        foreach ($v in $list) {
            $formats = @()
            foreach ($f in @($v.formats)) {
                if (-not $f -or $f.container -ne 'mp4' -or -not $f.url) { continue }
                $w = 0; $h = 0
                if ($f.url -match '/(\d+)x(\d+)/') { $w = [int]$Matches[1]; $h = [int]$Matches[2] }
                $formats += [pscustomobject]@{ Url = [string]$f.url; Width = $w; Height = $h; Bitrate = [long]$f.bitrate }
            }
            if (-not $formats.Count -and $v.url) { $formats += [pscustomobject]@{ Url = [string]$v.url; Width = [int]$v.width; Height = [int]$v.height; Bitrate = [long]0 } }
            if ($formats.Count) { $videos += [pscustomobject]@{ Seconds = [double]$v.duration; Formats = @($formats | Sort-Object Height, Bitrate) } }
        }
    }
    elseif ($Source -eq 'vxtwitter') {
        if (-not $data.tweetID) { return $null }
        $author = [string]$data.user_screen_name; $name = [string]$data.user_name
        $text = [string]$data.text; $epoch = [long]$data.date_epoch; $sensitive = [bool]$data.possibly_sensitive
        foreach ($m in @($data.media_extended)) {
            if (-not $m -or $m.type -notin @('video', 'gif') -or -not $m.url) { continue }
            $w = [int]$m.size.width; $h = [int]$m.size.height
            if ($m.url -match '/(\d+)x(\d+)/') { $w = [int]$Matches[1]; $h = [int]$Matches[2] }
            $videos += [pscustomobject]@{ Seconds = ([double]$m.duration_millis / 1000); Formats = @([pscustomobject]@{ Url = [string]$m.url; Width = $w; Height = $h; Bitrate = [long]0 }) }
        }
    }
    else { return $null }
    $text = ($text -replace 'https?://t\.co/\S+', '').Trim()
    $date = if ($epoch -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime.ToString('yyyy-MM-dd') } else { Get-Date -Format 'yyyy-MM-dd' }
    return [pscustomobject]@{ Source = $Source; Author = $author; Name = $name; Text = $text; Date = $date; Sensitive = $sensitive; Videos = @($videos) }
}

# The format to download: the largest at or under $Cap pixels tall (0 = no cap), else the smallest.
function Select-TweetFormat($Video, [int]$Cap) {
    $all = @($Video.Formats | Sort-Object Height, Bitrate)
    if (-not $all.Count) { return $null }
    $fit = $all
    if ($Cap -gt 0) { $fit = @($all | Where-Object { $_.Height -le $Cap }) }   # not `= if {...}`: a one-element array would unroll
    if ($fit.Count) { return $fit[-1] }
    return $all[0]
}

# The post's metadata without a login, from fxtwitter first and vxtwitter second. Each gets a few
# attempts a second apart because fxtwitter's answer for the same post differs by edge node. A
# service that sees the post but no video in it ends the attempts for that service; the other one
# still gets its turn, and that no-video answer is returned when nothing better turns up. $null
# when neither answered, with the reasons in $script:TweetApiErrors.
function Get-TweetFromApi([string]$TweetId) {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $script:TweetApiErrors = @()
    $noVideo = $null
    $sources = @(
        @{ Name = 'fxtwitter'; Url = "https://api.fxtwitter.com/status/$TweetId"; Attempts = 3 },
        @{ Name = 'vxtwitter'; Url = "https://api.vxtwitter.com/i/status/$TweetId"; Attempts = 2 }
    )
    foreach ($src in $sources) {
        for ($i = 1; $i -le $src.Attempts; $i++) {
            if ($i -gt 1) { Start-Sleep -Seconds 1 }
            $body = $null
            try {
                $wc = New-Object Net.WebClient
                $wc.Encoding = [Text.Encoding]::UTF8
                $wc.Headers['User-Agent'] = 'Mozilla/5.0 PCSetup-download-video'
                $body = $wc.DownloadString($src.Url)
            } catch {
                $script:TweetApiErrors += "$($src.Name) attempt ${i}: $($_.Exception.Message)"
                continue
            }
            $tweet = ConvertFrom-TweetApi $body $src.Name
            if ($tweet -and $tweet.Videos.Count) { return $tweet }
            if ($tweet) { $noVideo = $tweet; $script:TweetApiErrors += "$($src.Name): sees the post but no video in it"; break }
            $script:TweetApiErrors += "$($src.Name) attempt ${i}: no post in the answer ($(([string]$body).Length) bytes)"
        }
    }
    return $noVideo
}

function Invoke-X([string]$TweetId) {
    $cleanUrl = "https://x.com/i/status/$TweetId"
    Write-Step 'Checking tools'
    Ensure-Shortcuts
    Ensure-Scoop
    $ytdlp  = Resolve-ScoopTool 'yt-dlp' 'yt-dlp'
    $ffmpeg = Resolve-ScoopTool 'ffmpeg' 'ffmpeg'
    # The extension names the export "x.com_cookies.txt" (older exports say twitter.com).
    $cookieSets = Get-LoginSources -CookieFile (Join-Path $env:APPDATA 'PCSetup\x-cookies.txt') -ExportFilters @('*x.com_cookies*.txt', '*twitter.com_cookies*.txt') -DomainPattern 'x\.com|twitter\.com'
    $loginHelp = "X only shows this post to a logged-in account, and Chrome does not let tools read its login.`n`n" +
                 "One-time setup (about a minute):`n" +
                 "1. In Chrome install the extension 'Get cookies.txt LOCALLY' (open source, works offline).`n" +
                 "2. Open x.com while logged in, click the extension icon, click Export.`n" +
                 "3. Leave the file in Downloads (x.com_cookies.txt) - this tool picks it up on the next run.`n`n" +
                 "The export stays valid until you log out of X in Chrome. Re-export if downloads start failing again."
    # "No video could be found" is also what a guest gets for a sensitive-flagged video post.
    $wallPattern = 'requires authentication|not authorized|protected|login|log in|cookies|No video could be found|401|403'

    Write-Step 'Fetching post info'
    $resKey  = if ($MaxHeight -gt 0) { "res:$MaxHeight" } else { 'res' }
    $capNote = if ($MaxHeight -gt 0) { "max allowed ${MaxHeight}p" } else { 'best available' }
    $common  = @('-f', 'bv*+ba/b', '-S', "$resKey,fps,vcodec:h264,acodec:m4a,ext:mp4", '--ffmpeg-location', $ffmpeg)
    $info = $null; $used = $null; $lastErr = ''; $sawLoginWall = $false
    foreach ($set in $cookieSets) {
        $raw = Get-NativeOutput { & $ytdlp @common @($set.Args) --no-download --no-warnings --dump-single-json $cleanUrl }
        $line = $raw | Where-Object { $_ -like '{*' } | Select-Object -First 1
        if ($line) { $info = ConvertFrom-Json $line; $used = $set; break }
        $lastErr = ($raw | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1)
        Write-Warn "yt-dlp with $($set.Name): $lastErr"
        if ($lastErr -match $wallPattern) { $sawLoginWall = $true } else { break }
    }

    $downloads = @()    # one per video: yt-dlp arguments, the URL to hand it, height and length
    if ($info) {
        Write-Ok "Using $($used.Name)"
        # Never `$x = if (...) { @(...) }`: the if-expression flows through the pipeline and a
        # one-element array unrolls to the bare object, whose .Count is empty in 5.1 - the first
        # live run built zero downloads from a perfectly good single-video post that way.
        $isList  = ($info._type -eq 'playlist')
        $entries = @($info)
        if ($isList) { $entries = @($info.entries) }
        $first   = $entries[0]
        $author  = if ($info.uploader_id) { [string]$info.uploader_id } elseif ($first.uploader_id) { [string]$first.uploader_id } elseif ($info.uploader) { [string]$info.uploader } else { 'x' }
        $text    = if ($info.description) { [string]$info.description } elseif ($first.description) { [string]$first.description } else { '' }
        $ud      = if ($info.upload_date) { [string]$info.upload_date } else { [string]$first.upload_date }
        $date    = if ($ud -match '^(\d{4})(\d{2})(\d{2})$') { "$($Matches[1])-$($Matches[2])-$($Matches[3])" } else { Get-Date -Format 'yyyy-MM-dd' }
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $e = $entries[$i]
            $dlArgs = $common + $used.Args + @('--merge-output-format', 'mp4', '-N', '8')
            if ($isList) { $dlArgs += @('--playlist-items', "$($i + 1)") }
            $downloads += @{ Args = $dlArgs; Target = $cleanUrl; Height = [int]$e.height; Seconds = [double]$e.duration
                             Quality = "$($e.format_id) $($e.width)x$($e.height) $($e.vcodec) + $($e.acodec) ($capNote)" }
        }
    }
    else {
        Write-Warn 'Trying the public embed services (fxtwitter, vxtwitter) - they list media X hides from guests'
        $tweet  = Get-TweetFromApi $TweetId
        $apiErr = ($script:TweetApiErrors -join "`n")
        if (-not $tweet) {
            if ($sawLoginWall) { Fail "$loginHelp`n`nyt-dlp: $lastErr`n$apiErr" }
            Fail "Could not read this post.`n`nyt-dlp: $lastErr`n$apiErr`n`nThe post may be private, deleted, or X is blocking right now."
        }
        if (-not $tweet.Videos.Count) { Fail "This post has no video ($($tweet.Source) sees the post but no video in it).`n`nyt-dlp: $lastErr`n`nPhotos and text posts are not downloaded by this tool." }
        Write-Ok "Using $($tweet.Source) embed data (no login)"
        $author = $tweet.Author; $text = $tweet.Text; $date = $tweet.Date
        foreach ($v in $tweet.Videos) {
            $fmt = Select-TweetFormat $v $MaxHeight
            $downloads += @{ Args = @('-N', '8'); Target = $fmt.Url; Height = $fmt.Height; Seconds = $v.Seconds
                             Quality = "$($fmt.Width)x$($fmt.Height) h264 $([Math]::Round($fmt.Bitrate / 1000)) kbit/s ($capNote)" }
        }
    }
    $text = ($text -replace 'https?://t\.co/\S+', '').Trim()
    Write-Ok "Account : $author"
    Write-Ok "Text    : $(Get-SafeName $text 100)"
    Write-Ok "Posted  : $date"
    if ($downloads.Count -gt 1) { Write-Ok "Videos  : $($downloads.Count)" }
    foreach ($d in $downloads) {
        $len = if ($d.Seconds -ge 1) { ", $(Format-Duration ([int]$d.Seconds))" } else { '' }
        Write-Ok "Quality : $($d.Quality)$len"
    }

    Write-Step 'Preparing output'
    $videosDir = Get-KnownFolder 'MyVideos' 'Videos'
    $safeText  = Get-SafeName $text 60
    $baseName  = if ($safeText) { "$date $(Get-SafeName $author 40) - $safeText [$TweetId]" } else { "$date $(Get-SafeName $author 40) [$TweetId]" }
    $paths = @()
    for ($i = 0; $i -lt $downloads.Count; $i++) {
        $suffix = if ($downloads.Count -gt 1) { " ($($i + 1) of $($downloads.Count))" } else { '' }
        $paths += Join-Path $videosDir "$baseName$suffix.mp4"
    }
    Write-Ok "Folder  : $videosDir"
    foreach ($p in $paths) { Write-Ok "File    : $(Split-Path $p -Leaf)" }
    $missing = @($paths | Where-Object { -not (Test-Path -LiteralPath $_) })
    if (-not $missing.Count) {
        # Already there: an earlier h264 download is shrunk before its folder is opened.
        foreach ($p in $paths) { $null = Compress-Video $p $ffmpeg }
        Show-Existing $paths[0]
    }

    Write-Step 'Downloading'
    Write-Info "Progress below. $(Get-CancelHint)."
    Write-Host ''
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $sizes = @()
    for ($i = 0; $i -lt $downloads.Count; $i++) {
        $d = $downloads[$i]; $outPath = $paths[$i]; $target = $d.Target
        if (Test-Path -LiteralPath $outPath) { Write-Info "Already downloaded: $(Split-Path $outPath -Leaf)"; continue }
        # yt-dlp needs %(ext)s in the template (a literal % in the name must be doubled) and would skip
        # a partial file at this name and report success without --force-overwrites.
        $template = [IO.Path]::GetFileNameWithoutExtension($outPath) -replace '%', '%%'
        $dlArgs = $d.Args + @('--no-mtime', '--progress', '--force-overwrites', '-o', (Join-Path $videosDir "$template.%(ext)s"))
        $exit = Invoke-Streaming -Tool 'yt-dlp' { & $ytdlp @dlArgs $target }
        if (-not (Test-Path -LiteralPath $outPath) -or (Get-Item -LiteralPath $outPath).Length -lt 50KB) {
            Fail "Download did not produce a usable file (exit code $exit).`n`nExpected: $outPath`n`nScroll up in the window for yt-dlp's error."
        }
        if ($exit -ne 0) { Write-Warn "yt-dlp exited with code $exit but the file exists - check it plays." }
        $sizes += "{0} MB at {1}p" -f [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB, 1), $d.Height
    }
    $sw.Stop()
    $downloaded = "{0} downloaded in {1}s" -f ($sizes -join ' + '), [int]$sw.Elapsed.TotalSeconds

    $compressed = @()
    foreach ($p in $paths) { $c = Compress-Video $p $ffmpeg; if ($c) { $compressed += $c } }
    $summary = if ($compressed.Count) { "$downloaded; " + ($compressed -join '; ') } else { $downloaded }
    Finish $paths[0] $summary
}

# ============================================================================ folder mode
# Every video directly inside a folder through Compress-Video, largest first, as one job: the same
# check -> encode -> verify -> swap per file, so a file that would not get smaller (already lean
# X/Instagram clips) or that fails is kept as it is and the run carries on. The summary counts
# what changed and what did not, and the folder is opened at the end.
function Invoke-CompressFolder([string]$Dir) {
    Write-Step 'Compressing every video in a folder'
    Ensure-Shortcuts
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { Fail "Folder not found: $Dir" }
    $Dir = (Resolve-Path -LiteralPath $Dir).ProviderPath
    Write-Ok "Folder  : $Dir"
    Ensure-Scoop
    $ffmpeg = Resolve-ScoopTool 'ffmpeg' 'ffmpeg'
    $files = @(Get-CompressCandidates $Dir)
    if (-not $files.Count) { Fail "No videos (.mp4, .m4v, .mov, .mkv, .webm) directly inside $Dir.`n`nSubfolders are not searched - drop one onto compress-folder.bat instead." }
    $totalBytes = ($files | Measure-Object Length -Sum).Sum
    Write-Ok ("Videos  : {0} files, {1:N2} GB, largest first" -f $files.Count, ($totalBytes / 1GB))
    Write-Info "Each encode is verified before it replaces the original; a file that would not get smaller is kept. $(Get-CancelHint)."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $done = @(); $kept = @(); $already = @(); $deferred = @(); $saved = [long]0
    $root = [IO.Path]::GetPathRoot($Dir)
    # Largest first means the biggest file meets the emptiest drive: the 5 GB file in Downloads
    # needed 4 GB of headroom with 3.8 GB free and was skipped before a single byte had been
    # reclaimed. A file the drive cannot hold yet is deferred and tried once more at the end,
    # when the earlier encodes have freed their share; Compress-Video keeps its own check.
    $queue = @($files | ForEach-Object { @{ File = $_; Pass = 1 } })
    $n = 0
    while ($queue.Count) {
        $item = $queue[0]; $queue = @($queue | Select-Object -Skip 1)
        $f = Get-Item -LiteralPath $item.File.FullName -ErrorAction SilentlyContinue
        if (-not $f) { continue }
        $n++
        $passNote = if ($item.Pass -gt 1) { ' (second pass, after space was freed)' } else { '' }
        Write-Step ("[{0}/{1}] {2} ({3:N0} MB){4}" -f $n, $files.Count, $f.Name, ($f.Length / 1MB), $passNote)
        $free = (New-Object IO.DriveInfo $root).AvailableFreeSpace
        if ($free -lt (Get-EncodeHeadroom $f.Length)) {
            if ($item.Pass -eq 1) {
                Write-Warn ("Deferred: needs ~{0:N0} MB free next to it, {1:N0} MB free on {2} - trying again after the other files." -f ((Get-EncodeHeadroom $f.Length) / 1MB), ($free / 1MB), $root)
                $deferred += $f.Name
                $queue += @{ File = $f; Pass = 2 }
                $n--
                continue
            }
            Write-Warn ("Still not enough room on {0} ({1:N0} MB free) - keeping the file as it is." -f $root, ($free / 1MB))
            $kept += $f.Name
            continue
        }
        $result = Compress-Video $f.FullName $ffmpeg
        if ($result -like 'already*') { $already += $f.Name; continue }
        if (-not $result) { $kept += $f.Name; continue }
        $target = Get-Av1TargetPath $f.FullName
        $after = if (Test-Path -LiteralPath $target) { (Get-Item -LiteralPath $target).Length } else { $f.Length }
        $saved += ($f.Length - $after)
        $done += $f.Name
    }
    $sw.Stop()
    Write-Step 'Summary'
    $savedText = if ($saved -ge 1GB) { '{0:N2} GB' -f ($saved / 1GB) } else { '{0:N0} MB' -f ($saved / 1MB) }    # "0.00 GB" hid a 25 MB run
    $line = "{0} of {1} compressed, {2} saved in {3}" -f $done.Count, $files.Count, $savedText, (Format-Duration ([int]$sw.Elapsed.TotalSeconds))
    Write-Ok $line
    if ($already.Count) { Write-Ok "Already done: $($already.Count) (AV1 already, or stamped as compressed / checked by an earlier run)" }
    if ($deferred.Count) { Write-Info "Deferred to a second pass for space: $($deferred.Count)" }
    if ($kept.Count) {
        Write-Warn "Kept as they were (encode not smaller, or failed - the reason is above each one): $($kept.Count)"
        foreach ($k in $kept) { Write-Info "  $k" }
    }
    Finish $Dir $line
}

# ============================================================================ background job
# The work runs in a hidden, detached worker - this same script with -Worker - at below-normal
# priority (ffmpeg and the downloaders inherit it), so it never chugs the PC and does not care
# whether a window is open. Its stdout is the job log; its progress pair goes to a small status
# file. The visible window is only a viewer that tails the log and redraws the pair, and the
# launcher re-attaches to a running job instead of starting another: one job at a time.
$script:JobDir    = Join-Path $env:LOCALAPPDATA 'PCSetup\download-video'
$script:JobFile   = Join-Path $script:JobDir 'job.json'
# The log, error and status files are named per job (job-<stamp>.log/.err/.status) and recorded
# in job.json. They used to be fixed names, and a new job started by deleting the old ones - which
# fails while any earlier viewer window still has the log open (a viewer frozen in a QuickEdit
# selection, or simply one left open), so the launcher died on Remove-Item with its window
# closing at once and no job started. Now an old window can only ever hold its own files.
function Set-JobFiles([string]$Stamp) {
    $script:JobLog    = Join-Path $script:JobDir "job-$Stamp.log"
    $script:JobErr    = Join-Path $script:JobDir "job-$Stamp.err"
    $script:JobStatus = Join-Path $script:JobDir "job-$Stamp.status"
}
Set-JobFiles $(if ($env:PCSETUP_JOB_STAMP) { $env:PCSETUP_JOB_STAMP } else { 'current' })

# The job whose worker process is still alive, or $null. A stale job.json (PC rebooted, worker
# killed) is recognised by the PID being gone or belonging to a different, newer process.
function Get-RunningJob {
    if (-not (Test-Path -LiteralPath $script:JobFile)) { return $null }
    try { $job = Get-Content -LiteralPath $script:JobFile -Raw | ConvertFrom-Json } catch { return $null }
    $proc = Get-Process -Id ([int]$job.Pid) -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    try { if ($proc.StartTime.Ticks -ne [long]$job.ProcStart) { return $null } } catch {}
    return $job
}

# Worker side: the two status lines for the viewer, written atomically (temp file + rename).
function Write-JobStatus([string]$Bar, [string]$Raw, [string]$Title, [string]$State = '') {
    $tmp = "$script:JobStatus.tmp"
    try {
        [IO.File]::WriteAllText($tmp, "$Bar`n$Raw`n$Title`n$State", (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $script:JobStatus -Force
    } catch {}
}

function Start-BackgroundJob([string]$Description) {
    New-Item -ItemType Directory -Force -Path $script:JobDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Set-JobFiles $stamp
    $env:PCSETUP_JOB_STAMP = $stamp    # inherited by the worker, which writes job-<stamp>.status
    # Older jobs' files go now; one still held open by a lingering viewer is simply left for later.
    Get-ChildItem -LiteralPath $script:JobDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^job(-.+)?\.(log|err|status)$' -and $_.Name -notlike "job-$stamp.*" } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    $wargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Worker', '-MaxHeight', $MaxHeight)
    if ($Url)          { $wargs += @('-Url', "`"$Url`"") }
    if ($CompressFile) { $wargs += @('-CompressFile', "`"$CompressFile`"") }
    if ($CompressFolder) { $wargs += @('-CompressFolder', "`"$CompressFolder`"") }
    if ($Ending)       { $wargs += @('-Ending', "`"$Ending`"") }
    if ($NoCompress)   { $wargs += '-NoCompress' }
    if ($Gpu)          { $wargs += '-Gpu' }
    if ($Recheck)      { $wargs += '-Recheck' }
    if ($PSBoundParameters.ContainsKey('MinVmaf')) { $wargs += @('-MinVmaf', "$MinVmaf") }
    if ($NoMessageBox) { $wargs += '-NoMessageBox' }
    $p = Start-Process powershell -ArgumentList $wargs -WindowStyle Hidden -RedirectStandardOutput $script:JobLog -RedirectStandardError $script:JobErr -PassThru
    try { $p.PriorityClass = 'BelowNormal' } catch {}
    $ticks = try { $p.StartTime.Ticks } catch { 0 }
    $job = [pscustomobject]@{ Pid = $p.Id; ProcStart = $ticks; Started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Description = $Description
                              Log = $script:JobLog; Err = $script:JobErr; Status = $script:JobStatus }
    [IO.File]::WriteAllText($script:JobFile, ($job | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    return $job
}

# Worker side, on every exit path: the viewer notices the PID vanish, this just tidies up.
function Complete-WorkerJob {
    Write-JobStatus '' '' ''
    Remove-Item -LiteralPath $script:JobFile -Force -ErrorAction SilentlyContinue
}

# Viewer: print the worker's log lines as they arrive (markers back to colours), keep the status
# pair redrawn from the status file, watch for X to cancel, and finish the way the old inline run
# did - result lines, Explorer already opened by the worker, 8 s countdown, the worker's exit code.
function Watch-BackgroundJob($Job) {
    # This job's own files (a re-attached viewer reads them from job.json).
    if ($Job.Log) { $script:JobLog = $Job.Log; $script:JobErr = $Job.Err; $script:JobStatus = $Job.Status }
    Write-Step 'Background job'
    Write-Ok   "Working on: $($Job.Description)"
    Write-Info "Since $($Job.Started), worker PID $($Job.Pid), below-normal priority"
    Write-Warn 'Close this window any time - the work carries on. Run Download Video again to watch it. Press X here to cancel it.'
    $pair = New-StatusPair
    $utf8 = New-Object Text.UTF8Encoding $false
    $decoder = $utf8.GetDecoder()
    $buf = New-Object byte[] 65536
    $chars = New-Object char[] 131072
    $fs = $null; $pending = ''; $exitCode = 0; $finished = $false
    $st = @{ LastStatus = '' }
    $colors = @{ S = 'Cyan'; K = 'Green'; I = 'Gray'; W = 'Yellow'; F = 'Red'; D = 'Green' }
    $cancel = {
        & $pair.Clear
        Write-Warn "Cancelling: stopping worker $($Job.Pid) and everything it started..."
        & taskkill.exe /PID $Job.Pid /T /F 2>&1 | Out-Null
        Remove-Item -LiteralPath $script:JobFile -Force -ErrorAction SilentlyContinue
        Write-Warn 'Cancelled. A half-written file may remain; the next run cleans it up.'
        exit 1
    }
    # Status file -> pair. A finished stage ("end" flag) is drawn one last time and fixed in place,
    # so the lines that follow it in the log print underneath rather than above it.
    $applyStatus = {
        $status = try { [IO.File]::ReadAllText($script:JobStatus, $utf8) } catch { $st.LastStatus }
        if ($status -eq $st.LastStatus) { return }
        $st.LastStatus = $status
        $parts = $status -split "`n"
        if ($parts[0]) {
            & $pair.Draw $parts[0] $(if ($parts.Count -gt 1) { $parts[1] } else { '' })
            if ($parts.Count -gt 2 -and $parts[2]) { try { $Host.UI.RawUI.WindowTitle = $parts[2] } catch {} }
            if ($parts.Count -gt 3 -and $parts[3] -eq 'end') { & $pair.End }
        } else {
            & $pair.End
        }
    }
    while ($true) {
        $alive = [bool](Get-Process -Id ([int]$Job.Pid) -ErrorAction SilentlyContinue)
        & $applyStatus
        if (-not $fs -and (Test-Path -LiteralPath $script:JobLog)) {
            try { $fs = New-Object IO.FileStream($script:JobLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)) } catch { $fs = $null }
        }
        if ($fs) {
            while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                $c = $decoder.GetChars($buf, 0, $n, $chars, 0)
                $pending += New-Object string ($chars, 0, $c)
            }
            $printed = $false
            # Log lines are written after the status they belong to, so look once more before
            # printing them: an "end" that landed in between must be applied first.
            if ($pending.IndexOf("`n") -ge 0) { & $applyStatus }
            while (($i = $pending.IndexOf("`n")) -ge 0) {
                $line = $pending.Substring(0, $i).TrimEnd("`r"); $pending = $pending.Substring($i + 1)
                if (-not $printed) { & $pair.Clear; $printed = $true }
                if ($line -match '^([SKIWFD])\|(.*)$') {
                    if ($Matches[1] -eq 'F') { $exitCode = 1; $finished = $true }
                    if ($Matches[1] -eq 'D') { $finished = $true }
                    Write-Host $Matches[2] -ForegroundColor $colors[$Matches[1]]
                } else {
                    Write-Host $line
                }
            }
            if ($printed) { & $pair.Redraw }
        }
        if (-not $alive) { break }
        try { if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq 'X') { & $cancel } } } catch {}
        Start-Sleep -Milliseconds 150
    }
    & $pair.End
    if ($fs) { $fs.Close() }
    if ($pending.Trim()) { Write-Host $pending }
    $err = try { [IO.File]::ReadAllText($script:JobErr, $utf8) } catch { '' }
    if ($err.Trim()) {
        # Only PowerShell itself writes here: a crash of the worker, not a tool failure.
        $exitCode = 1
        Write-Host ''
        Write-Host 'The background worker stopped with an error:' -ForegroundColor Red
        Write-Host $err.Trim() -ForegroundColor Red
    }
    if (-not $finished -and -not $err.Trim()) {
        # Neither DONE nor FAILED reached the log: the worker was killed (cancelled from another
        # viewer, Task Manager, a reboot). Say so instead of closing as if it had succeeded.
        $exitCode = 1
        Write-Host ''
        Write-Warn 'The background job stopped before finishing (cancelled or killed). Nothing was completed.'
    }
    try { $Host.UI.RawUI.WindowTitle = 'Download Video' } catch {}
    for ($s = 8; $s -gt 0; $s--) {
        Write-Host -NoNewline "`r      Closing in $s s... "
        Start-Sleep -Seconds 1
    }
    exit $exitCode
}

# ============================================================================ main
if ($Worker) {
    try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch {}
} else {
    $null = Disable-ConsoleQuickEdit    # a click in this window must never freeze the display
}
if ($CompressDownloads -and -not $CompressFolder) { $CompressFolder = Get-DownloadsFolder }
if (-not $CompressFile -and -not $Url -and -not $CompressFolder) {
    # A file path in the clipboard (Explorer's "Copy as path" puts it there in quotes) means
    # "compress this", so compress-video.bat and download-video.bat both do the whole job.
    try { $clip = (Get-Clipboard -Raw -ErrorAction Stop) } catch { $clip = '' }
    $clip = if ($clip) { $clip.Trim().Trim('"') } else { '' }
    if ($clip -and $clip -notmatch '^[a-z]+://' -and (Test-Path -LiteralPath $clip -PathType Leaf)) { $CompressFile = $clip }
    elseif ($clip) { $Url = $clip }
}

if (-not $Inline -and -not $Worker) {
    # Launcher / viewer. A running job wins over whatever was just asked for.
    $running = Get-RunningJob
    if ($running) {
        if ($Url -or $CompressFile -or $CompressFolder) {
            Write-Step 'A job is already running'
            Write-Warn "One at a time: the link/file you just gave was NOT started. Run it again after this one finishes."
        }
        Watch-BackgroundJob $running
    }
    if (-not $Url -and -not $CompressFile -and -not $CompressFolder) { Fail 'The clipboard is empty. Copy a Twitch VOD, YouTube video, Instagram reel/post or X post link (or a video file path) and run this again.' }
    $desc = if ($CompressFolder) { "compress every video in $CompressFolder" } elseif ($CompressFile) { "compress $(Split-Path $CompressFile -Leaf)" } else { $Url }
    Write-Step 'Starting'
    Write-Ok "Job     : $desc"
    Watch-BackgroundJob (Start-BackgroundJob $desc)
}

try {
    if ($CompressFolder) { Invoke-CompressFolder $CompressFolder }
    if ($CompressFile) {
        # Shrink an existing file (an earlier download, or anything h264) and stop.
        Write-Step 'Compressing an existing file'
        Ensure-Shortcuts
        if (-not (Test-Path -LiteralPath $CompressFile -PathType Leaf)) { Fail "File not found: $CompressFile" }
        $CompressFile = (Resolve-Path -LiteralPath $CompressFile).ProviderPath
        Write-Ok "File    : $CompressFile"
        Ensure-Scoop
        $ffmpeg = Resolve-ScoopTool 'ffmpeg' 'ffmpeg'
        $result = Compress-Video $CompressFile $ffmpeg
        if (-not $result) { Fail "The file was not compressed - see the reason above.`n`n$CompressFile" }
        Finish $CompressFile $result
    }

    Write-Step 'Reading link'
    if (-not $Url) { Fail 'The clipboard is empty. Copy a Twitch VOD, YouTube video, Instagram reel/post or X post link and run this again.' }

    $link = Resolve-VideoLink $Url
    if (-not $link) {
        $preview = if ($Url.Length -gt 80) { $Url.Substring(0, 80) + '...' } else { $Url }
        Fail "The clipboard does not contain a link this tool understands.`n`nClipboard: $preview`n`nSupported:`n  https://www.twitch.tv/videos/123456789`n  https://www.youtube.com/watch?v=XXXXXXXXXXX  (also youtu.be, shorts, live)`n  https://www.instagram.com/reel/XXXXXXXXXXX/  (also /p/ posts)`n  https://x.com/<user>/status/123456789  (also twitter.com)"
    }
    switch ($link.Site) {
        'twitch'    { Write-Ok "Twitch VOD $($link.Id)";              Invoke-Twitch $link.Id }
        'youtube'   { Write-Ok "YouTube video $($link.Id)";           Invoke-YouTube $link.Id }
        'instagram' { Write-Ok "Instagram $($link.Kind) $($link.Id)"; Invoke-Instagram $link.Id $link.Kind }
        'x'         { Write-Ok "X post $($link.Id)";                  Invoke-X $link.Id }
    }
}
finally {
    if ($Worker) { Complete-WorkerJob }
}
