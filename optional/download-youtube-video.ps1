# download-youtube-video.ps1
# Reads a YouTube link from the clipboard and downloads it (max 720p, h264/aac mp4) into the
# user's Videos folder using yt-dlp. Launched by download-youtube-video.bat.
# Sibling of download-twitch-vod.ps1 - same bootstrap, same shortcuts, same window feedback.
#
# Optional parameters (for manual runs):
#   -Url        use this link instead of the clipboard
#   -MaxHeight  highest vertical resolution to download (default 720)
#   -Ending     only download up to this time, e.g. "30" (seconds) or "1:30" - re-encodes, test use

param(
    [string]$Url,
    [int]$MaxHeight = 720,
    [string]$Ending
)

# Auto-elevate to Administrator (forwarding any parameters)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $fwd = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -MaxHeight $MaxHeight"
    if ($Url)    { $fwd += " -Url `"$Url`"" }
    if ($Ending) { $fwd += " -Ending `"$Ending`"" }
    Start-Process PowerShell -ArgumentList $fwd -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = 'YouTube download'

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "   $Text" -ForegroundColor Gray }
function Write-Warn([string]$Text) { Write-Host "   $Text" -ForegroundColor Yellow }

function Fail([string]$Message) {
    Write-Host "`nFAILED: $Message" -ForegroundColor Red
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Message, 'YouTube download failed',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {}
    exit 1
}

function Format-Duration([int]$Seconds) {
    $t = [TimeSpan]::FromSeconds($Seconds)
    if ($t.TotalHours -ge 1) { return ('{0}h {1:00}m {2:00}s' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds) }
    return ('{0}m {1:00}s' -f $t.Minutes, $t.Seconds)
}

$scoopDir   = Join-Path $env:USERPROFILE 'scoop'
$scoopShims = Join-Path $scoopDir 'shims'

# Run a native command / external script and echo its output (stdout AND stderr) as info lines.
# With $ErrorActionPreference = 'Stop', anything a child writes to stderr through '2>&1' becomes a
# terminating NativeCommandError - the scoop installer's progress chatter killed the script that way.
function Invoke-Native([scriptblock]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command 2>&1 | ForEach-Object { Write-Info ("$_".TrimEnd()) } }
    finally { $ErrorActionPreference = $prev }
}

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

