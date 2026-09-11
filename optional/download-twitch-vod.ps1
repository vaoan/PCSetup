# download-twitch-vod.ps1
# Reads a Twitch VOD link from the clipboard and downloads it (max 720p) into the
# user's Videos folder using TwitchDownloaderCLI. Launched by download-twitch-vod.bat.
#
# Optional parameters (for manual runs):
#   -Url        use this VOD link instead of the clipboard
#   -MaxHeight  highest vertical resolution to download (default 720)
#   -Ending     only download up to this timestamp, e.g. "30s" or "01:15:00"

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
$Host.UI.RawUI.WindowTitle = 'Twitch VOD download'

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "   $Text" -ForegroundColor Gray }
function Write-Warn([string]$Text) { Write-Host "   $Text" -ForegroundColor Yellow }

function Fail([string]$Message) {
    Write-Host "`nFAILED: $Message" -ForegroundColor Red
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Message, 'Twitch VOD download failed',
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

# Recreate the launcher shortcuts if they are gone (fresh PC). Start Menu one goes through cmd.exe
# like the FFXIV profile launchers so Windows offers "Pin to Start" for it. Never fatal.
function Ensure-Shortcuts {
    $bat = Join-Path $PSScriptRoot 'download-twitch-vod.bat'
    if (-not (Test-Path -LiteralPath $bat)) { return }
    $videos = [Environment]::GetFolderPath('MyVideos'); if (-not $videos) { $videos = Join-Path $env:USERPROFILE 'Videos' }
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $targets = @(
        @{ Path = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Download Twitch VOD.lnk'
           Target = $cmdExe; Args = "/c `"$bat`""; Where = 'Start Menu' },
        @{ Path = Join-Path $videos 'Download Twitch VOD.lnk'; Target = $cmdExe; Args = "/c `"$bat`""; Where = 'Videos folder' }
    )
    try {
        $ws = New-Object -ComObject WScript.Shell
        foreach ($t in $targets) {
            if (Test-Path -LiteralPath $t.Path) { continue }
            New-Item -ItemType Directory -Force -Path (Split-Path $t.Path) | Out-Null
            $s = $ws.CreateShortcut($t.Path)
            $s.TargetPath = $t.Target
            $s.Arguments = $t.Args
            $s.WorkingDirectory = $PSScriptRoot
            $s.Description = 'Downloads the Twitch VOD link in the clipboard (max 720p) into Videos'
            $s.IconLocation = '%SystemRoot%\System32\imageres.dll,175'
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
Write-Step 'Reading VOD link'
if (-not $Url) {
    try { $Url = (Get-Clipboard -Raw -ErrorAction Stop) } catch { $Url = '' }
    if ($Url) { $Url = $Url.Trim() }
}
if (-not $Url) { Fail 'The clipboard is empty. Copy a Twitch VOD link (twitch.tv/videos/...) and run this again.' }

# Accepted: twitch.tv/videos/123, m.twitch.tv/videos/123, twitch.tv/<channel>/video/123, plain numeric id
$vodId = $null
if ($Url -match '(?i)twitch\.tv/(?:videos|[^/\s]+/v(?:ideo)?)/(\d+)') { $vodId = $Matches[1] }
elseif ($Url -match '^\d{6,}$') { $vodId = $Url }
if (-not $vodId) {
    $preview = if ($Url.Length -gt 80) { $Url.Substring(0, 80) + '...' } else { $Url }
    Fail "The clipboard does not contain a Twitch VOD link.`n`nClipboard: $preview`n`nExpected something like https://www.twitch.tv/videos/123456789"
}
Write-Ok "VOD id: $vodId"

# ---------------------------------------------------------------------------
Write-Step 'Checking tools'
Ensure-Shortcuts
Ensure-Scoop
$cli    = Resolve-ScoopTool 'TwitchDownloaderCLI' 'twitchdownloader-cli'
$ffmpeg = Resolve-ScoopTool 'ffmpeg' 'ffmpeg'
Write-Ok "TwitchDownloaderCLI: $cli"
Write-Ok "ffmpeg: $ffmpeg"

# ---------------------------------------------------------------------------
Write-Step 'Fetching VOD info'
$ErrorActionPreference = 'Continue'   # a stderr warning from the CLI must not abort us here
$infoLines = & $cli info --id $vodId --format Raw --banner false 2>&1 | ForEach-Object { "$_" }
$ErrorActionPreference = 'Stop'
$jsonLine = $infoLines | Where-Object { $_ -like '{"data":{"video":{"title"*' } | Select-Object -First 1
if (-not $jsonLine) {
    $tail = ($infoLines | Select-Object -Last 8) -join "`n"
    Fail "Could not read VOD info for id $vodId. It may be deleted, sub-only, or the link is wrong.`n`n$tail"
}
$video = (ConvertFrom-Json $jsonLine).data.video
if (-not $video) { Fail "Twitch returned no video for id $vodId (deleted or private?)." }

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
            $qualities += [pscustomobject]@{ Name = $name; Height = $height; Fps = $fps }
        }
    }
}
if (-not $qualities) { Fail 'No video qualities were listed for this VOD.' }
Write-Info ("Available: " + (($qualities | ForEach-Object { $_.Name }) -join ', '))

$pick = $qualities | Where-Object { $_.Height -le $MaxHeight } | Sort-Object Height, Fps -Descending | Select-Object -First 1
if (-not $pick) { $pick = $qualities | Sort-Object Height, Fps | Select-Object -First 1 }
Write-Ok "Quality : $($pick.Name) ($($pick.Height)p, max allowed ${MaxHeight}p)"

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
$fileName = "$date $safeChannel - $safeTitle [$vodId].mp4"
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

$tempDir = Join-Path $env:TEMP 'TwitchDownloader'
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

# ---------------------------------------------------------------------------
Write-Step "Downloading $($pick.Name) with 24 parallel threads"
Write-Info 'Progress is printed below by TwitchDownloaderCLI. Closing this window cancels the download.'
Write-Host ''

$cliArgs = @(
    'videodownload',
    '--id', $vodId,
    '-o', $outPath,
    '-q', $pick.Name,
    '--threads', '24',
    '--ffmpeg-path', $ffmpeg,
    '--temp-path', $tempDir,
    '--collision', 'Overwrite',
    '--banner', 'false'
)
if ($Ending) { $cliArgs += @('-e', $Ending) }

$sw = [Diagnostics.Stopwatch]::StartNew()
& $cli @cliArgs
$cliExit = $LASTEXITCODE
$sw.Stop()

# Verify the file rather than trusting the exit code.
if (-not (Test-Path -LiteralPath $outPath) -or (Get-Item -LiteralPath $outPath).Length -lt 1MB) {
    Fail "Download did not produce a usable file (exit code $cliExit).`n`nExpected: $outPath"
}
if ($cliExit -ne 0) { Write-Warn "TwitchDownloaderCLI exited with code $cliExit but the file exists - check it plays." }

$sizeMb = [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB)
Write-Host ''
Write-Host "DONE  $fileName" -ForegroundColor Green
Write-Host ("      {0} MB in {1} at {2}" -f $sizeMb, (Format-Duration ([int]$sw.Elapsed.TotalSeconds)), $pick.Name) -ForegroundColor Green
Write-Host "      $outPath" -ForegroundColor Green

Start-Process explorer.exe -ArgumentList "/select,`"$outPath`""
for ($s = 8; $s -gt 0; $s--) {
    Write-Host -NoNewline "`r      Closing in $s s... "
    Start-Sleep -Seconds 1
}
exit 0
