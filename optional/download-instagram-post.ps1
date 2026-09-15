# download-instagram-post.ps1
# Reads an Instagram reel / post link from the clipboard and downloads it. Reels and videos go to
# the Videos folder (yt-dlp, best quality, h264/aac mp4); photo posts and carousels go to the
# Pictures folder (gallery-dl). Launched by download-instagram-post.bat.
# Sibling of download-youtube-video.ps1 - same bootstrap, shortcuts and window feedback.
#
# Instagram hides almost everything behind a login. On this PC only Firefox cookies are readable
# (Chrome locks its cookie DB while running, Edge uses app-bound encryption), so: log in to
# Instagram in Firefox once, OR export a cookies.txt to %APPDATA%\PCSetup\instagram-cookies.txt.
#
# Optional parameters (for manual runs):
#   -Url           use this link instead of the clipboard
#   -NoMessageBox  report failures in the console only (tests)

param(
    [string]$Url,
    [switch]$NoMessageBox
)

# Auto-elevate to Administrator (forwarding any parameters)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $fwd = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Url)          { $fwd += " -Url `"$Url`"" }
    if ($NoMessageBox) { $fwd += " -NoMessageBox" }
    Start-Process PowerShell -ArgumentList $fwd -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = 'Instagram download'

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "   $Text" -ForegroundColor Gray }
function Write-Warn([string]$Text) { Write-Host "   $Text" -ForegroundColor Yellow }

function Fail([string]$Message) {
    Write-Host "`nFAILED: $Message" -ForegroundColor Red
    if ($NoMessageBox) { exit 1 }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Message, 'Instagram download failed',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {}
    exit 1
}

$scoopDir   = Join-Path $env:USERPROFILE 'scoop'
$scoopShims = Join-Path $scoopDir 'shims'
$cookieFile = Join-Path $env:APPDATA 'PCSetup\instagram-cookies.txt'

# Run a native command / external script and echo its output (stdout AND stderr) as info lines.
# With $ErrorActionPreference = 'Stop', anything a child writes to stderr through '2>&1' becomes a
# terminating NativeCommandError - the scoop installer's progress chatter killed the script that way.
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
    $bat = Join-Path $PSScriptRoot 'download-instagram-post.bat'
    if (-not (Test-Path -LiteralPath $bat)) { return }
    $videos = [Environment]::GetFolderPath('MyVideos'); if (-not $videos) { $videos = Join-Path $env:USERPROFILE 'Videos' }
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $targets = @(
        @{ Path = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Download Instagram Post.lnk'; Where = 'Start Menu' },
        @{ Path = Join-Path $videos 'Download Instagram Post.lnk'; Where = 'Videos folder' }
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
            $s.Description = 'Downloads the Instagram reel or post link in the clipboard'
            $icon = Join-Path $PSScriptRoot 'instagram.ico'
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

function Get-SafeName([string]$Text, [int]$Max = 60) {
    $invalid = [IO.Path]::GetInvalidFileNameChars() -join ''
    $s = (($Text -replace "[$([regex]::Escape($invalid))]", '') -replace '[\r\n]+', ' ' -replace '\s+', ' ').Trim()
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max).Trim() }
    return $s
}

# ---------------------------------------------------------------------------
Write-Step 'Reading Instagram link'
if (-not $Url) {
    try { $Url = (Get-Clipboard -Raw -ErrorAction Stop) } catch { $Url = '' }
    if ($Url) { $Url = $Url.Trim() }
}
if (-not $Url) { Fail 'The clipboard is empty. Copy an Instagram reel or post link and run this again.' }

# Accepted: instagram.com/reel/CODE, /reels/CODE, /p/CODE, /tv/CODE, and instagram.com/<user>/reel/CODE
$shortcode = $null; $kind = 'reel'
if ($Url -match '(?i)instagram\.com/(?:[A-Za-z0-9_.]+/)?(reels?|p|tv)/([A-Za-z0-9_-]{5,})') {
    $kind = if ($Matches[1] -ieq 'p') { 'p' } else { 'reel' }
    $shortcode = $Matches[2]
}
if (-not $shortcode) {
    $preview = if ($Url.Length -gt 80) { $Url.Substring(0, 80) + '...' } else { $Url }
    Fail "The clipboard does not contain an Instagram reel or post link.`n`nClipboard: $preview`n`nExpected something like https://www.instagram.com/reel/XXXXXXXXXXX/ or https://www.instagram.com/p/XXXXXXXXXXX/"
}
$cleanUrl = "https://www.instagram.com/$kind/$shortcode/"
Write-Ok "Post: $shortcode ($kind)"

