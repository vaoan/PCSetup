# Install (or replace) the YouTube cookies the Discord bridge uses on the VPS.
#
# YouTube refuses almost every request from the VPS's datacenter IP with
# "Sign in to confirm you're not a bot" (SD-015 in ../FAILURES.md). A cookies.txt
# exported from a signed-in YouTube session gets past it. When the bot starts
# answering "the YouTube cookies on the server have expired", re-export and run
# this again.
#
#   1. Sign in to YouTube in Chrome (a throwaway Google account, not your main one).
#   2. Export youtube.com with the extension "Get cookies.txt LOCALLY".
#   3. .\set-youtube-cookies.ps1 -SetSecret -DeleteSource
#
# Save the live file (the bot keeps refreshing it on the VPS) back into the secret, whole, so a
# restore gets the current session rather than the original export:
#
#   .\set-youtube-cookies.ps1 -FromVps
#
# Restore: setup-cloud.sh writes YOUTUBE_COOKIES_B64 back to the same path on a rebuilt box; on
# this PC, decode the .secrets value to a file and pass it with -Path.
#
# What it does: finds the newest *youtube.com_cookies*.txt in Downloads (or
# -Path), checks it holds a signed-in session, copies it to
# /etc/spotify-discord/youtube-cookies.txt (mode 600) over SSH, proves it with a
# real yt-dlp lookup of three videos on the box, and with -SetSecret stores it
# as the GitHub secret YOUTUBE_COOKIES_B64 so a rebuilt VPS gets it too.
# -DeleteSource removes the local export afterwards: anyone holding that file is
# signed in to that Google account.
#
# Reads RACKNERD_VPS_* and GH_PAT from the repo .secrets. Prints neither.

param(
    [string]$Path,
    [switch]$FromVps,
    [switch]$SetSecret,
    [switch]$DeleteSource
)

