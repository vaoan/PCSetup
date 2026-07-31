# Optional switch used by the full recovery flow. When set, the script restores
# the console stack but skips the final public-route verification.
param(
    [switch]$SkipVerification
)

# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($SkipVerification) { $arguments += " -SkipVerification" }
    Start-Process PowerShell -ArgumentList $arguments -Verb RunAs
    exit
}

# First-time setup for the web console on Windows.
# Run AFTER: install-all.ps1 or sync-secrets.bat plus the base Windows setup.
#
# What this does:
#   1. Creates %USERPROFILE%\Documents\Cloudflare\{sshwifty,launcher} dirs
#   2. Writes sshwifty.conf.json from .secrets (SSHWIFTY_CONF_B64)
#   3. Provisions Cloudflare tunnel 'dev-console' (creates if missing) + DNS records
#   4. Writes ~/.cloudflared/dev-config.yml with the live tunnel ID
#   5. Copies launcher scripts (console-proxy.js, console-launcher.js, start-console.ps1) from repo
#   6. Creates web-console scheduled task (SSHwifty + proxy + cloudflared at logon)
#   7. Creates UpdateWSLPortProxy scheduled task (portproxies + WSL services at logon)

$ErrorActionPreference = 'Stop'

$repoRoot         = Split-Path -Parent $PSScriptRoot
$secretsFile      = Join-Path $repoRoot '.secrets'
$accountId        = 'd34896e6a0f8b2fba5e03dec659eac50'
$cloudflareDir    = "$env:USERPROFILE\Documents\Cloudflare"
$sshwiftyDir      = "$cloudflareDir\sshwifty"
$sshwiftyKeyDir   = "$sshwiftyDir\keys"
$launcherDir      = "$cloudflareDir\launcher"
$cfDir            = "$env:USERPROFILE\.cloudflared"
$cfExe            = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$devConfigPath    = "$cfDir\dev-config.yml"
$sshwiftyConfPath = "$sshwiftyDir\sshwifty.conf.json"
$tunnelName       = 'dev-console'
$zoneName         = 'ffxiv.be'
$distro           = 'Ubuntu-24.04'
$consoleHostnames = @('console.ffxiv.be','dev.ffxiv.be','code.ffxiv.be','ttyd.ffxiv.be','tools.ffxiv.be','git.ffxiv.be')

function Write-Log { param([string]$msg) Write-Host "[setup-console] $msg" }
function Fail { param([string]$msg) Write-Host "[setup-console] ERROR: $msg" -ForegroundColor Red; exit 1 }

function Read-Secret {
    param([string]$key)
    if (-not (Test-Path $secretsFile)) { Fail ".secrets not found at $secretsFile. Run sync-secrets.bat first." }
    $line = Get-Content $secretsFile | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
    if (-not $line) { Fail "Secret '$key' not found in .secrets. Add it to GitHub Secrets and re-run sync-secrets.bat." }
    return ($line -replace "^$key=", '').Trim()
}

$script:cloudflareAccountApiToken = Read-Secret 'CLOUDFLARE_ACCOUNT_API_TOKEN'
if (-not $script:cloudflareAccountApiToken -or $script:cloudflareAccountApiToken -eq 'replace_me') {
    Fail "CLOUDFLARE_ACCOUNT_API_TOKEN is missing or placeholder in .secrets."
}
function Invoke-CloudflareApi {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET','POST','PUT','PATCH','DELETE')]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object]$Body = $null
    )

    $headers = @{ Authorization = "Bearer $script:cloudflareAccountApiToken" }
    $params = @{
        Uri     = "https://api.cloudflare.com/client/v4$Path"
        Headers = $headers
        Method  = $Method
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
        $params.ContentType = 'application/json'
    }

    $response = Invoke-RestMethod @params
    if ($null -eq $response.success -or -not $response.success) {
        $errors = if ($response.errors) { ($response.errors | ConvertTo-Json -Depth 8 -Compress) } else { 'unknown error' }
        Fail "Cloudflare API $Method $Path failed: $errors"
    }
    return $response.result
}

. (Join-Path $PSScriptRoot 'shared-cloudflare-auth.ps1')