# ---------------------------------------------------------------------------
Write-Step 'Checking tools'
Ensure-Shortcuts
Ensure-Scoop
$ytdlp     = Resolve-ScoopTool 'yt-dlp'     'yt-dlp'
$ffmpeg    = Resolve-ScoopTool 'ffmpeg'     'ffmpeg'
$gallerydl = Resolve-ScoopTool 'gallery-dl' 'gallery-dl'
Write-Ok "yt-dlp     : $ytdlp"
Write-Ok "ffmpeg     : $ffmpeg"
Write-Ok "gallery-dl : $gallerydl"

# Cookie sources, best first. Instagram needs a logged-in session for nearly every post.
# Chrome and Edge cookies cannot be read by any tool on current Windows builds (Chrome locks the
# DB while running, Edge uses app-bound encryption), so the supported way is a one-time export
# with the "Get cookies.txt LOCALLY" extension. Its default file name is
# "www.instagram.com_cookies.txt" in Downloads; a fresh export found there is adopted automatically.
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
if (Test-Path -LiteralPath $cookieFile) { $cookieSets += ,@{ Args = @('--cookies', $cookieFile); Name = "cookies file" } }
$firefoxProfiles = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
if (Test-Path -LiteralPath $firefoxProfiles) { $cookieSets += ,@{ Args = @('--cookies-from-browser', 'firefox'); Name = 'Firefox cookies' } }
$cookieSets += ,@{ Args = @(); Name = 'no cookies' }
Write-Info ("Login sources to try: " + (($cookieSets | ForEach-Object { $_.Name }) -join ', '))

$loginHelp = "Instagram only serves this post to a logged-in account, and Chrome does not let tools read its login.`n`n" +
             "One-time setup (about a minute):`n" +
             "1. In Chrome install the extension 'Get cookies.txt LOCALLY' (open source, works offline).`n" +
             "2. Open instagram.com while logged in, click the extension icon, click Export.`n" +
             "3. Leave the file in Downloads (www.instagram.com_cookies.txt) - this tool picks it up on the next run.`n`n" +
             "The export stays valid until you log out of Instagram in Chrome. Re-export if downloads start failing again.`n" +
             "(Also works: log in to instagram.com in Firefox, whose cookies tools can read.)"

# ---------------------------------------------------------------------------
Write-Step 'Fetching post info'
$formatSel  = 'bv*+ba/b'
$formatSort = 'res,fps,vcodec:h264,acodec:m4a,ext:mp4'   # reels are small; take the best quality
$ytCommon   = @('--no-playlist', '-f', $formatSel, '-S', $formatSort, '--ffmpeg-location', $ffmpeg)

$info = $null; $usedCookies = $null; $lastErr = ''; $sawLoginWall = $false
foreach ($set in $cookieSets) {
    $raw = Get-NativeOutput { & $ytdlp @ytCommon @($set.Args) --no-download --no-warnings --dump-single-json $cleanUrl }
    $line = $raw | Where-Object { $_ -like '{*' } | Select-Object -First 1
    if ($line) { $info = ConvertFrom-Json $line; $usedCookies = $set; break }
    $lastErr = ($raw | Where-Object { $_ -match 'ERROR' } | Select-Object -Last 1)
    if ($lastErr -match 'empty media response|login|log in|cookies|not accessible|rate.?limit|403|401') { $sawLoginWall = $true }
    Write-Warn "yt-dlp with $($set.Name): $lastErr"
    if ($lastErr -match 'No video formats|no video|is not a video|image') { break }   # photo post - gallery-dl handles it
}