# Auto-elevate to Administrator (after param(), which must be the first statement;
# the bound parameters are forwarded so the elevated copy does the same thing).
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $forward = foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { "-$k" } } else { "-$k `"$v`"" }
    }
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($forward -join ' ')" -Verb RunAs
    exit
}

$ErrorActionPreference = 'Continue'
# Windows PowerShell started from a pwsh prompt inherits PS7's PSModulePath and then cannot load
# Microsoft.PowerShell.Utility (Select-String, Invoke-RestMethod). Point it at its own folders.
if ($PSVersionTable.PSVersion.Major -le 5) {
    $env:PSModulePath = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $env:SystemRoot 'system32\WindowsPowerShell\v1.0\Modules')
    ) -join ';'
}
# Text piped into ssh / gh below must arrive without a BOM. On this PC 5.1 prefixed one (seen as
# "\xEF\xBB\xBFset: command not found" on the VPS), which would also corrupt the base64 secret.
$noBom = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = $noBom
try { [Console]::InputEncoding = $noBom } catch { }
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$secretsPath = Join-Path $repoRoot '.secrets'
$remotePath = '/etc/spotify-discord/youtube-cookies.txt'
# owner/name of this checkout's origin, e.g. from https://github.com/<owner>/<name>.git
$githubRepo = ((git -C $repoRoot remote get-url origin) -replace '^.*github\.com[:/]', '' -replace '\.git$', '').Trim()

function Fail([string]$msg) {
    Write-Host "X $msg" -ForegroundColor Red
    if ($script:fetched) { Remove-Item -LiteralPath $script:fetched -Force -ErrorAction SilentlyContinue }
    exit 1
}
function Ok([string]$msg) { Write-Host "OK $msg" -ForegroundColor Green }

function Get-Secret([string]$Key, [string]$Default = $null) {
    if (-not (Test-Path $secretsPath)) { Fail ".secrets not found at $secretsPath. Run cloudflared\sync-secrets.bat first." }
    $line = Select-String -Path $secretsPath -Pattern "^$Key=" | Select-Object -First 1
    if (-not $line) { if ($null -ne $Default) { return $Default }; Fail "$Key not found in .secrets" }
    return ($line.Line -replace "^$Key=", '').Trim()
}

$ip = Get-Secret 'RACKNERD_VPS_IP'
$user = Get-Secret 'RACKNERD_VPS_USER'
$port = Get-Secret 'RACKNERD_VPS_SSH_PORT' '22'
$key = Get-Secret 'RACKNERD_VPS_SSH_KEY_PATH' (Join-Path $HOME '.ssh\libra_prod_ed25519')
if (-not (Test-Path $key)) { Fail "SSH key not found at $key (set RACKNERD_VPS_SSH_KEY_PATH in .secrets)." }
$common = @('-i', $key, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new')

function Get-RemoteSha256 {
    $line = & ssh.exe @common -p $port "$user@$ip" "sha256sum $remotePath"
    if ($LASTEXITCODE -ne 0 -or -not $line) { return $null }
    return ("$line" -split '\s+')[0].ToLower()
}

# -- 1. find the file: the live one on the VPS, or an export ------------------
$fetched = $null
if ($FromVps) {
    # The live file is the one the bot keeps refreshed; save it whole, exactly as it is on the box.
    $fetched = Join-Path ([IO.Path]::GetTempPath()) "yt-cookies-from-vps-$([guid]::NewGuid().ToString('N')).txt"
    & scp.exe @common -P $port -q "${user}@${ip}:$remotePath" $fetched
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fetched)) { Fail "could not copy $remotePath from the VPS (exit $LASTEXITCODE)" }
    $Path = $fetched
    $SetSecret = $true
}
if (-not $Path) {
    $dl = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders').'{374DE290-123F-4565-9164-39C4925E467B}'
    $dl = [Environment]::ExpandEnvironmentVariables($dl)
    $found = Get-ChildItem -LiteralPath $dl -Filter '*youtube.com_cookies*.txt' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $found) { Fail "No *youtube.com_cookies*.txt in $dl. Export one first (see the header of this script), or pass -Path." }
    $Path = $found.FullName
}
if (-not (Test-Path -LiteralPath $Path)) { Fail "Not found: $Path" }
Write-Host "Cookies file: $Path"

# -- 2. check it is a signed-in YouTube session -------------------------------
$rows = @(Get-Content -LiteralPath $Path | Where-Object { $_ -and -not $_.StartsWith('# ') -and $_ -ne '#' })
$yt = @($rows | Where-Object { ($_ -split "`t")[0] -match 'youtube\.com$' })
$names = @($yt | ForEach-Object { ($_ -split "`t")[5] })
if ($yt.Count -eq 0) { Fail 'The file has no youtube.com cookies. Export while on youtube.com.' }
$login = @('SAPISID', '__Secure-3PSID', 'LOGIN_INFO') | Where-Object { $names -contains $_ }
if (-not $login) { Fail 'The file has youtube.com cookies but no signed-in session (no SAPISID / __Secure-3PSID). Sign in first.' }
Ok "$($yt.Count) youtube.com cookies, signed in ($($login -join ', '))"

# -- 3. copy to the VPS (not with -FromVps: the file came from there) ---------
if (-not $FromVps) {
    $staging = "/root/.yt-cookies-upload-$([guid]::NewGuid().ToString('N')).txt"
    & scp.exe @common -P $port -q $Path "${user}@${ip}:$staging"
    if ($LASTEXITCODE -ne 0) { Fail "scp failed (exit $LASTEXITCODE)" }
    $install = "umask 077; mkdir -p /etc/spotify-discord && chmod 700 /etc/spotify-discord && sed -i 's/\r$//' $staging && mv -f $staging $remotePath && chmod 600 $remotePath && stat -c '%a %s' $remotePath"
    $mode = & ssh.exe @common -p $port "$user@$ip" $install
    if ($LASTEXITCODE -ne 0) { Fail "installing the file on the VPS failed (exit $LASTEXITCODE)" }
    Ok "installed on the VPS as $remotePath (mode/bytes: $mode)"
}

# -- 4. prove it: a real lookup of three videos that are blocked without cookies
$verify = @'
set -u
YT=$(command -v yt-dlp || echo /usr/local/bin/yt-dlp)
[ -x "$YT" ] || { echo "NO_YTDLP"; exit 2; }
ok=0
for id in jNQXAC9IVRw kJQP7kiw5Fk 9bZkp7q19f0; do
  tmp=$(mktemp); cp /etc/spotify-discord/youtube-cookies.txt "$tmp"
  if timeout 90 "$YT" --cookies "$tmp" --no-warnings --js-runtimes node -f bestaudio/best -g "https://www.youtube.com/watch?v=$id" </dev/null >/dev/null 2>"$tmp.err"; then
    ok=$((ok+1))
  else
    echo "  $id: $(grep -o 'ERROR.*' "$tmp.err" | cut -c1-120)"
  fi
  rm -f "$tmp" "$tmp.err"
done
echo "RESULT $ok/3"
'@
$out = ($verify -replace "`r`n", "`n") | & ssh.exe @common -p $port "$user@$ip" 'bash -s'
$out | ForEach-Object { Write-Host $_ }
$result = $out | Where-Object { $_ -match '^RESULT (\d)/3' } | Select-Object -First 1
if ($out -contains 'NO_YTDLP') { Fail 'yt-dlp is not installed on the VPS (setup-cloud.sh installs it).' }
if (-not ($result -match '^RESULT (\d)/3') -or [int]$Matches[1] -lt 2) { Fail 'The cookies did not get past YouTube from the VPS. Export again from a fresh sign-in and retry.' }
Ok "YouTube lookups from the VPS work with these cookies ($($result -replace 'RESULT ',''))"

# -- 5. GitHub secret, so a rebuilt VPS gets them -----------------------------
if ($SetSecret) {
    $token = Get-Secret 'GH_PAT'
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { Fail 'gh is not installed; cannot set the GitHub secret.' }
    # The key decides the identity: confirm it belongs to the repo owner.
    try {
        $me = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers @{ Authorization = "Bearer $token"; 'User-Agent' = 'PCSetup' }
    } catch { Fail "GH_PAT was rejected by GitHub: $($_.Exception.Message)" }
    $owner = $githubRepo.Split('/')[0]
    if ($me.login -ne $owner) { Fail "GH_PAT belongs to a different account than $owner; not setting the secret." }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $b64 = [Convert]::ToBase64String($bytes)
    # The secret must be the whole file: decode what is about to be stored and compare it with
    # the file on the VPS, byte for byte (sha256).
    $sha = [Security.Cryptography.SHA256]::Create()
    $savedHash = ([BitConverter]::ToString($sha.ComputeHash([Convert]::FromBase64String($b64))) -replace '-', '').ToLower()
    $remoteHash = Get-RemoteSha256
    if ($FromVps -and $savedHash -ne $remoteHash) { Fail "the copy differs from the file on the VPS (sha256 $savedHash vs $remoteHash); not saving it." }
    $env:GH_TOKEN = $token
    try {
        $b64 | & $gh.Source secret set YOUTUBE_COOKIES_B64 --repo $githubRepo | Out-Null
        $rc = $LASTEXITCODE
    } finally { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
    if ($rc -ne 0) { Fail "gh secret set failed (exit $rc)" }
    Ok "GitHub secret YOUTUBE_COOKIES_B64 updated on $githubRepo ($($bytes.Length) bytes, sha256 $savedHash$(if ($savedHash -eq $remoteHash) { ', identical to the VPS file' }))"
}

# The copy pulled from the VPS is a live login; it only existed to be saved.
if ($fetched) { Remove-Item -LiteralPath $fetched -Force -ErrorAction SilentlyContinue }

# -- 6. the local export is a live login; remove it ---------------------------
if ($DeleteSource -and -not $FromVps) {
    Remove-Item -LiteralPath $Path -Force
    if (Test-Path -LiteralPath $Path) { Fail "Could not delete $Path" }
    Ok "deleted the local export $Path"
}
Write-Host 'Done. The bot reads the file on every track; no restart needed.'
exit 0