# -- 1. Create directories ----------------------------------------------------
Write-Log "Creating directories..."
New-Item -ItemType Directory -Path $sshwiftyDir  -Force | Out-Null
New-Item -ItemType Directory -Path $launcherDir  -Force | Out-Null
New-Item -ItemType Directory -Path $cfDir        -Force | Out-Null

# -- 2. Write sshwifty.conf.json from .secrets --------------------------------
Write-Log "Writing sshwifty.conf.json..."
$sshwiftyConfB64  = Read-Secret 'SSHWIFTY_CONF_B64'
$sshwiftyConfJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($sshwiftyConfB64))
[IO.File]::WriteAllText($sshwiftyConfPath, $sshwiftyConfJson, (New-Object System.Text.UTF8Encoding $false))

function Convert-ToFileUri {
    param([Parameter(Mandatory = $true)][string]$Path)
    return 'file://' + ($Path -replace '\\', '/')
}

function Get-PresetKeyReference {
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyBase,
        [Parameter(Mandatory = $true)]
        [string]$PresetTitle
    )

    $privatePath = Join-Path $sshwiftyKeyDir $KeyBase
    if (-not (Test-Path $privatePath)) {
        Fail "Generated SSHWifty key file missing for '$PresetTitle'. Run setup-console-wsl.sh first."
    }

    return [pscustomobject]@{
        PrivateKey = Convert-ToFileUri -Path $privatePath
    }
}

function Get-WslHostFingerprint {
    param([string]$DistroName)

    $fingerprintLine = & wsl -d $DistroName --user root -- bash -lc "ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub 2>/dev/null | head -n 1" 2>$null | Select-Object -First 1
    if (-not $fingerprintLine) {
        Fail "Could not read WSL SSH host fingerprint."
    }

    $fingerprint = ($fingerprintLine -split '\s+')[1]
    if (-not $fingerprint) {
        Fail "Could not parse WSL SSH host fingerprint."
    }

    return $fingerprint
}

function Set-OrAddPreset {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$PrivateKey,
        [Parameter(Mandatory = $true)]
        [string]$Fingerprint
    )

        $preset = @($Config.Presets | Where-Object { $_.Title -eq $Title } | Select-Object -First 1)
    if ($preset) {
        $preset.Meta.'Private Key' = $PrivateKey
        $preset.Meta.Fingerprint = $Fingerprint
        return
    }

    $Config.Presets += [pscustomobject]@{
        Title = $Title
        Type  = 'SSH'
        Host  = '127.0.0.1:2222'
        Meta  = [pscustomobject]@{
            User = 'root'
            Encoding = 'utf-8'
            Authentication = 'Private Key'
            'Private Key' = $PrivateKey
            Fingerprint = $Fingerprint
        }
    }
}

$wslIp = (& wsl -d $distro --user root -- bash -lc "hostname -I | cut -d ' ' -f1" 2>$null | Out-String).Trim()
if (-not $wslIp) {
    Write-Log "Could not resolve WSL IP during setup."
    $wslSshHost = '127.0.0.1:2222'
} else {
    $wslSshHost = '127.0.0.1:2222'
    Write-Log "Resolved WSL IP: $wslIp"
    Write-Log "SSHwifty will target the local TCP relay at $wslSshHost"
}

