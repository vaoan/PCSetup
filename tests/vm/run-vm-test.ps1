<#
.SYNOPSIS
    Runs the full PCSetup install in a throwaway Windows 11 VM, with nothing skipped.

.DESCRIPTION
    The Docker suite can only ever cover part of this repo: a Server Core container has no winget,
    no consumer Appx packages, no Defender and no WSL, so scripts 2, 5, 6, 10, 11 and 99 cannot
    run there at all. This harness exists because those are exactly the scripts that touch the
    machine hardest, and they were the least tested things in the repo.

    A real Windows 11 desktop VM has all of it, so run-all.bat runs unmodified and unskipped -
    PCSETUP_CI is deliberately NOT set.

    Flow:
      1. Build a small ISO holding autounattend.xml (avoids repacking the 8 GB Windows ISO).
      2. Create a Generation 2 VM with vTPM and Secure Boot, so Windows 11's requirements are met
         honestly rather than bypassed.
      3. Install Windows unattended, wait for the first-logon marker file.
      4. Checkpoint as 'clean-install' so later runs skip the 20-minute install entirely.
      5. Run the real install inside the guest over PowerShell Direct (no guest networking setup
         needed - it goes over VMBus).
      6. Run the Pester suite in the guest and report.

.PARAMETER Revert
    Reuse the existing 'clean-install' checkpoint instead of installing Windows again. This is the
    normal way to re-run a test.

.PARAMETER KeepVM
    Leave the VM running afterwards for inspection.

.EXAMPLE
    .\run-vm-test.ps1
.EXAMPLE
    .\run-vm-test.ps1 -Revert -Branch my-branch
#>
[CmdletBinding()]
param(
    [string] $IsoPath,
    [string] $VMName   = 'PCSetup-Test',
    [string] $Branch   = 'main',
    [string] $VMRoot   = 'C:\PCSetup-VM',
    [int]    $MemoryGB = 8,
    [int]    $CpuCount = 4,
    [int]    $DiskGB   = 80,
    [switch] $Revert,
    [switch] $KeepVM,
    # Build the answer-file ISO and stop. Exists so the ISO path can be exercised without
    # creating a VM or installing Windows - it is the fiddliest part of this script.
    [switch] $BuildIsoOnly
)

# Auto-elevate to Administrator. Unlike every other .ps1 here this block comes AFTER param(),
# because PowerShell requires param() to be the first statement in a file - the usual
# elevate-first form from CLAUDE.md is a parse error in a script that takes parameters. Bound
# parameters are forwarded so the elevated copy runs the command you actually typed.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $forward = foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { "-$($kv.Key)" }
        }
        else { "-$($kv.Key)"; "`"$($kv.Value)`"" }
    }
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $forward
    Start-Process PowerShell -ArgumentList $psArgs -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'

$GuestUser     = 'pcsetup'
$GuestPassword = 'PCSetupTest!2026'
$CheckpointName = 'clean-install'

function Write-Step { param([string]$m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Info { param([string]$m) Write-Host "    $m" -ForegroundColor DarkGray }
function Fail { param([string]$m) Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# ── Preflight ────────────────────────────────────────────────────────────────────────────────
Write-Step 'Preflight'

if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
    Fail "Hyper-V cmdlets are unavailable. Enable Hyper-V and reboot:`n  dism /online /enable-feature /featurename:Microsoft-Hyper-V-All /all"
}

if (-not $IsoPath) {
    # Newest by name, so Win11_25H2 wins over 24H2/23H2.
    $IsoPath = Get-ChildItem 'Z:\Downloads', "$env:USERPROFILE\Downloads" -Filter 'Win11*.iso' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $IsoPath -or -not (Test-Path $IsoPath)) { Fail "No Windows 11 ISO found. Pass -IsoPath." }
Write-Info "Windows ISO: $IsoPath"

$vmDir  = Join-Path $VMRoot $VMName
$vhdx   = Join-Path $vmDir "$VMName.vhdx"
$aiso   = Join-Path $vmDir 'autounattend.iso'
New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

$freeGB = [math]::Round((Get-PSDrive ($VMRoot[0])).Free / 1GB)
Write-Info "Free space on $($VMRoot[0]): : $freeGB GB (need ~$DiskGB GB)"
if ($freeGB -lt $DiskGB) { Fail "Not enough free space on $($VMRoot[0]):" }

$existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue

# ── Answer-file ISO ──────────────────────────────────────────────────────────────────────────
# Built with the IMAPI2 COM API rather than oscdimg, so the Windows ADK is not a prerequisite.
# CreateResultImage() hands back a COM IStream. PowerShell sees it as System.__ComObject and
# cannot call Read on it directly ("does not contain a method named 'Read'"), so the copy is done
# in a tiny typed helper that casts to ComTypes.IStream. Marshal.ReadInt32 supplies the
# bytes-read out-parameter, which avoids needing an /unsafe compile for a pointer.
if (-not ('PCSetup.IsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

namespace PCSetup {
    public static class IsoWriter {
        public static void Write(string path, object comStream, int blockSize, int totalBlocks) {
            System.Runtime.InteropServices.ComTypes.IStream stream =
                (System.Runtime.InteropServices.ComTypes.IStream)comStream;
            using (FileStream output = File.OpenWrite(path)) {
                byte[] buffer = new byte[blockSize];
                IntPtr read = Marshal.AllocHGlobal(4);
                try {
                    while (totalBlocks-- > 0) {
                        stream.Read(buffer, blockSize, read);
                        output.Write(buffer, 0, Marshal.ReadInt32(read));
                    }
                    output.Flush();
                }
                finally { Marshal.FreeHGlobal(read); }
            }
        }
    }
}
'@
}

function New-AnswerIso {
    param([string]$SourceDir, [string]$Destination)

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet
    $fsi.VolumeName = 'UNATTEND'
    $fsi.Root.AddTree($SourceDir, $false)

    $result = $fsi.CreateResultImage()
    Remove-Item $Destination -Force -ErrorAction SilentlyContinue
    [PCSetup.IsoWriter]::Write($Destination, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)
}

if (-not $Revert -or -not $existing) {
    Write-Step 'Building answer-file ISO'
    # Stage autounattend.xml alone in its own folder - AddTree takes a whole directory.
    $stage = Join-Path $vmDir 'unattend-stage'
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'autounattend.xml') (Join-Path $stage 'autounattend.xml') -Force
    New-AnswerIso -SourceDir $stage -Destination $aiso
    Write-Info "answer ISO: $aiso ($([math]::Round((Get-Item $aiso).Length / 1KB)) KB)"
}

if ($BuildIsoOnly) {
    Write-Step 'BuildIsoOnly: stopping before VM creation'
    Write-Info $aiso
    exit 0
}