# ---------------------------------------------------------------------------
if ($info) {
    # ----- Video / reel path (yt-dlp) -----
    Write-Ok "Using $($usedCookies.Name)"
    $user    = if ($info.uploader) { [string]$info.uploader } elseif ($info.channel) { [string]$info.channel } else { 'instagram' }
    $caption = if ($info.description) { [string]$info.description } elseif ($info.title) { [string]$info.title } else { '' }
    $date    = if ($info.upload_date -match '^(\d{4})(\d{2})(\d{2})$') { "$($Matches[1])-$($Matches[2])-$($Matches[3])" } else { Get-Date -Format 'yyyy-MM-dd' }
    $length  = [int]$info.duration
    Write-Ok "Account : $user"
    Write-Ok "Caption : $(Get-SafeName $caption 100)"
    Write-Ok "Posted  : $date"
    if ($length) { Write-Ok "Length  : ${length}s" }
    Write-Ok "Quality : $($info.format_id) $($info.width)x$($info.height) $($info.vcodec) + $($info.acodec)"

    Write-Step 'Preparing output'
    $videosDir = [Environment]::GetFolderPath('MyVideos'); if (-not $videosDir) { $videosDir = Join-Path $env:USERPROFILE 'Videos' }
    New-Item -ItemType Directory -Force -Path $videosDir | Out-Null
    $safeCaption = Get-SafeName $caption 60
    $baseName = if ($safeCaption) { "$date $(Get-SafeName $user 40) - $safeCaption [$shortcode]" } else { "$date $(Get-SafeName $user 40) [$shortcode]" }
    $fileName = "$baseName.mp4"
    $outPath  = Join-Path $videosDir $fileName
    Write-Ok "Folder  : $videosDir"
    Write-Ok "File    : $fileName"
    if (Test-Path -LiteralPath $outPath) {
        Write-Warn "Already downloaded - opening its folder instead."
        Start-Process explorer.exe -ArgumentList "/select,`"$outPath`""
        Start-Sleep -Seconds 4
        exit 0
    }

    Write-Step 'Downloading'
    Write-Host ''
    $template = Join-Path $videosDir "$baseName.%(ext)s"
    $dlArgs = $ytCommon + $usedCookies.Args + @('--merge-output-format', 'mp4', '-N', '8', '--no-mtime', '--progress', '-o', $template)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ErrorActionPreference = 'Continue'
    & $ytdlp @dlArgs $cleanUrl 2>&1 | ForEach-Object { "$_" }
    $dlExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $sw.Stop()

    if (-not (Test-Path -LiteralPath $outPath) -or (Get-Item -LiteralPath $outPath).Length -lt 50KB) {
        Fail "Download did not produce a usable file (exit code $dlExit).`n`nExpected: $outPath`n`nScroll up in the window for yt-dlp's error."
    }
    if ($dlExit -ne 0) { Write-Warn "yt-dlp exited with code $dlExit but the file exists - check it plays." }
    $sizeMb = [Math]::Round((Get-Item -LiteralPath $outPath).Length / 1MB, 1)
    Write-Host ''
    Write-Host "DONE  $fileName" -ForegroundColor Green
    Write-Host ("      {0} MB in {1}s" -f $sizeMb, [int]$sw.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host "      $outPath" -ForegroundColor Green
    Start-Process explorer.exe -ArgumentList "/select,`"$outPath`""
}
else {
    # ----- Photo / carousel path (gallery-dl) -----
    Write-Warn 'yt-dlp found no video - trying gallery-dl (photo posts and carousels)'
    $meta = $null; $usedCookies = $null; $gdErr = ''
    foreach ($set in $cookieSets) {
        $raw = Get-NativeOutput { & $gallerydl @($set.Args) -j $cleanUrl }
        $json = ($raw | Where-Object { $_ -notmatch '^\[' }) -join "`n"
        try { $parsed = ConvertFrom-Json $json } catch { $parsed = $null }
        if ($parsed -and $parsed.Count) { $meta = $parsed; $usedCookies = $set; break }
        $gdErr = ($raw | Where-Object { $_ -match 'error' } | Select-Object -Last 1)
        if ($gdErr -match 'login|log in|cookies|401|403') { $sawLoginWall = $true }
        Write-Warn "gallery-dl with $($set.Name): $gdErr"
    }
    if (-not $meta) {
        if ($sawLoginWall) { Fail "$loginHelp`n`nLast error: $lastErr $gdErr" }
        Fail "Could not read this post.`n`nyt-dlp: $lastErr`ngallery-dl: $gdErr`n`nThe post may be private, deleted, or Instagram is blocking right now."
    }
    Write-Ok "Using $($usedCookies.Name)"
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
    $picturesDir = [Environment]::GetFolderPath('MyPictures'); if (-not $picturesDir) { $picturesDir = Join-Path $env:USERPROFILE 'Pictures' }
    New-Item -ItemType Directory -Force -Path $picturesDir | Out-Null
    $safeCaption = Get-SafeName $caption 60
    $baseName = if ($safeCaption) { "$date $(Get-SafeName $user 40) - $safeCaption [$shortcode]" } else { "$date $(Get-SafeName $user 40) [$shortcode]" }
    $tempDir = Join-Path $env:TEMP "InstagramDownload\$shortcode"
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    Write-Ok "Folder  : $picturesDir"
    Write-Ok "Name    : $baseName"

    Write-Step 'Downloading'
    Invoke-Native { & $gallerydl @($usedCookies.Args) -D $tempDir -f '{num}.{extension}' $cleanUrl }
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
    Write-Host ''
    Write-Host "DONE  $($files.Count) file(s) in $picturesDir" -ForegroundColor Green
    Start-Process explorer.exe -ArgumentList "/select,`"$($finalPaths[0])`""
}

for ($s = 8; $s -gt 0; $s--) {
    Write-Host -NoNewline "`r      Closing in $s s... "
    Start-Sleep -Seconds 1
}
exit 0