if (Test-Path $sshwiftyKeyDir) {
    Write-Log "Synchronizing sshwifty preset keys from $sshwiftyKeyDir..."
    $sshwiftyConfig = Get-Content $sshwiftyConfPath -Raw | ConvertFrom-Json
    $sshwiftyConfig.DialTimeout = 120
    foreach ($server in @($sshwiftyConfig.Servers)) {
        $server.InitialTimeout = 120
        $server.ReadTimeout = 180
        $server.WriteTimeout = 180
    }
    $presetSpecs = @(
        @{ Title = 'WSL Terminal (Persistent)'; KeyBase = 'wsl-terminal' },
        @{ Title = 'WSL Shell (Fresh)';         KeyBase = 'wsl-shell' },
        @{ Title = 'Candystore (Persistent)'; KeyBase = 'candystore' },
        @{ Title = 'Candystore (Fresh)';      KeyBase = 'candystore-shell' },
        @{ Title = 'Eclipse-con (Persistent)'; KeyBase = 'eclipse-con' },
        @{ Title = 'Eclipse-con (Fresh)';      KeyBase = 'eclipse-con-shell' },
        @{ Title = 'Puck (Persistent)';        KeyBase = 'puck' },
        @{ Title = 'Puck (Fresh)';             KeyBase = 'puck-shell' },
        @{ Title = 'AeleOS (Persistent)';      KeyBase = 'aeleos' },
        @{ Title = 'AeleOS (Fresh)';           KeyBase = 'aeleos-shell' },
        @{ Title = 'PCSetup (Persistent)';     KeyBase = 'pcsetup' },
        @{ Title = 'PCSetup (Fresh)';          KeyBase = 'pcsetup-shell' }
    )

    $serverFingerprint = Get-WslHostFingerprint -DistroName $distro

    foreach ($spec in $presetSpecs) {
        $material = Get-PresetKeyReference -KeyBase $spec.KeyBase -PresetTitle $spec.Title
        Set-OrAddPreset -Config $sshwiftyConfig -Title $spec.Title -PrivateKey $material.PrivateKey -Fingerprint $serverFingerprint
    }

    foreach ($preset in @($sshwiftyConfig.Presets)) {
        if ($preset.Type -eq 'SSH') {
            $preset.Host = $wslSshHost
        }
    }

    [IO.File]::WriteAllText($sshwiftyConfPath, ($sshwiftyConfig | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))
    Write-Log "sshwifty presets synchronized (Candystore, Eclipse-con, Puck, AeleOS, PCSetup) -> $wslSshHost"
} else {
    Fail "Missing generated key directory: $sshwiftyKeyDir. Run setup-console-wsl.sh before setup-console-windows.ps1."
}

# -- 3. Provision Cloudflare tunnel + DNS records -----------------------------
Write-Log "Provisioning Cloudflare dev tunnel..."
if (-not (Test-Path $cfExe))   { Fail "cloudflared.exe not found at $cfExe. Run cloudflared\install-all.ps1 first." }

$tunnelId = $null

$tunnels = Invoke-CloudflareApi -Method GET -Path "/accounts/$accountId/cfd_tunnel"
$existing = @($tunnels | Where-Object { $_.name -eq $tunnelName -and -not $_.deleted_at })
if ($existing.Count -gt 0) {
    $tunnelId = $existing[0].id
    Write-Log "Tunnel ready: $tunnelName ($tunnelId)"
} else {
    Write-Log "Creating new tunnel via API..."
    $created = Invoke-CloudflareApi -Method POST -Path "/accounts/$accountId/cfd_tunnel" -Body @{ name = $tunnelName }
    $tunnelId = $created.id
    Write-Log "Tunnel created: $tunnelName ($tunnelId)"
}

$credPath = "$cfDir\$tunnelId.json"

if (-not (Test-Path $credPath)) {
    Write-Log "Creating tunnel credentials..."
    $tokenResult = Invoke-CloudflareApi -Method GET -Path "/accounts/$accountId/cfd_tunnel/$tunnelId/token"
    $tokenValue = if ($tokenResult.PSObject.Properties.Name -contains 'token') { $tokenResult.token } else { $tokenResult }
    if (-not $tokenValue) {
        Fail "Could not generate credentials token for $tunnelName."
    }
    try {
        $tokenJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($tokenValue.Trim()))
        $tokenData = $tokenJson | ConvertFrom-Json
        $credentials = @{
            AccountTag   = $tokenData.a
            TunnelSecret = $tokenData.s
            TunnelID     = $tokenData.t
        } | ConvertTo-Json
        [IO.File]::WriteAllText($credPath, $credentials, (New-Object System.Text.UTF8Encoding $false))
        Write-Log "Tunnel credentials written: $credPath"
    } catch {
        Fail "Failed to decode credentials token for $tunnelName. $_"
    }
}

