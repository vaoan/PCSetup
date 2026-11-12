# Shared by vps-ssh.ps1 and set-youtube-cookies.ps1 (dot-sourced, defines one function).
#
# The key lives in GitHub as RACKNERD_VPS_SSH_KEY and reaches .secrets base64-encoded. Write it
# out when the file is missing: LF endings (ssh.exe rejects CRLF as "invalid format") and an ACL
# with only the current user, or OpenSSH refuses it as "UNPROTECTED PRIVATE KEY FILE".
function Restore-VpsKey {
    param([string]$Path, [string]$B64)
    if (Test-Path $Path) { return $Path }
    if (-not $B64) { throw "SSH key not found at $Path and RACKNERD_VPS_SSH_KEY_B64 is not in .secrets. Run cloudflared\sync-secrets.bat." }
    $text = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($B64)) -replace "`r", ''
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $text.TrimEnd("`n") + "`n", [Text.Encoding]::ASCII)
    & icacls.exe $Path /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    Write-Host "Restored the VPS SSH key to $Path"
    return $Path
}