# Recreate the launcher shortcuts if they are gone (fresh PC). Both go through cmd.exe like the
# FFXIV profile launchers so Windows offers "Pin to Start" for them. Never fatal.
function Ensure-Shortcuts {
    $bat = Join-Path $PSScriptRoot 'download-youtube-video.bat'
    if (-not (Test-Path -LiteralPath $bat)) { return }
    $videos = [Environment]::GetFolderPath('MyVideos'); if (-not $videos) { $videos = Join-Path $env:USERPROFILE 'Videos' }
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $targets = @(
        @{ Path = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Download YouTube Video.lnk'; Where = 'Start Menu' },
        @{ Path = Join-Path $videos 'Download YouTube Video.lnk'; Where = 'Videos folder' }
    )
    try {
        $ws = New-Object -ComObject WScript.Shell
        foreach ($t in $targets) {
            if (Test-Path -LiteralPath $t.Path) { continue }
            New-Item -ItemType Directory -Force -Path (Split-Path $t.Path) | Out-Null
            $s = $ws.CreateShortcut($t.Path)
            $s.TargetPath = $cmdExe
            $s.Arguments = "/c `"$bat`""
            $s.WorkingDirectory = $PSScriptRoot
            $s.Description = 'Downloads the YouTube link in the clipboard (max 720p) into Videos'
            $icon = Join-Path $PSScriptRoot 'youtube.ico'
            $s.IconLocation = if (Test-Path -LiteralPath $icon) { "$icon,0" } else { '%SystemRoot%\System32\imageres.dll,175' }
            $s.Save()
            if (Test-Path -LiteralPath $t.Path) { Write-Ok "Recreated shortcut in $($t.Where): $($t.Path)" } else { Write-Warn "Could not create shortcut: $($t.Path)" }
        }
    } catch { Write-Warn "Shortcut check skipped: $($_.Exception.Message)" }
}

# Resolve a scoop-installed command, installing it if missing (check -> act -> verify).
function Resolve-ScoopTool([string]$Command, [string]$Package) {
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $shim = Join-Path $scoopShims "$Command.exe"
    if (Test-Path -LiteralPath $shim) { return $shim }

    Write-Warn "$Command not found - installing '$Package' with scoop"
    Invoke-Native { & scoop install $Package }

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if (Test-Path -LiteralPath $shim) { return $shim }
    Fail "'$Package' did not install correctly ($Command still missing).`n`nTry running in a terminal: scoop install $Package"
}

# ---------------------------------------------------------------------------
Write-Step 'Reading YouTube link'
if (-not $Url) {
    try { $Url = (Get-Clipboard -Raw -ErrorAction Stop) } catch { $Url = '' }
    if ($Url) { $Url = $Url.Trim() }
}
if (-not $Url) { Fail 'The clipboard is empty. Copy a YouTube link and run this again.' }

# Accepted: youtube.com/watch?v=ID, youtu.be/ID, youtube.com/shorts/ID, /live/ID, /embed/ID, music.youtube.com
$videoId = $null
if ($Url -match '(?i)(?:youtube\.com/(?:watch\?(?:[^#\s]*&)?v=|shorts/|live/|embed/|v/)|youtu\.be/)([A-Za-z0-9_-]{11})') { $videoId = $Matches[1] }
if (-not $videoId) {
    $preview = if ($Url.Length -gt 80) { $Url.Substring(0, 80) + '...' } else { $Url }
    Fail "The clipboard does not contain a YouTube video link.`n`nClipboard: $preview`n`nExpected something like https://www.youtube.com/watch?v=XXXXXXXXXXX or https://youtu.be/XXXXXXXXXXX"
}
$cleanUrl = "https://www.youtube.com/watch?v=$videoId"
Write-Ok "Video id: $videoId"

# ---------------------------------------------------------------------------
Write-Step 'Checking tools'
Ensure-Shortcuts
Ensure-Scoop
$ytdlp  = Resolve-ScoopTool 'yt-dlp' 'yt-dlp'
$ffmpeg = Resolve-ScoopTool 'ffmpeg' 'ffmpeg'
$deno   = Resolve-ScoopTool 'deno'   'deno'     # JS runtime yt-dlp needs to unlock all YouTube formats
Write-Ok "yt-dlp : $ytdlp"
Write-Ok "ffmpeg : $ffmpeg"
Write-Ok "deno   : $deno"

# Best video <= MaxHeight, preferring h264 + aac in mp4 so the file plays in anything (AV1/VP9 do not
# play in the stock Windows player). yt-dlp merges separate video/audio streams with ffmpeg.
$formatSel  = 'bv*+ba/b'
$formatSort = "res:$MaxHeight,fps,vcodec:h264,acodec:m4a,ext:mp4"
$commonArgs = @('--no-playlist', '-f', $formatSel, '-S', $formatSort, '--ffmpeg-location', $ffmpeg, '--js-runtimes', "deno:$deno")

# ---------------------------------------------------------------------------
Write-Step 'Fetching video info'
$cookieArgs = @()
$infoJson = $null
$lastErr  = ''
# Try without cookies first; if YouTube demands a sign-in ("confirm you're not a bot"), retry with
# the cookies of an installed browser. Each attempt is one yt-dlp call.
foreach ($attempt in @(@(), @('--cookies-from-browser', 'firefox'), @('--cookies-from-browser', 'chrome'), @('--cookies-from-browser', 'edge'))) {
    $ErrorActionPreference = 'Continue'
    $raw = & $ytdlp @commonArgs @attempt --no-download --no-warnings --dump-single-json $cleanUrl 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = 'Stop'
    $line = $raw | Where-Object { $_ -like '{*' } | Select-Object -First 1
    if ($line) { $infoJson = $line; $cookieArgs = $attempt; break }
    $lastErr = ($raw | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1)
    if ($lastErr -notmatch 'sign in|not a bot|cookies') { break }
    if ($attempt.Count) { Write-Warn "Blocked with $($attempt[1]) cookies too" } else { Write-Warn 'YouTube asked for a sign-in - retrying with browser cookies' }
}
if (-not $infoJson) {
    Fail "Could not read the video info.`n`n$lastErr`n`nPrivate, removed, age-restricted, or YouTube is blocking downloads right now."
}
$info = ConvertFrom-Json $infoJson
if ($cookieArgs.Count) { Write-Ok "Using $($cookieArgs[1]) cookies" }

$title   = [string]$info.title
$channel = if ($info.channel) { [string]$info.channel } elseif ($info.uploader) { [string]$info.uploader } else { 'YouTube' }
$date    = if ($info.upload_date -match '^(\d{4})(\d{2})(\d{2})$') { "$($Matches[1])-$($Matches[2])-$($Matches[3])" } else { Get-Date -Format 'yyyy-MM-dd' }
$length  = [int]$info.duration
$pickDesc = "$($info.format_id) $($info.width)x$($info.height) $($info.fps)fps $($info.vcodec) + $($info.acodec)"
$sizeGuess = if ($info.filesize_approx) { [Math]::Round($info.filesize_approx / 1MB) } elseif ($info.filesize) { [Math]::Round($info.filesize / 1MB) } else { $null }

Write-Ok "Channel : $channel"
Write-Ok "Title   : $title"
Write-Ok "Uploaded: $date"
Write-Ok "Length  : $(Format-Duration $length)"
Write-Ok "Quality : $pickDesc (max allowed ${MaxHeight}p)"
if ($sizeGuess) { Write-Ok "Size    : ~$sizeGuess MB" }
if ($info.is_live) { Fail 'This is a live stream that is still running. Wait until it ends, then download the recording.' }

# ---------------------------------------------------------------------------
Write-Step 'Preparing output'
$videosDir = [Environment]::GetFolderPath('MyVideos')
if (-not $videosDir) { $videosDir = Join-Path $env:USERPROFILE 'Videos' }
New-Item -ItemType Directory -Force -Path $videosDir | Out-Null

$invalid = [IO.Path]::GetInvalidFileNameChars() -join ''
$safeTitle   = (($title   -replace "[$([regex]::Escape($invalid))]", '') -replace '\s+', ' ').Trim()
$safeChannel = (($channel -replace "[$([regex]::Escape($invalid))]", '') -replace '\s+', ' ').Trim()
if ($safeTitle.Length -gt 120) { $safeTitle = $safeTitle.Substring(0, 120).Trim() }
if (-not $safeTitle) { $safeTitle = 'untitled' }
$baseName = "$date $safeChannel - $safeTitle [$videoId]"
$fileName = "$baseName.mp4"
$outPath  = Join-Path $videosDir $fileName

Write-Ok "Folder  : $videosDir"
Write-Ok "File    : $fileName"

if (Test-Path -LiteralPath $outPath) {
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB)
    Write-Warn "Already downloaded ($sizeMb MB) - opening its folder instead."
    Start-Process explorer.exe -ArgumentList "/select,`"$outPath`""
    Start-Sleep -Seconds 4
    exit 0
}

# ---------------------------------------------------------------------------
Write-Step 'Downloading with 16 parallel fragment connections'
Write-Info 'Progress is printed below by yt-dlp. Closing this window cancels the download.'
Write-Host ''

# yt-dlp needs %(ext)s in the template; with --merge-output-format mp4 the result is always .mp4.
$template = Join-Path $videosDir "$baseName.%(ext)s"
$dlArgs = $commonArgs + $cookieArgs + @(
    '--merge-output-format', 'mp4',
    '-N', '16',
    '--no-mtime',
    '--progress',
    '-o', $template
)
if ($Ending) { $dlArgs += @('--download-sections', "*0-$Ending", '--force-keyframes-at-cuts') }

$sw = [Diagnostics.Stopwatch]::StartNew()
$ErrorActionPreference = 'Continue'
& $ytdlp @dlArgs $cleanUrl 2>&1 | ForEach-Object { "$_" }
$dlExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$sw.Stop()

# Verify the file rather than trusting the exit code.
if (-not (Test-Path -LiteralPath $outPath) -or (Get-Item -LiteralPath $outPath).Length -lt 200KB) {
    Fail "Download did not produce a usable file (exit code $dlExit).`n`nExpected: $outPath`n`nScroll up in the window for yt-dlp's error."
}
if ($dlExit -ne 0) { Write-Warn "yt-dlp exited with code $dlExit but the file exists - check it plays." }

$sizeMb = [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB)
Write-Host ''
Write-Host "DONE  $fileName" -ForegroundColor Green
Write-Host ("      {0} MB in {1} at {2}p" -f $sizeMb, (Format-Duration ([int]$sw.Elapsed.TotalSeconds)), $info.height) -ForegroundColor Green
Write-Host "      $outPath" -ForegroundColor Green

Start-Process explorer.exe -ArgumentList "/select,`"$outPath`""
for ($s = 8; $s -gt 0; $s--) {
    Write-Host -NoNewline "`r      Closing in $s s... "
    Start-Sleep -Seconds 1
}
exit 0
