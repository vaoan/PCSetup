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

# Remove old shortcuts if they exist. The Toggle Claude/SND/ClaimAngel entries
# are listed here because the MSYS2 tmux session feature was removed - this
# cleans them off the desktop of any machine that still has them.
$oldShortcuts = @("Start Tunnel.lnk", "Stop Tunnel.lnk", "Restart Tunnel.lnk", "Toggle Claude Session.lnk",
                  "Toggle Claude.lnk", "Toggle SND.lnk", "Toggle ClaimAngel.lnk")
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