try {
    Write-Log "Ensuring Cloudflare cert.pem from .secrets..."
    $null = Ensure-CloudflareCertPem -RepoRoot $repoRoot
    Write-Log "cert.pem ready"

    Write-Log "Provisioning DNS routes for dev-console..."
    Invoke-CloudflaredDnsRoute -CloudflaredPath $cfExe -TunnelName $tunnelId -Hostnames $consoleHostnames
    Write-Log "DNS routes provisioned"
} catch {
    Fail "DNS route provisioning failed: $_"
}

# -- 3b. Gate every console hostname behind Zero Trust Access -----------------
# Critical: the tunnel + DNS above would otherwise expose these hostnames with
# NO Access app in front of them (fully public). setup-access-apps.ps1 (re)creates
# the reusable email-allow + this-PC IP-bypass policies and points every app at
# them with the max session duration. Idempotent — safe to run every setup.
Write-Log "Provisioning Zero Trust Access gating (reusable policies)..."
$accessAppsScript = Join-Path $PSScriptRoot 'setup-access-apps.ps1'
if (Test-Path $accessAppsScript) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $accessAppsScript
    if ($LASTEXITCODE -ne 0) {
        Fail "Access gating provisioning failed (setup-access-apps.ps1 exited $LASTEXITCODE)."
    }
    Write-Log "Zero Trust Access gating provisioned"
} else {
    Fail "setup-access-apps.ps1 not found at $accessAppsScript"
}

# -- 4. Write dev-config.yml --------------------------------------------------
Write-Log "Writing cloudflared dev-config.yml..."
$devConfig = @"
tunnel: $tunnelId
credentials-file: $($credPath -replace '\\', '\\')
protocol: http2

ingress:
  - hostname: console.ffxiv.be
    service: http://127.0.0.1:7681
  - hostname: dev.ffxiv.be
    service: ssh://localhost:22
  - hostname: tools.ffxiv.be
    service: http://127.0.0.1:7686
  - hostname: git.ffxiv.be
    service: http://127.0.0.1:7687
  - hostname: code.ffxiv.be
    service: http://127.0.0.1:8080
  - hostname: ttyd.ffxiv.be
    service: http://127.0.0.1:7683
  - service: http_status:404
"@
[IO.File]::WriteAllText($devConfigPath, $devConfig, [Text.Encoding]::UTF8)

# -- 5. Copy launcher scripts from repo ---------------------------------------
Write-Log "Copying launcher scripts..."
Copy-Item "$PSScriptRoot\console-proxy.js"    "$launcherDir\console-proxy.js"    -Force
Copy-Item "$PSScriptRoot\console-launcher.js" "$launcherDir\console-launcher.js" -Force
# PWA assets served by console-proxy.js (SSH Console installable app)
Copy-Item "$PSScriptRoot\console-pwa-manifest.webmanifest" "$launcherDir\console-pwa-manifest.webmanifest" -Force
Copy-Item "$PSScriptRoot\console-pwa-sw.js"                "$launcherDir\console-pwa-sw.js"                -Force
Copy-Item "$PSScriptRoot\console-pwa-icon-192.png"         "$launcherDir\console-pwa-icon-192.png"         -Force
Copy-Item "$PSScriptRoot\console-pwa-icon-512.png"         "$launcherDir\console-pwa-icon-512.png"         -Force
Copy-Item "$PSScriptRoot\ssh-proxy.js"        "$cloudflareDir\ssh-proxy.js"      -Force
Copy-Item "$PSScriptRoot\tcp-relay.js"        "$cloudflareDir\tcp-relay.js"      -Force
Copy-Item "$PSScriptRoot\start-console.ps1"   "$cloudflareDir\start-console.ps1" -Force
Copy-Item "$PSScriptRoot\tunnel-supervisor.ps1" "$cloudflareDir\tunnel-supervisor.ps1" -Force

