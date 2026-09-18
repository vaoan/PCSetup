$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

# Server Core and freshly-imaged machines do not always preload the compression assemblies.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# One-line live status for long native commands (DISM, wsl --install, installers). Shared
# with the generated scripts of 2/3/6, so it lives in its own file.
. (Join-Path $PSScriptRoot 'status-line.ps1')

# Portable git/gh live here. Nothing else on the machine is assumed to exist yet.
$script:BootstrapRoot = Join-Path $env:ProgramData 'PCSetup\bootstrap'
$script:BootstrapPaths = New-Object System.Collections.Generic.List[string]

function Ensure-GetFileHashCommand {
    function global:Get-FileHash {
        [CmdletBinding(DefaultParameterSetName = 'Path')]
        param(
            [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')]
            [string[]]$Path,

            [Parameter(Mandatory, ParameterSetName = 'LiteralPath')]
            [Alias('PSPath')]
            [string[]]$LiteralPath,

            [Parameter(Mandatory, ParameterSetName = 'Stream')]
            [System.IO.Stream]$InputStream,

            [ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MD5')]
            [string]$Algorithm = 'SHA256'
        )

        if ($PSCmdlet.ParameterSetName -eq 'Stream') {
            $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
            try {
                $hash = [BitConverter]::ToString($hasher.ComputeHash($InputStream)).Replace('-', '')
                [pscustomobject]@{
                    Algorithm = $Algorithm.ToUpperInvariant()
                    Hash = $hash
                }
            }
            finally {
                if ($hasher) { $hasher.Dispose() }
            }
            return
        }

        $pathsToProcess = if ($PSCmdlet.ParameterSetName -eq 'LiteralPath') { $LiteralPath } else { $Path }
        foreach ($item in $pathsToProcess) {
            $resolved = Resolve-Path -LiteralPath $item -ErrorAction Stop
            foreach ($resolvedPath in $resolved) {
                $stream = [System.IO.File]::OpenRead($resolvedPath.ProviderPath)
                try {
                    $hasher = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
                    $hash = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '')
                    [pscustomobject]@{
                        Algorithm = $Algorithm.ToUpperInvariant()
                        Hash = $hash
                        Path = $resolvedPath.ProviderPath
                    }
                }
                finally {
                    if ($hasher) { $hasher.Dispose() }
                    $stream.Dispose()
                }
            }
        }
    }
}

function Refresh-SetupEnvironment {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $extra = @(
        "$env:USERPROFILE\scoop\shims",
        "$env:ProgramData\scoop\shims",
        "$env:ProgramData\chocolatey\bin",
        "$env:APPDATA\nvm",
        "$env:ProgramFiles\nodejs"
    )

    # Bootstrap paths go LAST on purpose: once Scoop installs the managed git/gh, its shims must
    # win over the portable copies. This function rebuilds $env:Path from scratch, so the
    # bootstrap entries have to be re-appended here or they vanish on the next refresh.
    $env:Path = ($extra + @($machinePath, $userPath) + @($script:BootstrapPaths) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique) -join ';'

    foreach ($scope in 'Machine', 'User') {
        foreach ($name in 'SCOOP', 'SCOOP_GLOBAL', 'NVM_HOME', 'NVM_SYMLINK') {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                Set-Item -Path "Env:$name" -Value $value
            }
        }
    }
}

function Set-PathEntryFirst {
    param(
        [string]$Entry,
        [ValidateSet('Machine', 'User')]
        [string]$Scope = 'Machine'
    )

    if ([string]::IsNullOrWhiteSpace($Entry)) {
        return
    }

    $current = [Environment]::GetEnvironmentVariable('Path', $Scope)
    $parts = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $normalizedEntry = $Entry.TrimEnd('\')
    $parts = @($parts | Where-Object { $_.TrimEnd('\') -ine $normalizedEntry })
    [Environment]::SetEnvironmentVariable('Path', ((@($Entry) + $parts) -join ';'), $Scope)
}

function Get-BootstrapArchitecture {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { return [pscustomobject]@{ MinGit = 'arm64';  Gh = 'arm64' } }
        'x86'   { return [pscustomobject]@{ MinGit = '32-bit'; Gh = '386' } }
        default { return [pscustomobject]@{ MinGit = '64-bit'; Gh = 'amd64' } }
    }
}

function Add-BootstrapPath {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory)) { return }
    if (-not ($script:BootstrapPaths -contains $Directory)) {
        $script:BootstrapPaths.Add($Directory)
    }
    Refresh-SetupEnvironment
}

function Install-BootstrapTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$AssetPattern,
        [string]$ExcludePattern,
        [Parameter(Mandatory = $true)][string]$BinSubPath
    )

    $target = Join-Path $script:BootstrapRoot $Name
    $exe = Join-Path (Join-Path $target $BinSubPath) "$Command.exe"

    if (Test-Path $exe) {
        Write-Host "$Name bootstrap already present, reusing..." -ForegroundColor Yellow
        Add-BootstrapPath (Split-Path $exe -Parent)
        return
    }

    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Write-Host "$Name already on PATH, no bootstrap needed..." -ForegroundColor Yellow
        return
    }

    Write-Host "Bootstrapping portable $Name from $Repo..." -ForegroundColor Cyan
    $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'PCSetup' }
    $asset = $release.assets |
        Where-Object { $_.name -like $AssetPattern } |
        Where-Object { -not $ExcludePattern -or $_.name -notlike $ExcludePattern } |
        Select-Object -First 1
    if (-not $asset) {
        throw "No asset matching '$AssetPattern' in the latest $Repo release; cannot bootstrap $Name."
    }

    $zipPath = Join-Path $env:TEMP ("pcsetup-bootstrap-{0}.zip" -f $Name)
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    # WebClient + ZipFile rather than Invoke-WebRequest + Expand-Archive: this runs before
    # anything is installed, and both of those cmdlets live in Microsoft.PowerShell.Utility /
    # .Archive, which a PS7-poisoned PSModulePath can make unloadable (the same failure this
    # script already works around with Ensure-GetFileHashCommand).
    [System.Net.WebClient]::new().DownloadFile($asset.browser_download_url, $zipPath)

    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $target)
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path $exe)) {
        $found = Get-ChildItem $target -Filter "$Command.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) {
            throw "$Name bootstrap archive ($($asset.name)) did not contain $Command.exe."
        }
        $exe = $found.FullName
    }

    Add-BootstrapPath (Split-Path $exe -Parent)
    Write-Host "$Name bootstrapped to $exe" -ForegroundColor Green
}

