# download-video.ps1
# One clipboard-driven downloader for Twitch VODs, YouTube videos and Instagram reels/posts.
# Reads the link from the clipboard, detects the site, installs only the tools that site needs
# (scoop itself included, so it works on a freshly formatted PC), downloads into the Videos
# folder (Pictures for Instagram photo posts), shows progress in the window, opens Explorer on
# the finished file, and reports failures in a message box. Launched by download-video.bat.
# Twitch/YouTube names end in a quality tag ([1080p60]); an earlier download of the same video at a
# different quality is kept and the new quality lands next to it - only an identical version is skipped.
#
#   Twitch     TwitchDownloaderCLI + ffmpeg   highest quality available, 24 threads, disk-space check first
#   YouTube    yt-dlp + deno + ffmpeg         highest quality available (h264/aac preferred at equal resolution), 16 fragment connections
#   Instagram  yt-dlp + gallery-dl + ffmpeg   best quality; needs a one-time cookie export (see below)
#
# Instagram serves almost nothing without a login and no tool can read Chrome/Edge cookies on
# current Windows, so: install the Chrome extension "Get cookies.txt LOCALLY", open instagram.com
# logged in, click Export, leave the file in Downloads. This script adopts it automatically.
#
# Optional parameters (for manual runs):
#   -Url           use this link instead of the clipboard
#   -MaxHeight     Twitch/YouTube resolution cap in pixels, e.g. 720 (default 0 = no cap, best available)
#   -Ending        test aid: only the first part - Twitch "20s", YouTube seconds like "30" (re-encodes)
#   -NoMessageBox  failures go to the console only (tests)

param(
    [string]$Url,
    [int]$MaxHeight = 0,
    [string]$Ending,
    [switch]$NoMessageBox
)

# Auto-elevate to Administrator (forwarding any parameters)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $fwd = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -MaxHeight $MaxHeight"
    if ($Url)          { $fwd += " -Url `"$Url`"" }
    if ($Ending)       { $fwd += " -Ending `"$Ending`"" }
    if ($NoMessageBox) { $fwd += " -NoMessageBox" }
    Start-Process PowerShell -ArgumentList $fwd -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = 'Download Video'

# ============================================================================ shared helpers
function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "   $Text" -ForegroundColor Gray }
function Write-Warn([string]$Text) { Write-Host "   $Text" -ForegroundColor Yellow }

function Fail([string]$Message) {
    Write-Host "`nFAILED: $Message" -ForegroundColor Red
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
#   ffmpeg (-Ending)     frame=  135 fps= 65 q=31.0 size=  256KiB time=00:00:02.46 bitrate=...
function Invoke-Streaming([scriptblock]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $redirected = try { [Console]::IsOutputRedirected } catch { $true }
    $width      = try { [Math]::Max(60, [Console]::WindowWidth) } catch { 120 }
    $barWidth   = 30
    $st = @{ Shown = $false; LastPct = -1; LastLabel = '' }

    $clearBar = {
        if ($st.Shown) { Write-Host -NoNewline ("`r" + (' ' * ($width - 1)) + "`r"); $st.Shown = $false }
    }
    $render = {
        param([string]$Label, [double]$Pct, [string]$Detail)
        if ($Pct -ge 0) {
            $filled = [int][Math]::Round($barWidth * [Math]::Min(100.0, $Pct) / 100.0)
            $text = "$Label [" + ('#' * $filled) + ('-' * ($barWidth - $filled)) + '] ' + ('{0,5:0.0}%' -f $Pct)
        } else {
            $text = "$Label ..."
        }
        if ($Detail) { $text += " $Detail" }
        if ($redirected) {
            $whole = if ($Pct -ge 0) { [int][Math]::Floor($Pct) } else { -1 }
            if ($whole -ne $st.LastPct -or $Label -ne $st.LastLabel) { Write-Host $text; $st.LastPct = $whole; $st.LastLabel = $Label }
        } else {
            if ($text.Length -gt $width - 1) { $text = $text.Substring(0, $width - 1) }
            Write-Host -NoNewline ("`r" + $text.PadRight($width - 1)) -ForegroundColor Cyan
            $st.Shown = $true
        }
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
                & $render $label $pct ''
            } elseif ($line -match '^\[download\]\s+([\d.]+)% of\s+(~?\s*[\d.]+\w+)(?:\s+in\s+([\d:]+))?(?:\s+at\s+([^\s\[]+))?(?:\s+ETA\s+([^\s\[]+))?(.*)$') {
                # Fields stop at "[" because a message is sometimes glued on with no line break.
                $pct    = [double]$Matches[1]
                $detail = "of $($Matches[2] -replace '\s', '')"
                if ($Matches[3]) { $detail += " in $($Matches[3])" }
                if ($Matches[4]) { $detail += " at $($Matches[4])" }
                if ($Matches[5]) { $detail += " ETA $($Matches[5])" }
                $rest   = $Matches[6]
                & $render 'Downloading' $pct $detail
            } elseif ($line -match '^frame=.*?time=(\S+)') {
                & $render 'Re-encoding' -1 "time $($Matches[1])"
            } else {
                & $clearBar
                Write-Host $line
            }
            if ($rest.Trim()) { & $clearBar; Write-Host $rest.Trim() }
        }
        $code = $LASTEXITCODE
        if ($st.Shown) { Write-Host '' }
        return $code
    }
    finally { $ErrorActionPreference = $prev }
}

