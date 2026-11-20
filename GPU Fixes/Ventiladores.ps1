# ARREGLAR VENTILADORES: si suben y bajan solos, reinicia PredatorSense (queda abierto)
# y comprueba las RPM reales durante 20 s. Normal en "Max": CPU ~5357 rpm, GPU ~4615 rpm fijos.
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""; exit
}
$i = Get-CimInstance -Namespace root\wmi -ClassName AcerGamingFunction
function Get-Rpm($x) { $o = [uint64](Invoke-CimMethod -InputObject $i -MethodName GetGamingSysInfo -Arguments @{gmInput=[uint32]$x}).gmOutput; [int](($o -shr 8) -band 0xFFFF) }

Write-Host "Reiniciando PredatorSense..." -ForegroundColor Cyan
Stop-Process -Name PredatorSense -Force -ErrorAction SilentlyContinue
Start-Sleep 3
Start-Process explorer.exe "shell:AppsFolder\ULICTekInc.PredatorSenseforNotebook_nt9dgb7efx6bt!PredatorSense"
Start-Sleep 20   # PredatorSense vuelve a aplicar el perfil activo (Max FPS)

Write-Host "Midiendo ventiladores 20 s..."
$cpu = @(); $gpu = @()
1..20 | ForEach-Object { $c = Get-Rpm 0x0201; $g = Get-Rpm 0x0601; $cpu += $c; $gpu += $g; Write-Host ("  CPU {0} rpm   GPU {1} rpm" -f $c, $g); Start-Sleep 1 }
$varC = ($cpu | Measure-Object -Maximum).Maximum - ($cpu | Measure-Object -Minimum).Minimum
$varG = ($gpu | Measure-Object -Maximum).Maximum - ($gpu | Measure-Object -Minimum).Minimum
if ($varC -le 300 -and $varG -le 300 -and ($cpu | Measure-Object -Minimum).Minimum -gt 5000) {
  Write-Host "`nOK: ventiladores fijos al maximo." -ForegroundColor Green
} else {
  Write-Host "`nSiguen variando (CPU +-$varC, GPU +-$varG rpm). Revisa que el perfil de PredatorSense tenga ventilador en Max." -ForegroundColor Yellow
}
try { Read-Host "`nPresiona Enter para cerrar" | Out-Null } catch {}