function Invoke-Logged {
    param(
        [string]$Name,
        [scriptblock]$Script
    )

    Write-Host "Installing/checking $Name..." -ForegroundColor Cyan
    try {
        $result = & $Script
        if ($result -contains $false) {
            return $false
        }
        return $true
    }
    catch {
        Write-Host "$Name failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

function Test-ScoopPackageInstalled {
    param([string]$Package)

    $prefix = & scoop prefix $Package 2>$null
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($prefix))
}

function Install-ScoopPackage {
    param(
        [string]$Package,
        [string[]]$Commands = @()
    )

    Refresh-SetupEnvironment
    if (Test-ScoopPackageInstalled $Package) {
        Write-Host "$Package already installed by Scoop, skipping..." -ForegroundColor Yellow
        return $true
    }

    foreach ($command in $Commands) {
        if (Get-Command $command -ErrorAction SilentlyContinue) {
            Write-Host "$Package command exists outside Scoop; installing Scoop package anyway..." -ForegroundColor Yellow
            break
        }
    }

    & scoop install $Package
    Refresh-SetupEnvironment
    return ($LASTEXITCODE -eq 0)
}

function Install-FirstAvailableScoopPackage {
    param(
        [string]$Name,
        [string[]]$Packages,
        [string[]]$Commands = @()
    )

    foreach ($command in $Commands) {
        if (Get-Command $command -ErrorAction SilentlyContinue) {
            Write-Host "$Name already available via $command, skipping..." -ForegroundColor Yellow
            return $true
        }
    }

    foreach ($package in $Packages) {
        if (Invoke-Logged $package { Install-ScoopPackage $package $Commands }) {
            return $true
        }
    }

    return $false
}

function Install-WingetPackage {
    param(
        [string]$Id,
        [string]$Name
    )

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "winget is not available; skipping $Name." -ForegroundColor Yellow
        return $false
    }

    Write-Host "Installing/checking $Name via winget..." -ForegroundColor Cyan
    & winget install --id $Id -e --accept-source-agreements --accept-package-agreements --silent
    return ($LASTEXITCODE -eq 0)
}

function Ensure-HypervisorBoot {
    Write-Host "Ensuring Windows hypervisor launch settings..." -ForegroundColor Cyan
    & bcdedit /set hypervisorlaunchtype auto | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not set hypervisorlaunchtype=auto. WSL2 may require manual boot configuration." -ForegroundColor Yellow
    }

    & bcdedit /set vsmlaunchtype auto | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not set vsmlaunchtype=auto. Continuing." -ForegroundColor Yellow
    }
}

function Test-WslDistroRegistered {
    param([string]$DistroName = 'Ubuntu-24.04')

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $false
    }

    $distros = (Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('-l', '-q')).Output -replace "`0", ''
    return ($distros -match "(?m)^\s*$([regex]::Escape($DistroName))\s*$")
}

function Register-UbuntuDistro {
    if (-not (Get-Command ubuntu2404.exe -ErrorAction SilentlyContinue)) {
        return $false
    }

    Write-Host "Registering Ubuntu-24.04 WSL distro..." -ForegroundColor Cyan
    $registration = Invoke-ProcessCapture -FilePath 'ubuntu2404.exe' -ArgumentList @('install', '--root') -Label "Registering $DistroName (ubuntu2404 install --root)"
    if ($registration.ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($registration.Output)) {
        Write-Host $registration.Output.Trim() -ForegroundColor Yellow
    }

    return (Test-WslDistroRegistered -DistroName 'Ubuntu-24.04')
}

function Install-WslDistro {
    param([string]$DistroName = 'Ubuntu-24.04')

    if (Test-WslDistroRegistered -DistroName $DistroName) {
        Write-Host "$DistroName already registered, skipping..." -ForegroundColor Yellow
        return $true
    }

    Write-Host "Installing/checking WSL distro: $DistroName" -ForegroundColor Cyan
    $distroInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install', '-d', $DistroName, '--no-launch') -Label "Installing $DistroName (wsl --install)"
    if ($distroInstall.ExitCode -eq 0 -and (Test-WslDistroRegistered -DistroName $DistroName)) {
        return $true
    }

    $distroInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install', $DistroName) -Label "Installing $DistroName (wsl --install, legacy syntax)"
    if ($distroInstall.ExitCode -eq 0 -and (Test-WslDistroRegistered -DistroName $DistroName)) {
        return $true
    }

    Write-Host "WSL CLI distro install did not finish; trying Ubuntu 24.04 via winget..." -ForegroundColor Yellow
    if ((Install-WingetPackage 'Canonical.Ubuntu.2404' 'Ubuntu 24.04 LTS') -or (Get-Command ubuntu2404.exe -ErrorAction SilentlyContinue)) {
        if (Register-UbuntuDistro) {
            return $true
        }
        Write-Host "Ubuntu 24.04 app is installed, but WSL could not register it in this boot." -ForegroundColor Yellow
        return $true
    }

    Write-Host "$DistroName is not ready. Reboot if WSL was just enabled, then rerun 0-init-prereqs.bat." -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace($distroInstall.Output)) {
        Write-Host $distroInstall.Output.Trim() -ForegroundColor Yellow
    }
    return $false
}