function Show-Existing([string]$Path, [string]$Tag) {
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $Path).Length / 1MB)
    $at = if ($Tag) { " at $Tag" } else { '' }
    Write-Warn "Already downloaded$at ($sizeMb MB) - opening its folder instead."
    Start-Process explorer.exe -ArgumentList "/select,`"$Path`""
    Start-Sleep -Seconds 4
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

# Height, rounded fps and duration of a video file, or $null when ffprobe cannot read it.
function Get-VideoSpec([string]$Path, [string]$Ffprobe) {
    if (-not $Ffprobe) { return $null }
    $lines = Get-NativeOutput { & $Ffprobe -v error -select_streams v:0 -show_entries 'stream=height,r_frame_rate:format=duration' -of csv=p=0 $Path }
    $height = 0; $fps = 0.0; $seconds = 0.0
    foreach ($line in $lines) {
        if ($line -match '^(\d+),(\d+)/(\d+)\s*$') {
            $height = [int]$Matches[1]
            if ([int]$Matches[3] -ne 0) { $fps = [double]$Matches[2] / [double]$Matches[3] }
        } elseif ($line -match '^([\d.]+)\s*$') {
            $seconds = [double]$Matches[1]
        }
    }
    if ($height -le 0) { return $null }
    return [pscustomobject]@{ Height = $height; Fps = $fps; Tag = (Format-QualityTag $height $fps); Seconds = $seconds }
}

# Looks at every .mp4 in $Dir that carries [$Id] in its name. Exits through Show-Existing when the
# requested version is already there (renaming a legacy untagged file to the tagged name first);
# otherwise renames legacy files to their real quality and returns so the download proceeds.
# $ExpectedSeconds = 0 disables the length check (used for -Ending test runs).
function Resolve-ExistingVersions([string]$Dir, [string]$Id, [string]$BaseName, [string]$Tag, [int]$ExpectedSeconds, [string]$Ffprobe) {
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
    Write-Host "DONE  $(Split-Path $Path -Leaf)" -ForegroundColor Green
    if ($Summary) { Write-Host "      $Summary" -ForegroundColor Green }
    Write-Host "      $Path" -ForegroundColor Green
    Start-Process explorer.exe -ArgumentList "/select,`"$Path`""
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
            $s.Description = 'Downloads the Twitch, YouTube or Instagram link in the clipboard'
            $icon = Join-Path $PSScriptRoot 'download-video.ico'
            $s.IconLocation = if (Test-Path -LiteralPath $icon) { "$icon,0" } else { '%SystemRoot%\System32\imageres.dll,175' }
            $s.Save()
            if (Test-Path -LiteralPath $t.Path) { Write-Ok "Recreated shortcut in $($t.Where): $($t.Path)" } else { Write-Warn "Could not create shortcut: $($t.Path)" }
        }
    } catch { Write-Warn "Shortcut check skipped: $($_.Exception.Message)" }
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
    $candidates = if ($MaxHeight -gt 0) { @($qualities | Where-Object { $_.Height -le $MaxHeight }) } else { @($qualities) }
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
    Resolve-ExistingVersions -Dir $videosDir -Id $VodId -BaseName $baseName -Tag $tag -ExpectedSeconds $expected -Ffprobe (Get-FfprobePath $ffmpeg)

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
    }

    Write-Step "Downloading $($pick.Name) with 24 parallel threads"
    Write-Info 'Progress bar below. Closing this window cancels the download.'
    Write-Host ''
    $cliArgs = @('videodownload', '--id', $VodId, '-o', $outPath, '-q', $pick.Name, '--threads', '24',
                 '--ffmpeg-path', $ffmpeg, '--temp-path', $tempDir, '--collision', 'Overwrite', '--banner', 'false')
    if ($Ending) { $cliArgs += @('-e', $Ending) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $exit = Invoke-Streaming { & $cli @cliArgs }
    $sw.Stop()
    & $clearTemp

    if (-not (Test-Path -LiteralPath $outPath) -or (Get-Item -LiteralPath $outPath).Length -lt 1MB) {
        $freeNow = [Math]::Round((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($videosDir))).AvailableFreeSpace / 1GB, 1)
        Fail "Download did not produce a usable file (exit code $exit).`n`nExpected: $outPath`nFree space on the Videos drive now: $freeNow GB`n`nScroll up in the window for the CLI's error."
    }
    if ($exit -ne 0) { Write-Warn "TwitchDownloaderCLI exited with code $exit but the file exists - check it plays." }
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB)
    Finish $outPath ("{0} MB in {1} at {2}" -f $sizeMb, (Format-Duration ([int]$sw.Elapsed.TotalSeconds)), $pick.Name)
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
    # prefer h264 + aac in mp4 so the file plays in anything (AV1/VP9 do not play in the stock Windows
    # player). Resolution outranks codec, so a 1440p/4K VP9-only upload is still taken at full size.
    # yt-dlp merges separate video/audio streams with ffmpeg.
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
    Resolve-ExistingVersions -Dir $videosDir -Id $VideoId -BaseName $idBase -Tag $tag -ExpectedSeconds $expected -Ffprobe (Get-FfprobePath $ffmpeg)

    Write-Step 'Downloading with 16 parallel fragment connections'
    Write-Info 'Progress bar below. Closing this window cancels the download.'
    Write-Host ''
    # yt-dlp needs %(ext)s in the template; with --merge-output-format mp4 the result is always .mp4.
    # --force-overwrites: a file already at this exact name was judged incomplete or mis-tagged above,
    # and yt-dlp would otherwise skip the download and report success.
    $dlArgs = $common + $cookieArgs + @('--merge-output-format', 'mp4', '-N', '16', '--no-mtime', '--progress', '--force-overwrites',
                                        '-o', (Join-Path $videosDir "$baseName.%(ext)s"))
    if ($Ending) { $dlArgs += @('--download-sections', "*0-$Ending", '--force-keyframes-at-cuts') }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $exit = Invoke-Streaming { & $ytdlp @dlArgs $cleanUrl }
    $sw.Stop()

    if (-not (Test-Path -LiteralPath $outPath) -or (Get-Item -LiteralPath $outPath).Length -lt 200KB) {
        Fail "Download did not produce a usable file (exit code $exit).`n`nExpected: $outPath`n`nScroll up in the window for yt-dlp's error."
    }
    if ($exit -ne 0) { Write-Warn "yt-dlp exited with code $exit but the file exists - check it plays." }
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB)
    Finish $outPath ("{0} MB in {1} at {2}p" -f $sizeMb, (Format-Duration ([int]$sw.Elapsed.TotalSeconds)), $info.height)
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

    # Cookie sources, best first. Instagram needs a logged-in session for nearly every post.
    # Chrome and Edge cookies cannot be read by any tool on current Windows builds (Chrome locks the
    # DB while running, Edge uses app-bound encryption), so the supported way is a one-time export
    # with the "Get cookies.txt LOCALLY" extension. Its default file name is
    # "www.instagram.com_cookies.txt" in Downloads; a fresh export found there is adopted automatically.
    $cookieFile = Join-Path $env:APPDATA 'PCSetup\instagram-cookies.txt'
    $downloadsDir = $null
    try { $downloadsDir = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders').'{374DE290-123F-4565-9164-39C4925E467B}' } catch {}
    if ($downloadsDir) { $downloadsDir = [Environment]::ExpandEnvironmentVariables($downloadsDir) } else { $downloadsDir = Join-Path $env:USERPROFILE 'Downloads' }
    $exported = Get-ChildItem -LiteralPath $downloadsDir -Filter '*instagram.com_cookies*.txt' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($exported -and (-not (Test-Path -LiteralPath $cookieFile) -or $exported.LastWriteTime -gt (Get-Item -LiteralPath $cookieFile).LastWriteTime)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $cookieFile) | Out-Null
        Copy-Item -LiteralPath $exported.FullName -Destination $cookieFile -Force
        Write-Ok "Adopted new cookie export from Downloads: $($exported.Name) -> $cookieFile"
    }
    $cookieSets = @()
    if (Test-Path -LiteralPath $cookieFile) { $cookieSets += ,@{ Args = @('--cookies', $cookieFile); Name = 'cookies file' } }
    if (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles')) { $cookieSets += ,@{ Args = @('--cookies-from-browser', 'firefox'); Name = 'Firefox cookies' } }
    $cookieSets += ,@{ Args = @(); Name = 'no cookies' }
    Write-Info ("Login sources to try: " + (($cookieSets | ForEach-Object { $_.Name }) -join ', '))
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
        if (Test-Path -LiteralPath $outPath) { Show-Existing $outPath }

        Write-Step 'Downloading'
        Write-Host ''
        $dlArgs = $common + $used.Args + @('--merge-output-format', 'mp4', '-N', '8', '--no-mtime', '--progress', '-o', (Join-Path $videosDir "$baseName.%(ext)s"))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $exit = Invoke-Streaming { & $ytdlp @dlArgs $cleanUrl }
        $sw.Stop()
        if (-not (Test-Path -LiteralPath $outPath) -or (Get-Item -LiteralPath $outPath).Length -lt 50KB) {
            Fail "Download did not produce a usable file (exit code $exit).`n`nExpected: $outPath`n`nScroll up in the window for yt-dlp's error."
        }
        if ($exit -ne 0) { Write-Warn "yt-dlp exited with code $exit but the file exists - check it plays." }
        $sizeMb = [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB, 1)
        Finish $outPath ("{0} MB in {1}s" -f $sizeMb, [int]$sw.Elapsed.TotalSeconds)
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

# ============================================================================ main
Write-Step 'Reading link from clipboard'
if (-not $Url) {
    try { $Url = (Get-Clipboard -Raw -ErrorAction Stop) } catch { $Url = '' }
    if ($Url) { $Url = $Url.Trim() }
}
if (-not $Url) { Fail 'The clipboard is empty. Copy a Twitch VOD, YouTube video or Instagram reel/post link and run this again.' }

if ($Url -match '(?i)twitch\.tv/(?:videos|[^/\s]+/v(?:ideo)?)/(\d+)') {
    Write-Ok "Twitch VOD $($Matches[1])"
    Invoke-Twitch $Matches[1]
}
elseif ($Url -match '(?i)(?:youtube\.com/(?:watch\?(?:[^#\s]*&)?v=|shorts/|live/|embed/|v/)|youtu\.be/)([A-Za-z0-9_-]{11})') {
    Write-Ok "YouTube video $($Matches[1])"
    Invoke-YouTube $Matches[1]
}
elseif ($Url -match '(?i)instagram\.com/(?:[A-Za-z0-9_.]+/)?(reels?|p|tv)/([A-Za-z0-9_-]{5,})') {
    $kind = if ($Matches[1] -ieq 'p') { 'p' } else { 'reel' }
    Write-Ok "Instagram $kind $($Matches[2])"
    Invoke-Instagram $Matches[2] $kind
}
else {
    $preview = if ($Url.Length -gt 80) { $Url.Substring(0, 80) + '...' } else { $Url }
    Fail "The clipboard does not contain a link this tool understands.`n`nClipboard: $preview`n`nSupported:`n  https://www.twitch.tv/videos/123456789`n  https://www.youtube.com/watch?v=XXXXXXXXXXX  (also youtu.be, shorts, live)`n  https://www.instagram.com/reel/XXXXXXXXXXX/  (also /p/ posts)"
}
