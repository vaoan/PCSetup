<#
.SYNOPSIS
    Installs Windows scheduled tasks to auto-start Claude Code in MSYS2 tmux sessions.

.DESCRIPTION
    This script creates scheduled tasks for:
    - claude: General Claude Code session (Z:\Users\Heiner\Documents\Cloudflare)
    - claimangel: ClaimAngel project (Z:\Github\ClaimAngel\frontend)
    - snd: SND project - bash only (Z:\Users\Heiner\Documents\Luas\SND)

    All tasks run at Windows logon with elevated (Admin) privileges.
    Claude Code runs with --dangerously-skip-permissions flag.

.PARAMETER Uninstall
    Remove all scheduled tasks

.PARAMETER Session
    Install only a specific session (claude, claimangel, snd, or all)

.NOTES
    Run as Administrator for scheduled task creation.

    IMPORTANT: Browser-based MCP servers (Playwright, Chrome DevTools) will NOT work
    in this remote environment. All other Claude Code functionality works fine.
#>

param(
    [switch]$Uninstall,
    [ValidateSet("all", "claude", "claimangel", "snd")]
    [string]$Session = "all"
)

$ErrorActionPreference = "Stop"

# Configuration
$MSYS2Path = "C:\msys64"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StartScript = Join-Path $ScriptDir "start-claude-session.sh"

# Session definitions
$Sessions = @{
    "claude" = @{
        TaskName = "claude-session"
        WorkingDir = "/z/Users/Heiner/Documents/Cloudflare"
        NoClaude = $false
        Description = "Claude Code in MSYS2 tmux (Cloudflare project)"
    }
    "claimangel" = @{
        TaskName = "claimangel-session"
        WorkingDir = "/z/Github/ClaimAngel/frontend"
        NoClaude = $false
        Description = "Claude Code in MSYS2 tmux (ClaimAngel project)"
    }
    "snd" = @{
        TaskName = "snd-session"
        WorkingDir = "/z/Users/Heiner/Documents/Luas/SND"
        NoClaude = $true
        Description = "Bash shell in MSYS2 tmux (SND project)"
    }
}

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    $color = switch ($Type) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Type] $Message" -ForegroundColor $color
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Uninstall-Session {
    param([string]$SessionName)

    $config = $Sessions[$SessionName]
    $taskName = $config.TaskName

    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Status "Scheduled task '$taskName' removed" -Type "Success"
    } else {
        Write-Status "Scheduled task '$taskName' not found" -Type "Warning"
    }
}

function Install-Session {
    param([string]$SessionName)

    $config = $Sessions[$SessionName]
    $taskName = $config.TaskName

    Write-Status "Installing session '$SessionName'..."

    # Remove existing task if present
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Write-Status "Removing existing scheduled task..." -Type "Info"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    # Convert script path to MSYS2 format
    $msysScriptPath = $StartScript -replace '\\', '/' -replace '^([A-Z]):', { '/' + $_.Groups[1].Value.ToLower() }

    # Build arguments
    $noClaude = if ($config.NoClaude) { "--no-claude" } else { "" }
    $bashArgs = "-l -c `"$msysScriptPath $SessionName $($config.WorkingDir) $noClaude`""

    $bashExe = Join-Path $MSYS2Path "usr\bin\bash.exe"
    $action = New-ScheduledTaskAction `
        -Execute $bashExe `
        -Argument $bashArgs

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    # Run with highest privileges (Admin)
    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -LogonType Interactive `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 0)

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description $config.Description | Out-Null

    Write-Status "Scheduled task '$taskName' created" -Type "Success"
}

# Main
if (-not (Test-Administrator)) {
    Write-Status "This script requires Administrator privileges" -Type "Warning"
    Write-Status "Relaunching as Administrator..." -Type "Info"

    $scriptPath = $MyInvocation.MyCommand.Path
    $arguments = @()
    if ($Uninstall) { $arguments += "-Uninstall" }
    if ($Session -ne "all") { $arguments += "-Session $Session" }

    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`" $($arguments -join ' ')" -Verb RunAs
    exit
}

# Verify prerequisites
if (-not (Test-Path $MSYS2Path)) {
    Write-Status "MSYS2 not found at $MSYS2Path" -Type "Error"
    exit 1
}

$tmuxPath = Join-Path $MSYS2Path "usr\bin\tmux.exe"
if (-not (Test-Path $tmuxPath)) {
    Write-Status "tmux not found in MSYS2. Install with: pacman -S tmux" -Type "Error"
    exit 1
}

if (-not (Test-Path $StartScript)) {
    Write-Status "Start script not found: $StartScript" -Type "Error"
    exit 1
}

Write-Status "Prerequisites verified" -Type "Success"

# Determine which sessions to process
$sessionsToProcess = if ($Session -eq "all") { $Sessions.Keys } else { @($Session) }

foreach ($s in $sessionsToProcess) {
    if ($Uninstall) {
        Uninstall-Session -SessionName $s
    } else {
        Install-Session -SessionName $s
    }
}

if (-not $Uninstall) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  Installation Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Sessions will start automatically at Windows logon." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To start now:" -ForegroundColor Yellow
    foreach ($s in $sessionsToProcess) {
        $taskName = $Sessions[$s].TaskName
        Write-Host "  Start-ScheduledTask -TaskName '$taskName'"
    }
    Write-Host ""
    Write-Host "To attach (from MSYS2/SSH):" -ForegroundColor Yellow
    foreach ($s in $sessionsToProcess) {
        Write-Host "  tmux attach -t $s"
    }
    Write-Host ""
    Write-Host "Or use aliases: claude, claimangel, snd" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "IMPORTANT:" -ForegroundColor Red
    Write-Host "  Browser-based MCP servers will NOT work in remote sessions."
    Write-Host ""
}