function Invoke-ProcessCapture {
    # Runs a native command with its output captured, and a one-line live status while it runs
    # (nothing is drawn for the first second, so quick queries like `wsl -l -q` stay silent).
    # Before this it was Start-Process -Wait with redirected output: `wsl --install` and the
    # Ubuntu registration showed nothing at all for the minutes they take.
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$Label = ''
    )

    if (-not $Label) {
        $Label = ('Running {0} {1}' -f (Split-Path -Leaf $FilePath), ($ArgumentList -join ' ')).Trim()
        if ($Label.Length -gt 48) { $Label = $Label.Substring(0, 45) + '...' }
    }
    $r = Invoke-CommandWithStatus -Label $Label -FilePath $FilePath -ArgumentList $ArgumentList
    return [pscustomobject]@{
        ExitCode = $r.ExitCode
        Output   = "$($r.Output)`n$($r.Error)"
    }
}

function Set-DarkMode {
    # Turns Windows dark mode on for the current user without the Settings app.
    #
    # Unactivated Windows greys out Settings > Personalization, but the page only ever writes
    # two registry values, and nothing stops a script from writing them. The shipped dark.theme
    # is applied first through the Theme Manager COM API (the engine behind the Settings page
    # and behind double-clicking a .theme file), which repaints the desktop instantly - taskbar,
    # Start, Explorer, accent and wallpaper - and then the two values are written and re-read
    # explicitly, so a session with no desktop (PowerShell Direct, a service) still ends up dark
    # even when the theme engine could not run.
    #
    # Not `Start-Process dark.theme` / `rundll32 themecpl.dll,OpenThemeAction`: on this build
    # (26200, themecpl 26100.8117) that handler exits 0 after ~100 ms without applying anything,
    # from an elevated shell, from Explorer and from a scheduled task alike. The COM call is what
    # it was supposed to do, and it needs no Settings window closed afterwards.
    #
    # Check -> act -> verify: skipped entirely when both values already say dark, because
    # dark.theme carries its own wallpaper and re-applying it on an already-dark machine would
    # replace whatever the user picked since. Returns $true when dark mode is on afterwards.
    $personalizePath = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $themesPath = 'Software\Microsoft\Windows\CurrentVersion\Themes'
    $themeFile = Join-Path $env:SystemRoot 'Resources\Themes\dark.theme'
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser

    function Get-DarkModeState {
        $k = $hkcu.OpenSubKey($personalizePath)
        if (-not $k) { return @{ Apps = $null; System = $null } }
        try {
            return @{
                Apps   = $k.GetValue('AppsUseLightTheme', $null)
                System = $k.GetValue('SystemUsesLightTheme', $null)
            }
        }
        finally { $k.Close() }
    }

    $state = Get-DarkModeState
    if ($state.Apps -eq 0 -and $state.System -eq 0) {
        Write-Host "Dark mode already on, skipping (theme file left alone)." -ForegroundColor Yellow
        return $true
    }

    # Policies that lock the Personalization pages independently of activation. None exist on a
    # fresh install; if one does, it is removed so the pages are as unlocked as the registry can
    # make them. The activation lock itself is not a registry setting and is not touched.
    $policyLocks = @(
        @{ Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop'; Value = 'NoChangingWallPaper' },
        @{ Hive = 'HKLM'; Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop'; Value = 'NoChangingWallPaper' },
        @{ Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\System';        Value = 'NoDispBackgroundPage' },
        @{ Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\System';        Value = 'NoDispAppearancePage' },
        @{ Hive = 'HKCU'; Key = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';      Value = 'NoThemesTab' },
        @{ Hive = 'HKCU'; Key = 'Software\Policies\Microsoft\Windows\Personalization';               Value = 'NoChangingColor' },
        @{ Hive = 'HKLM'; Key = 'Software\Policies\Microsoft\Windows\Personalization';               Value = 'NoChangingColor' }
    )
    foreach ($lock in $policyLocks) {
        $root = if ($lock.Hive -eq 'HKLM') { [Microsoft.Win32.Registry]::LocalMachine } else { $hkcu }
        $k = $root.OpenSubKey($lock.Key, $true)
        if (-not $k) { continue }
        try {
            if ($null -ne $k.GetValue($lock.Value, $null)) {
                $k.DeleteValue($lock.Value, $false)
                Write-Host "Removed personalization lock $($lock.Hive)\$($lock.Key)\$($lock.Value)" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Could not remove $($lock.Hive)\$($lock.Key)\$($lock.Value): $($_.Exception.Message)" -ForegroundColor Yellow
        }
        finally { $k.Close() }
    }

    # IThemeManager2 ({C1E8C83E-...}) on the "Windows Theme Manager 2 API" coclass in themeui.dll.
    # Undocumented; the vtable below is the layout ThemeTool/SecureUxTheme use, and every slot
    # before AddAndSelectTheme must stay in place for the call to land on the right method.
    # Verified on 26200: Init and GetThemeCount return 0 with a sane count, AddAndSelectTheme
    # switches CurrentTheme and the wallpaper within ~300 ms.
    if (-not ('PCSetup.ThemeManager' -as [type])) {
        Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PCSetup {
    [ComImport, Guid("C1E8C83E-845D-4D95-81DB-E283FDFFC000"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IThemeManager2 {
        [PreserveSig] int Init(int flags);
        [PreserveSig] int InitAsync(IntPtr hwnd, int unk);
        [PreserveSig] int Refresh();
        [PreserveSig] int RefreshAsync(IntPtr hwnd, int unk);
        [PreserveSig] int RefreshComplete();
        [PreserveSig] int GetThemeCount(out int count);
        [PreserveSig] int GetTheme(int index, [MarshalAs(UnmanagedType.IUnknown)] out object theme);
        [PreserveSig] int IsThemeDisabled(int index, out int disabled);
        [PreserveSig] int GetCurrentTheme(out int index);
        [PreserveSig] int SetCurrentTheme(IntPtr hwnd, int index, int applyNow, int applyFlags, int packFlags);
        [PreserveSig] int GetCustomTheme(out int index);
        [PreserveSig] int GetDefaultTheme(out int index);
        [PreserveSig] int CreateThemePack(IntPtr hwnd, [MarshalAs(UnmanagedType.LPWStr)] string path, int packFlags);
        [PreserveSig] int CloneAndSetCurrentTheme(IntPtr hwnd, [MarshalAs(UnmanagedType.LPWStr)] string path, [MarshalAs(UnmanagedType.LPWStr)] out string newPath);
        [PreserveSig] int InstallThemePack(IntPtr hwnd, [MarshalAs(UnmanagedType.LPWStr)] string path, int unk, int packFlags, [MarshalAs(UnmanagedType.LPWStr)] out string newPath, [MarshalAs(UnmanagedType.IUnknown)] out object theme);
        [PreserveSig] int DeleteTheme([MarshalAs(UnmanagedType.LPWStr)] string path);
        [PreserveSig] int OpenTheme(IntPtr hwnd, [MarshalAs(UnmanagedType.LPWStr)] string path, int packFlags);
        [PreserveSig] int AddAndSelectTheme(IntPtr hwnd, [MarshalAs(UnmanagedType.LPWStr)] string path, int applyFlags, int packFlags);
    }
    [ComImport, Guid("9324DA94-50EC-4A14-A770-E90CA03E7C8F")]
    public class ThemeManagerClass {}
    public static class ThemeManager {
        // Returns the HRESULT; 0 means the theme engine accepted and applied the file.
        public static int ApplyThemeFile(string path) {
            IThemeManager2 m = (IThemeManager2)new ThemeManagerClass();
            int hr = m.Init(0);
            if (hr != 0) return hr;
            return m.AddAndSelectTheme(IntPtr.Zero, path, 0, 0);
        }
        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    }
}
'@
    }

    # Act 1: apply the theme file. Verified by reading CurrentTheme back, not by the HRESULT.
    if (Test-Path -LiteralPath $themeFile) {
        Write-Host "Applying $themeFile..." -ForegroundColor Cyan
        try {
            $hr = [PCSetup.ThemeManager]::ApplyThemeFile($themeFile)
            if ($hr -ne 0) {
                Write-Host ("Theme engine refused the file (HRESULT 0x{0:X8}); falling back to the registry values." -f $hr) -ForegroundColor Yellow
            }
            $applied = $false
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while ([DateTime]::UtcNow -lt $deadline) {
                $current = ''
                $k = $hkcu.OpenSubKey($themesPath)
                if ($k) {
                    try { $current = [string]$k.GetValue('CurrentTheme', '') } finally { $k.Close() }
                }
                $state = Get-DarkModeState
                if ($current -and $current -ieq $themeFile -and $state.Apps -eq 0 -and $state.System -eq 0) {
                    $applied = $true
                    break
                }
                Start-Sleep -Milliseconds 250
            }
            if ($applied) {
                Write-Host "Theme applied; desktop switched to dark." -ForegroundColor Green
            }
            elseif ($hr -eq 0) {
                Write-Host "Theme engine returned OK but CurrentTheme did not change within 10s; falling back to the registry values." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "Theme engine unavailable ($($_.Exception.Message)); falling back to the registry values." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "$themeFile not found; setting dark mode through the registry only." -ForegroundColor Yellow
    }

    # Act 2: write the two values the Settings page would have written. Harmless when the theme
    # already did it; decisive when it could not run.
    $k = $hkcu.CreateSubKey($personalizePath)
    if (-not $k) { throw "CreateSubKey returned null for HKCU\$personalizePath" }
    try {
        $k.SetValue('AppsUseLightTheme', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.SetValue('SystemUsesLightTheme', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
    }
    finally { $k.Close() }

    # Tell running apps the colour set changed (this is what Settings broadcasts); without it the
    # taskbar and open Explorer windows keep their old colours until they restart.
    try {
        $result = [UIntPtr]::Zero
        [void][PCSetup.ThemeManager]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'ImmersiveColorSet', 2, 5000, [ref]$result)
    }
    catch {
        Write-Host "WM_SETTINGCHANGE broadcast failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Verify by reading back, not by trusting the calls above.
    $state = Get-DarkModeState
    if ($state.Apps -eq 0 -and $state.System -eq 0) {
        Write-Host "Dark mode on: AppsUseLightTheme=0, SystemUsesLightTheme=0." -ForegroundColor Green
        return $true
    }
    Write-Host "Dark mode NOT on after writing: AppsUseLightTheme=$($state.Apps), SystemUsesLightTheme=$($state.System)." -ForegroundColor Red
    return $false
}

function Set-DeliveryOptimizationHttpOnly {
    # Delivery Optimization download mode 0 = plain HTTP from Microsoft, no peer lookup. Every
    # store-backed download in this setup goes through DO (the Ubuntu distro from wsl --install,
    # msstore winget packages such as the NVIDIA App, Windows Update payloads), and in "LAN"
    # mode DO first looks for peers - on a NAT VM or a home network that finds nothing and only
    # delays the start of each download. The policy value outranks the Settings toggle, is
    # machine-wide, and is simply "no peer sharing" - fine to leave on a personal PC.
    # Check -> act -> verify (read back); DoSvc is restarted so it picks the policy up now.
    $keyPath = 'SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    $hklm = [Microsoft.Win32.Registry]::LocalMachine
    $read = {
        $k = $hklm.OpenSubKey($keyPath)
        if (-not $k) { return $null }
        try { return $k.GetValue('DODownloadMode', $null) } finally { $k.Close() }
    }
    if ((& $read) -eq 0) {
        Write-Host "Delivery Optimization already HTTP-only (DODownloadMode=0), skipping..." -ForegroundColor Yellow
        return $true
    }
    $k = $hklm.CreateSubKey($keyPath)
    if (-not $k) { throw "CreateSubKey returned null for HKLM\$keyPath" }
    try { $k.SetValue('DODownloadMode', 0, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $k.Close() }
    if ((& $read) -ne 0) {
        Write-Host "DODownloadMode did not read back as 0." -ForegroundColor Red
        return $false
    }
    $svc = Get-Service -Name DoSvc -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        try { Restart-Service -Name DoSvc -Force -ErrorAction Stop } catch { Write-Host "DoSvc restart skipped: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    $effective = try { (Get-DOConfig -ErrorAction Stop).DownloadMode } catch { 'n/a' }
    Write-Host "Delivery Optimization set to HTTP-only (DODownloadMode=0, effective mode: $effective)." -ForegroundColor Green
    return $true
}

function Test-WindowsFeatureEnabled {
    param([string]$FeatureName)

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
    return ($feature -and $feature.State -eq 'Enabled')
}

function Find-FeaturePayloadSource {
    # Windows install media (the ISO still attached to a VM, the USB stick still in a fresh PC)
    # carries feature payloads under sources\sxs. Pointing DISM at it with /Source /LimitAccess
    # skips Windows Update entirely: .NET 3.5 enables in well under a minute instead of queueing
    # behind the first-boot update scan and a 68 MB Delivery Optimization download. Returns the
    # sxs folder holding a file matching $Pattern, or '' when no media is present.
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [string[]]$Roots = @()
    )
    if (-not $Roots) {
        $Roots = @([IO.DriveInfo]::GetDrives() |
            Where-Object { $_.IsReady -and @('CDRom', 'Removable', 'Fixed') -contains "$($_.DriveType)" } |
            ForEach-Object { $_.RootDirectory.FullName })
    }
    foreach ($root in $Roots) {
        # Test-Path on a drive letter that does not exist (or a card reader with no card) is an
        # error, and under $ErrorActionPreference = 'Stop' it would abort the whole scan.
        try {
            # [IO.Path]::Combine, not Join-Path: Join-Path validates the drive and throws on a
            # letter that is not mounted right now.
            $sxs = [IO.Path]::Combine($root, 'sources\sxs')
            if (-not (Test-Path -LiteralPath $sxs -ErrorAction SilentlyContinue)) { continue }
            $hit = Get-ChildItem -LiteralPath $sxs -Filter $Pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $sxs }
        }
        catch { }
    }
    return ''
}

function Start-WindowsFeatureEnable {
    # Kicks off `dism /Enable-Feature` in the background and returns a handle for
    # Enable-WindowsFeature -Started, or $null when the feature is already on. The setup keeps
    # installing while DISM waits in the Windows Update queue; nothing here needs .NET 3.5, so
    # the only hard constraint is that the job is collected before the next DISM call (two
    # CBS operations cannot run at once), which is what the WSL section does.
    param(
        [Parameter(Mandatory)][string]$FeatureName,
        [string]$DisplayName = $FeatureName,
        [string]$Source = ''
    )
    if (Test-WindowsFeatureEnabled $FeatureName) {
        Write-Host "$DisplayName already enabled, skipping..." -ForegroundColor Yellow
        return $null
    }
    $extra = if ($Source) { @("/Source:$Source", '/LimitAccess') } else { @() }
    $how = if ($Source) { "from $Source" } else { 'through Windows Update' }
    Write-Host "Enabling Windows feature: $DisplayName ($FeatureName) in the background, $how - the rest of the setup continues meanwhile." -ForegroundColor Cyan
    $job = Start-CommandCapture -Label ("Enabling $DisplayName" + $(if ($Source) { ' from media' } else { '' })) -FilePath 'dism.exe' `
        -ArgumentList (@('/Online', '/Enable-Feature', "/FeatureName:$FeatureName", '/All', '/NoRestart') + $extra) `
        -WatchProcess @('TiWorker', 'TrustedInstaller') `
        -WatchService @('wuauserv', 'DoSvc', 'BITS', 'TrustedInstaller') `
        -ActivityLog (Join-Path $env:SystemRoot 'Logs\DISM\dism.log') `
        -GrowthLog (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log')
    return @{ Job = $job; Extra = $extra; Source = $Source }
}

function Enable-WindowsFeature {
    # Check -> act (with a live status line) -> verify. Returns 'AlreadyEnabled', 'Enabled',
    # 'RebootRequired' or 'Failed'; the caller decides how bad 'Failed' is. With -Source the
    # first attempt reads the payload from install media (/LimitAccess: never Windows Update);
    # if that attempt does not verify - wrong build on the media, unreadable drive - the same
    # enable is retried the normal way through Windows Update before reporting a failure.
    # With -Started (from Start-WindowsFeatureEnable) the first attempt is the job already
    # running: the status line attaches to it if it is still going, otherwise its result is
    # just read. $null for -Started means "nothing was started" and the normal path runs.
    param(
        [Parameter(Mandatory)][string]$FeatureName,
        [string]$DisplayName = $FeatureName,
        [string]$Source = '',
        [hashtable]$Started = $null
    )
    $attempts = @()
    if ($Started) {
        $attempts += @{ Label = $Started.Job.Label; Extra = $Started.Extra; Job = $Started.Job }
        if ($Started.Extra.Count -gt 0) { $attempts += @{ Label = "Enabling $DisplayName"; Extra = @(); Job = $null } }
    }
    else {
        if (Test-WindowsFeatureEnabled $FeatureName) {
            Write-Host "$DisplayName already enabled, skipping..." -ForegroundColor Yellow
            return 'AlreadyEnabled'
        }
        Write-Host "Enabling Windows feature: $DisplayName ($FeatureName)" -ForegroundColor Cyan
        if ($Source) { $attempts += @{ Label = "Enabling $DisplayName from media"; Extra = @("/Source:$Source", '/LimitAccess'); Job = $null } }
        $attempts += @{ Label = "Enabling $DisplayName"; Extra = @(); Job = $null }
    }
    foreach ($attempt in $attempts) {
        if ($attempt.Job) {
            $sinceStart = '{0:0}s' -f $attempt.Job.Clock.Elapsed.TotalSeconds
            if (Test-CommandCaptureRunning -Job $attempt.Job) {
                Write-Host "$DisplayName is still enabling in the background (running for $sinceStart); waiting for it..." -ForegroundColor Cyan
            }
            else {
                Write-Host "$DisplayName finished enabling in the background ($sinceStart); checking the result..." -ForegroundColor Cyan
            }
            $r = Wait-CommandWithStatus -Job $attempt.Job
        }
        else {
            if ($attempt.Extra.Count -gt 0) {
                Write-Host "  payload source: $Source (Windows Update not contacted)" -ForegroundColor Cyan
            }
            $status = @{
                Label        = $attempt.Label
                FilePath     = 'dism.exe'
                ArgumentList = @('/Online', '/Enable-Feature', "/FeatureName:$FeatureName", '/All', '/NoRestart') + $attempt.Extra
                WatchProcess = @('TiWorker', 'TrustedInstaller')
                WatchService = @('wuauserv', 'DoSvc', 'BITS', 'TrustedInstaller')
                ActivityLog  = (Join-Path $env:SystemRoot 'Logs\DISM\dism.log')
                GrowthLog    = (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log')
            }
            $r = Invoke-CommandWithStatus @status
        }
        $elapsed = '{0:0}s' -f $r.Elapsed.TotalSeconds
        if (Test-WindowsFeatureEnabled $FeatureName) {
            Write-Host "$DisplayName enabled (verified, $elapsed)." -ForegroundColor Green
            return 'Enabled'
        }
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue).State
        if ($r.ExitCode -eq 3010 -or "$state" -match 'Pending') {
            Write-Host "$DisplayName enabled, reboot required (state: $state, $elapsed)." -ForegroundColor Yellow
            return 'RebootRequired'
        }
        $lastLine = ($r.Output -split "`r?`n" | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*\[' } | Select-Object -Last 1)
        if ($attempt.Extra.Count -gt 0) {
            Write-Host "  media source did not work (dism exit $($r.ExitCode), $elapsed): $lastLine - retrying through Windows Update." -ForegroundColor Yellow
            continue
        }
        Write-Host "$DisplayName NOT enabled: dism exit $($r.ExitCode), state '$state', $elapsed. $lastLine $($r.Error)".Trim() -ForegroundColor Red
        return 'Failed'
    }
}

function Enable-WslPrerequisites {
    param([string]$DistroName = 'Ubuntu-24.04')

    Write-Host "Checking WSL prerequisites for Cloudflare console routes..." -ForegroundColor Cyan
    $requiresReboot = $false

    foreach ($featureName in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'HypervisorPlatform', 'Microsoft-Hyper-V-All')) {
        $result = Enable-WindowsFeature -FeatureName $featureName
        if ($result -eq 'AlreadyEnabled') { continue }
        if ($result -eq 'Failed') {
            Write-Host "Failed to enable $featureName. Enable it manually, reboot, then rerun 0-init-prereqs.bat." -ForegroundColor Yellow
            continue
        }

        $requiresReboot = $true
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Host "wsl.exe is not available yet. Reboot Windows, then rerun 0-init-prereqs.bat." -ForegroundColor Yellow
        return
    }

    $wslStatus = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--status')
    if ($wslStatus.Output -match 'not installed') {
        Install-WingetPackage 'Microsoft.WSL' 'Windows Subsystem for Linux' | Out-Null
        Ensure-HypervisorBoot

        Write-Host "Installing WSL platform files..." -ForegroundColor Cyan
        $wslInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install', '--no-distribution') -Label 'Installing WSL (wsl --install --no-distribution)'
        if ($wslInstall.ExitCode -ne 0) {
            Write-Host "WSL --no-distribution install did not finish; trying default WSL install..." -ForegroundColor Yellow
            $wslInstall = Invoke-ProcessCapture -FilePath 'wsl.exe' -ArgumentList @('--install') -Label 'Installing WSL (wsl --install)'
            if ($wslInstall.ExitCode -ne 0) {
                Write-Host "WSL platform install did not finish. Reboot Windows, then run: wsl --install" -ForegroundColor Yellow
                if (-not [string]::IsNullOrWhiteSpace($wslInstall.Output)) {
                    Write-Host $wslInstall.Output.Trim() -ForegroundColor Yellow
                }
            }
        }
        $requiresReboot = $true
    }

    if ($wslStatus.Output -match 'virtualization is not enabled|Virtual Machine Platform') {
        Ensure-HypervisorBoot
        Write-Host "WSL2 is installed but cannot start in this boot. Reboot Windows, then rerun 0-init-prereqs.bat." -ForegroundColor Yellow
        $requiresReboot = $true
    }

    if ($requiresReboot) {
        Write-Host "WSL prerequisites were changed. Reboot Windows before installing the Cloudflare console stack." -ForegroundColor Yellow
        return
    }

    if (-not (Test-WslDistroRegistered -DistroName $DistroName)) {
        Install-WslDistro -DistroName $DistroName | Out-Null
    }
}

$script:Failures = New-Object System.Collections.Generic.List[string]

Write-Host "Starting PCSetup prerequisite initialization..." -ForegroundColor Cyan
Ensure-GetFileHashCommand

# Dark mode first, before anything downloads: it is instant and the rest of the run then
# happens on a dark desktop. Not a throw - a cosmetic failure must not stop the toolchain,
# but it is recorded and the script exits 1 at the end so run-all reports it.
if ($env:PCSETUP_CI -eq '1') {
    Write-Host "SKIP: CI mode - skipping dark mode (Server Core has no theme engine or desktop)." -ForegroundColor Yellow
}
elseif (-not (Invoke-Logged 'Dark mode' { Set-DarkMode })) {
    $script:Failures.Add('Dark mode could not be turned on (see above)')
}

# Before the first download: stop Delivery Optimization from hunting for peers ahead of every
# store-backed download. Tuning, not a prerequisite - a machine that refuses the policy write
# gets a warning, not a failed step 0.
if ($env:PCSETUP_CI -eq '1') {
    Write-Host "SKIP: CI mode - skipping Delivery Optimization tuning (no DoSvc on Server Core)." -ForegroundColor Yellow
}
elseif (-not (Invoke-Logged 'Delivery Optimization' { Set-DeliveryOptimizationHttpOnly })) {
    Write-Host "Delivery Optimization could not be set to HTTP-only; continuing (downloads may start slower)." -ForegroundColor Yellow
}

# .NET Framework 3.5 starts NOW, in the background, and is collected just before the WSL
# features (the next DISM call). On a fresh install DISM has no local payload and waits in the
# Windows Update queue for minutes - that wait now overlaps with everything installed below
# instead of blocking it. Install media still attached (VM ISO, USB stick) carries the payload
# and is used when present, which makes it seconds instead. Nothing in this setup needs 3.5;
# it stays a warning when it cannot be enabled.
$netfxSource = ''
$netfxPending = $null
try {
    $netfxSource = Find-FeaturePayloadSource -Pattern '*netfx3*.cab'
    if ($netfxSource) {
        Write-Host "Install media found at $netfxSource - .NET Framework 3.5 will be enabled from it." -ForegroundColor Cyan
    }
    else {
        Write-Host "No install media with sources\sxs found; .NET Framework 3.5 comes from Windows Update in the background (attach the Windows ISO/USB to make it instant)." -ForegroundColor Yellow
    }
    $netfxPending = Start-WindowsFeatureEnable -FeatureName 'NetFx3' -DisplayName '.NET Framework 3.5' -Source $netfxSource
}
catch {
    Write-Host ".NET Framework 3.5 could not be started in the background ($($_.Exception.Message)); it will be enabled in the foreground later." -ForegroundColor Yellow
}
Set-PathEntryFirst "$env:USERPROFILE\scoop\shims" 'Machine'
Set-PathEntryFirst "$env:ProgramData\scoop\shims" 'Machine'
Refresh-SetupEnvironment

# ─────────────────────────────────────────────
# Git and GitHub CLI first, from portable zips, before any package manager exists.
#
# Scoop cannot function without git: "scoop update" and every "scoop bucket add" are git
# operations. The previous order ran "scoop update" and only then installed git *through Scoop*,
# so on a machine without git the run died at "Scoop update failed" before ever reaching the line
# that would have fixed it. Bootstrapping from the official release zips needs nothing but a
# network connection - no Chocolatey, no Scoop, no MSI, no admin-only installer.
#
# Scoop still installs its own managed git/gh further down; those shims take precedence because
# bootstrap paths are appended last in Refresh-SetupEnvironment.
# ─────────────────────────────────────────────
$bootstrapArch = Get-BootstrapArchitecture
Install-BootstrapTool -Name 'git' -Command 'git' -Repo 'git-for-windows/git' `
    -AssetPattern "MinGit-*-$($bootstrapArch.MinGit).zip" -ExcludePattern '*busybox*' -BinSubPath 'cmd'
Install-BootstrapTool -Name 'gh' -Command 'gh' -Repo 'cli/cli' `
    -AssetPattern "gh_*_windows_$($bootstrapArch.Gh).zip" -BinSubPath 'bin'

foreach ($required in 'git', 'gh') {
    if (-not (Get-Command $required -ErrorAction SilentlyContinue)) {
        throw "$required is not available after bootstrap; Scoop bucket operations would fail."
    }
}

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey bootstrap..." -ForegroundColor Cyan
    try {
        $chocoInstallScript = (Invoke-WebRequest -Uri 'https://community.chocolatey.org/install.ps1' -UseBasicParsing -TimeoutSec 120).Content
        Invoke-Expression $chocoInstallScript
    }
    catch {
        throw "Chocolatey bootstrap failed: $($_.Exception.Message)"
    }

    Refresh-SetupEnvironment
}
else {
    Write-Host "Chocolatey already installed, skipping bootstrap..." -ForegroundColor Yellow
}

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    throw 'Chocolatey is not available after installation.'
}

if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Scoop..." -ForegroundColor Cyan
    $installer = Join-Path $env:TEMP 'scoop-install.ps1'
    Invoke-WebRequest -Uri 'https://get.scoop.sh' -OutFile $installer -UseBasicParsing
    & powershell -NoProfile -ExecutionPolicy Bypass -File $installer -RunAsAdmin
    Refresh-SetupEnvironment
}

if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    throw 'Scoop is not available after installation.'
}

$null = & scoop config aria2-enabled false
Write-Host "Updating Scoop..." -ForegroundColor Cyan
& scoop update
if ($LASTEXITCODE -ne 0) {
    throw 'Scoop update failed.'
}

if (-not (Invoke-Logged 'Git' { Install-ScoopPackage 'git' @('git') })) { throw 'Git Scoop install failed.' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is not available after Scoop install.'
}

foreach ($bucket in 'extras', 'versions', 'java', 'nerd-fonts') {
    $buckets = & scoop bucket list 2>$null | Out-String
    if ($buckets -notmatch "(?m)^\s*$bucket\s+") {
        Write-Host "Adding Scoop bucket: $bucket" -ForegroundColor Cyan
        & scoop bucket add $bucket
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add Scoop bucket: $bucket"
        }
    }
}

if (-not (Invoke-Logged '7-Zip' { Install-ScoopPackage '7zip' @('7z') })) { throw '7-Zip Scoop install failed.' }
if (-not (Invoke-Logged 'GitHub CLI' { Install-ScoopPackage 'gh' @('gh') })) { throw 'GitHub CLI Scoop install failed.' }
if (-not (Invoke-Logged 'Python' { Install-ScoopPackage 'python' @('python') })) { throw 'Python Scoop install failed.' }

if (-not (Install-FirstAvailableScoopPackage 'Visual C++ redistributables' @('vcredist-aio', 'vcredist2022', 'vcredist') @())) {
    Install-WingetPackage 'Microsoft.VCRedist.2015+.x64' 'Visual C++ Redistributable x64' | Out-Null
    Install-WingetPackage 'Microsoft.VCRedist.2015+.x86' 'Visual C++ Redistributable x86' | Out-Null
}

foreach ($runtime in @(
    @{ Id = 'Microsoft.DotNet.DesktopRuntime.6'; Name = '.NET 6 Desktop Runtime' },
    @{ Id = 'Microsoft.DotNet.DesktopRuntime.8'; Name = '.NET 8 Desktop Runtime' },
    @{ Id = 'Microsoft.DotNet.DesktopRuntime.9'; Name = '.NET 9 Desktop Runtime' }
)) {
    Install-WingetPackage $runtime.Id $runtime.Name | Out-Null
}

if (-not (Invoke-Logged 'Temurin Java 17' { Install-ScoopPackage 'temurin17-jdk' @() })) { throw 'Temurin Java 17 Scoop install failed.' }
if (-not (Invoke-Logged 'Temurin Java 8' { Install-ScoopPackage 'temurin8-jdk' @() })) { throw 'Temurin Java 8 Scoop install failed.' }

if (-not (Invoke-Logged 'nvm' { Install-ScoopPackage 'nvm' @('nvm') })) { throw 'nvm Scoop install failed.' }
Refresh-SetupEnvironment

if (-not (Get-Command nvm -ErrorAction SilentlyContinue)) {
    throw 'nvm is not available after Scoop install.'
}

Write-Host "Installing/checking Node.js LTS via nvm..." -ForegroundColor Cyan
& nvm install lts
if ($LASTEXITCODE -ne 0) {
    throw 'Node.js LTS install via nvm failed.'
}
Refresh-SetupEnvironment
Write-Host "Activating Node.js LTS via nvm..." -ForegroundColor Cyan
& nvm use lts
if ($LASTEXITCODE -ne 0) {
    throw 'Node.js LTS activation via nvm failed.'
}
Refresh-SetupEnvironment

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'node is not available after nvm use lts.'
}

# nvm 2.0 (scoop main bucket since September 2026) is shim-based: node/npm/npx are Zig-built
# npm.exe-style shims in scoop\persist\nvm\.nodejs, and there is no npm.cmd anywhere on PATH.
# nvm 1.x had npm.cmd inside the NVM_SYMLINK folder. Asking for "npm" lets PATHEXT pick either;
# asking for npm.cmd failed every fresh install the day the bucket moved to 2.0.
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw 'npm is not available after nvm use lts.'
}
Write-Host ("npm resolved to {0}" -f (Get-Command npm).Source) -ForegroundColor Green

# Collect the .NET Framework 3.5 enable started at the top. If DISM is still busy, the status
# line attaches to it here and this is where the wait shows; if it already finished, only the
# result is checked. Must precede the WSL features: two DISM/CBS operations cannot run at once.
try {
    if ((Enable-WindowsFeature -FeatureName 'NetFx3' -DisplayName '.NET Framework 3.5' -Source $netfxSource -Started $netfxPending) -eq 'Failed') {
        Write-Host ".NET Framework 3.5 could not be enabled; continuing (optional)." -ForegroundColor Yellow
    }
}
catch {
    Write-Host ".NET Framework 3.5 enablement skipped: $($_.Exception.Message)" -ForegroundColor Yellow
}

if ($env:PCSETUP_CI -eq '1') {
    # A Server Core container has no hypervisor, no Appx surface and no winget, so every step
    # in here can only warn. Skipping keeps the CI build from spending minutes on dism and
    # winget calls whose failure is a foregone conclusion.
    Write-Host "SKIP: CI mode - skipping WSL prerequisites." -ForegroundColor Yellow
}
else {
    Enable-WslPrerequisites
}

if ($script:Failures.Count -gt 0) {
    Write-Host "Prerequisite initialization finished with $($script:Failures.Count) failure(s):" -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
    exit 1
}

Write-Host "Prerequisite initialization complete." -ForegroundColor Green