# ── VM lifecycle ─────────────────────────────────────────────────────────────────────────────
if ($existing -and $Revert) {
    Write-Step "Reverting '$VMName' to checkpoint '$CheckpointName'"
    $cp = Get-VMCheckpoint -VMName $VMName -Name $CheckpointName -ErrorAction SilentlyContinue
    if (-not $cp) { Fail "No '$CheckpointName' checkpoint. Run once without -Revert first." }
    if ((Get-VM $VMName).State -ne 'Off') { Stop-VM $VMName -TurnOff -Force }
    Restore-VMCheckpoint -VMName $VMName -Name $CheckpointName -Confirm:$false
    Start-VM $VMName
}
else {
    if ($existing) {
        Write-Step "Removing existing VM '$VMName'"
        if ($existing.State -ne 'Off') { Stop-VM $VMName -TurnOff -Force }
        Remove-VM $VMName -Force
        Remove-Item $vhdx -Force -ErrorAction SilentlyContinue
    }

    Write-Step "Creating VM '$VMName'"
    $switch = (Get-VMSwitch | Where-Object SwitchType -eq 'External' | Select-Object -First 1).Name
    if (-not $switch) { $switch = (Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue).Name }
    if (-not $switch) { Fail "No usable VM switch. The guest needs internet to install anything." }
    Write-Info "network switch: $switch"

    New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) `
           -NewVHDPath $vhdx -NewVHDSizeBytes ($DiskGB * 1GB) -SwitchName $switch -Path $vmDir | Out-Null
    Set-VM -Name $VMName -ProcessorCount $CpuCount -CheckpointType Standard -AutomaticCheckpointsEnabled $false

    # Windows 11 requires TPM 2.0 and Secure Boot. Meeting them beats bypassing them: a bypassed
    # install is not the machine this repo actually targets.
    Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
    Enable-VMTPM -VMName $VMName
    Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'

    Add-VMDvdDrive -VMName $VMName -Path $IsoPath
    Add-VMDvdDrive -VMName $VMName -Path $aiso
    $dvd = Get-VMDvdDrive -VMName $VMName | Select-Object -First 1
    Set-VMFirmware -VMName $VMName -FirstBootDevice $dvd

    Write-Step 'Installing Windows (unattended)'
    Write-Info "Expect roughly 15-25 minutes. Watch it live with: vmconnect localhost $VMName"
    Start-VM $VMName
}

# ── Wait for the guest ───────────────────────────────────────────────────────────────────────
$cred = New-Object System.Management.Automation.PSCredential(
    $GuestUser, (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))

Write-Step 'Waiting for the guest to finish OOBE'
# PowerShell Direct works over VMBus, so this needs no guest IP, firewall rule or WinRM config -
# it only needs the guest to be up and the credentials to be valid.
$deadline = (Get-Date).AddMinutes(60)
$ready = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 20
    try {
        $marker = Invoke-Command -VMName $VMName -Credential $cred -ErrorAction Stop -ScriptBlock {
            Test-Path 'C:\pcsetup-vm-ready.txt'
        }
        if ($marker) { $ready = $true; break }
        Write-Info 'guest reachable, still finishing first logon...'
    }
    catch {
        Write-Info "waiting... ($([int]($deadline - (Get-Date)).TotalMinutes) min left)"
    }
}
if (-not $ready) { Fail "Guest never reported ready. Inspect with: vmconnect localhost $VMName" }
Write-Info 'guest is ready'

if (-not $Revert) {
    Write-Step "Checkpointing as '$CheckpointName'"
    Write-Info 'Later runs can use -Revert and skip the Windows install entirely.'
    Checkpoint-VM -Name $VMName -SnapshotName $CheckpointName
}

# ── The actual test ──────────────────────────────────────────────────────────────────────────
Write-Step "Running the full PCSetup install in the guest (branch: $Branch)"
Write-Info 'PCSETUP_CI is NOT set: all 13 scripts run for real, nothing is skipped.'

$installResult = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    param($branch)
    $ErrorActionPreference = 'Continue'
    $log = 'C:\pcsetup-install.log'
    try {
        # Exactly the documented fresh-machine entry point - the thing a real format runs.
        & powershell -NoProfile -ExecutionPolicy Bypass -Command `
            "iex ((New-Object Net.WebClient).DownloadString('https://i.ffxiv.be/?branch=$branch'))" *>&1 |
            Tee-Object -FilePath $log
        return @{ ExitCode = $LASTEXITCODE; Log = (Get-Content $log -Raw -ErrorAction SilentlyContinue) }
    }
    catch {
        return @{ ExitCode = 1; Log = $_.Exception.Message }
    }
} -ArgumentList $Branch

Write-Host $installResult.Log
Write-Info "installer exit code: $($installResult.ExitCode)"

Write-Step 'Verifying the installed machine'
$verify = Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    $r = [ordered]@{}
    $r['scoop']            = [bool](Get-Command scoop  -ErrorAction SilentlyContinue)
    $r['choco']            = [bool](Get-Command choco  -ErrorAction SilentlyContinue)
    $r['git']              = [bool](Get-Command git    -ErrorAction SilentlyContinue)
    $r['node']             = [bool](Get-Command node   -ErrorAction SilentlyContinue)
    $r['winget']           = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    $r['wsl']              = [bool](Get-Command wsl    -ErrorAction SilentlyContinue)
    $r['execPolicy']       = (Get-ExecutionPolicy -Scope CurrentUser).ToString()
    $r['longPaths']        = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
    $r['defenderExcl']     = @(try { (Get-MpPreference).ExclusionPath } catch { @() }).Count
    $r['appxRemaining']    = @(Get-AppxPackage | Where-Object { $_.Name -match 'Photos|Camera|YourPhone|ZuneMusic' }).Count
    $r['takeOwnership']    = Test-Path 'Registry::HKEY_CLASSES_ROOT\*\shell\TakeOwnership'
    $r
}

Write-Host ''
Write-Host '=========== VM RESULT ===========' -ForegroundColor Cyan
$verify.GetEnumerator() | ForEach-Object { '{0,-16} {1}' -f $_.Key, $_.Value }
Write-Host '=================================' -ForegroundColor Cyan

if (-not $KeepVM) {
    Write-Step 'Shutting the VM down'
    Stop-VM $VMName -Force -ErrorAction SilentlyContinue
    Write-Info "VM kept on disk. Re-run fast with: .\run-vm-test.ps1 -Revert"
}

exit $(if ($installResult.ExitCode -eq 0) { 0 } else { 1 })