# -- 6. Download sshwifty binary if missing -----------------------------------
$sshwiftyExe = "$sshwiftyDir\sshwifty_windows_amd64.exe"
if (-not (Test-Path $sshwiftyExe)) {
    Write-Log "Downloading sshwifty binary..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $githubHeaders = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'PCSetup-cloudflared-installer'
    }
    try {
        $githubToken = Read-Secret 'GH_PAT'
        if (-not [string]::IsNullOrWhiteSpace($githubToken) -and $githubToken -ne 'replace_me') {
            $githubHeaders.Authorization = "Bearer $githubToken"
        }
    } catch {
        Write-Log "GH_PAT not available; using anonymous GitHub release lookup."
    }

    $releases  = Invoke-RestMethod -Uri 'https://api.github.com/repos/nirui/sshwifty/releases' -Headers $githubHeaders -UseBasicParsing
    $asset     = $releases[0].assets | Where-Object { $_.name -like '*windows_amd64*' } | Select-Object -First 1
    if (-not $asset) { Fail "Could not find sshwifty Windows AMD64 asset in latest release." }

    $tarPath   = [IO.Path]::GetTempFileName() + '.tar.gz'
    $extractDir= [IO.Path]::Combine([IO.Path]::GetTempPath(), [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -Headers $githubHeaders -OutFile $tarPath -UseBasicParsing
        tar -xzf $tarPath -C $extractDir
        $exeFile = Get-ChildItem -Path $extractDir -Filter '*.exe' -Recurse | Select-Object -First 1
        if (-not $exeFile) { Fail "No .exe found in sshwifty archive." }
        Move-Item $exeFile.FullName $sshwiftyExe -Force
        Write-Log "sshwifty $($releases[0].tag_name) downloaded"
    } finally {
        Remove-Item $tarPath    -Force -ErrorAction SilentlyContinue
        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Log "sshwifty binary already present"
}

# -- 7. web-console scheduled task --------------------------------------------
# Runs start-console.ps1 at logon: sets portproxies, starts WSL services,
# SSHwifty, console-proxy.js, and the cloudflared dev tunnel — all hidden.
Write-Log "Creating web-console scheduled task..."

# Remove the old CloudflaredDevTunnel task if present (replaced by web-console)
Unregister-ScheduledTask -TaskName "CloudflaredDevTunnel" -Confirm:$false -ErrorAction SilentlyContinue

$wcTaskName  = "web-console"
$wcScript    = "$cloudflareDir\start-console.ps1"
$wcAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wcScript`""
$wcTriggers  = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
    (New-ScheduledTaskTrigger -AtStartup)   # also fires on resume from sleep
)
$wcSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew
$wcPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

Unregister-ScheduledTask -TaskName $wcTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $wcTaskName -Action $wcAction -Trigger $wcTriggers `
    -Settings $wcSettings -Principal $wcPrincipal -Force | Out-Null
Write-Log "Scheduled task '$wcTaskName' created (runs at logon + boot/resume, hidden)"

# -- 8. UpdateWSLPortProxy scheduled task -------------------------------------
Write-Log "Creating UpdateWSLPortProxy scheduled task..."
$proxyTaskName = "UpdateWSLPortProxy"
$proxyScript = @"
`$distro = 'Ubuntu-24.04'
`$codeUser = (wsl -d `$distro --user root -- bash -lc "getent passwd 1000 | cut -d: -f1" | Out-String).Trim()
if (-not `$codeUser) { `$codeUser = 'root' }
wsl -d `$distro --user root -- bash -c "systemctl start code-server@`$codeUser ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit git-proxy 2>/dev/null || true" | Out-Null
"@
$proxyScriptPath = "$cfDir\update-wsl-portproxy.ps1"
[IO.File]::WriteAllText($proxyScriptPath, $proxyScript, [Text.Encoding]::UTF8)

$proxyAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$proxyScriptPath`""
$proxyTriggers  = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
    (New-ScheduledTaskTrigger -AtStartup)   # also fires on resume from sleep
)
$proxySettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$proxyPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

Unregister-ScheduledTask -TaskName $proxyTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $proxyTaskName -Action $proxyAction -Trigger $proxyTriggers `
    -Settings $proxySettings -Principal $proxyPrincipal -Force | Out-Null
Write-Log "Scheduled task '$proxyTaskName' created (runs at logon + boot/resume, elevated)"

# -- 9. WSLKeepAlive scheduled task -------------------------------------------
# Holds the WSL2 VM open. Without it, WSL shuts the VM down when idle -> code-server
# (code.ffxiv.be), the dashboard (tools.ffxiv.be) and the other WSL-backed
# services die, and the WSL IP can change out from under the TCP relays -> 502.
# A single `sleep infinity` session is fragile (it gets terminated and the VM then
# idles down), so the task runs a self-healing loop: if the held session is ever
# killed, it respawns within ~2s, so the VM effectively never drops.
Write-Log "Creating WSLKeepAlive scheduled task..."
$kaTaskName   = "WSLKeepAlive"
$kaScriptPath = "$cfDir\wsl-keepalive.ps1"
$kaScript     = @"
# WSL keepalive — holds the WSL2 VM open so code-server and the other WSL-backed
# console services stay up and the WSL IP stays stable. Self-healing loop.
`$distro = '$distro'
while (`$true) {
    try { & wsl.exe -d `$distro --user root -- sleep infinity } catch {}
    Start-Sleep -Seconds 2
}
"@
[IO.File]::WriteAllText($kaScriptPath, $kaScript, [Text.Encoding]::UTF8)

$kaAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$kaScriptPath`""
$kaTriggers  = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
    (New-ScheduledTaskTrigger -AtStartup)   # also fires on resume from sleep
)
$kaSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$kaPrincipal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

Unregister-ScheduledTask -TaskName $kaTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $kaTaskName -Action $kaAction -Trigger $kaTriggers `
    -Settings $kaSettings -Principal $kaPrincipal -Force | Out-Null
Start-ScheduledTask -TaskName $kaTaskName -ErrorAction SilentlyContinue
Write-Log "Scheduled task '$kaTaskName' created (self-healing loop, holds WSL VM open)"

# -- Done ----------------------------------------------------------------------
Write-Host ""
Write-Host "[setup-console] Setup complete." -ForegroundColor Green
Write-Host "  Cloudflare tunnel: $tunnelName ($tunnelId)"
Write-Host "  Hostnames: $($consoleHostnames -join ', ')"
Write-Host ""
Write-Host "  Next: run start-console.bat to launch the console."
Write-Host "  Remote: https://console.ffxiv.be"
Write-Host ""
Write-Host "  Files deployed to:"
Write-Host "    $sshwiftyDir\"
Write-Host "    $launcherDir\"
Write-Host "    $devConfigPath"

Write-Host ""
Write-Host "Launching console stack now so verification runs against a live install..." -ForegroundColor Yellow
$startConsoleScript = Join-Path $cloudflareDir "start-console.ps1"
if (Test-Path $startConsoleScript) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $startConsoleScript
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Console launch failed. Check the logs under $cloudflareDir and $launcherDir."
        exit $LASTEXITCODE
    }
} else {
    Write-Log "Console launcher missing: $startConsoleScript"
    exit 1
}

Write-Log "Giving the console stack time to settle before verification..."
Start-Sleep -Seconds 15

Write-Log "Running post-install console verification..."
$verifyConsoleScript = Join-Path $PSScriptRoot "verify-console.ps1"
if (Test-Path $verifyConsoleScript) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $verifyConsoleScript
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Console verification failed. Check the report under $env:USERPROFILE\.cloudflared\reports."
        exit $LASTEXITCODE
    }
    Write-Log "Console verification passed. Report saved under $env:USERPROFILE\.cloudflared\reports."
} else {
    Write-Log "Console verification skipped: verify-console.ps1 not found."
}

if (-not $SkipVerification) {
    $verifyScript = Join-Path $PSScriptRoot "verify-public-routes.ps1"
    if (Test-Path $verifyScript) {
        Write-Log "Running post-install public-route verification..."
        & powershell -NoProfile -ExecutionPolicy Bypass -File $verifyScript
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Verification passed. Report saved under $env:USERPROFILE\.cloudflared\reports."
        } else {
            Write-Log "Verification failed. Check the report under $env:USERPROFILE\.cloudflared\reports."
            exit $LASTEXITCODE
        }
    } else {
        Write-Log "Verification skipped: verify-public-routes.ps1 not found."
    }
}
