# Create desktop shortcut for tunnel toggle
$desktop = if (Test-Path "$env:USERPROFILE\OneDrive\Desktop") { 
    "$env:USERPROFILE\OneDrive\Desktop" 
} elseif (Test-Path "$env:USERPROFILE\Desktop") { 
    "$env:USERPROFILE\Desktop" 
} else { 
    [Environment]::GetFolderPath("Desktop") 
}

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$ws = New-Object -ComObject WScript.Shell

Write-Host "Creating toggle shortcut on desktop..." -ForegroundColor Yellow
Write-Host "Desktop: $desktop" -ForegroundColor Gray

# Toggle Web Tunnel
$shortcut = $ws.CreateShortcut("$desktop\Toggle Tunnel.lnk")
$shortcut.TargetPath = Join-Path $scriptPath "toggle-tunnel.bat"
$shortcut.WorkingDirectory = $scriptPath
$shortcut.IconLocation = "shell32.dll,238"
$shortcut.Description = "Toggle Web Tunnel (Start/Stop)"
$shortcut.Save()
Write-Host "  Created: Toggle Tunnel.lnk" -ForegroundColor Green

# Toggle SSH Tunnel
$sshTogglePath = Join-Path $scriptPath "toggle-ssh-tunnel.bat"
if (Test-Path $sshTogglePath) {
    $shortcut = $ws.CreateShortcut("$desktop\Toggle SSH Tunnel.lnk")
    $shortcut.TargetPath = $sshTogglePath
    $shortcut.WorkingDirectory = $scriptPath
    $shortcut.IconLocation = "shell32.dll,144"
    $shortcut.Description = "Toggle SSH Tunnel (Start/Stop)"
    $shortcut.Save()
    Write-Host "  Created: Toggle SSH Tunnel.lnk" -ForegroundColor Green
}

# Toggle Claude Sessions (claude, claimangel, snd)
$claudeTogglePath = Join-Path $scriptPath "toggle-claude-session.bat"
if (Test-Path $claudeTogglePath) {
    # Claude session
    $shortcut = $ws.CreateShortcut("$desktop\Toggle Claude.lnk")
    $shortcut.TargetPath = $claudeTogglePath
    $shortcut.Arguments = "claude"
    $shortcut.WorkingDirectory = $scriptPath
    $shortcut.IconLocation = "shell32.dll,24"
    $shortcut.Description = "Toggle Claude Code tmux session (Start/Stop)"
    $shortcut.Save()
    Write-Host "  Created: Toggle Claude.lnk" -ForegroundColor Green

    # ClaimAngel session
    $shortcut = $ws.CreateShortcut("$desktop\Toggle ClaimAngel.lnk")
    $shortcut.TargetPath = $claudeTogglePath
    $shortcut.Arguments = "claimangel"
    $shortcut.WorkingDirectory = $scriptPath
    $shortcut.IconLocation = "shell32.dll,24"
    $shortcut.Description = "Toggle ClaimAngel Claude Code tmux session (Start/Stop)"
    $shortcut.Save()
    Write-Host "  Created: Toggle ClaimAngel.lnk" -ForegroundColor Green

    # SND session
    $shortcut = $ws.CreateShortcut("$desktop\Toggle SND.lnk")
    $shortcut.TargetPath = $claudeTogglePath
    $shortcut.Arguments = "snd"
    $shortcut.WorkingDirectory = $scriptPath
    $shortcut.IconLocation = "shell32.dll,24"
    $shortcut.Description = "Toggle SND bash tmux session (Start/Stop)"
    $shortcut.Save()
    Write-Host "  Created: Toggle SND.lnk" -ForegroundColor Green
}

# Remove old shortcuts if they exist
$oldShortcuts = @("Start Tunnel.lnk", "Stop Tunnel.lnk", "Restart Tunnel.lnk", "Toggle Claude Session.lnk")
foreach ($old in $oldShortcuts) {
    $oldPath = Join-Path $desktop $old
    if (Test-Path $oldPath) {
        Remove-Item $oldPath -Force
        Write-Host "  Removed: $old" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "Toggle shortcut created successfully!" -ForegroundColor Green
Write-Host "Double-click 'Toggle Tunnel' on your desktop to start or stop the tunnel." -ForegroundColor Cyan
