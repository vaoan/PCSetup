# AJUSTES CPU/GPU MANUALES - Acer Predator PHN16-72 (i9-14900HX + RTX 4070 Laptop)
# Sin inicio automatico: se aplica solo cuando tu lo ejecutas.
#   MaxFPS  : CPU 4000/3000, GPU 1425 -> 82 FPS, GPU 73.8 C  [recomendado, maximo que cumple <=75 C]
#   Fresco  : CPU 4000/3000, GPU 1350 -> 77 FPS, GPU 69.4 C
#   Fabrica : sin limites             -> 98 FPS, GPU 84.9 C  (hot spot 93.5 C)
#   Estado  : solo muestra lo que esta activo
# El limite de CPU se mantiene al reiniciar; el de GPU se pierde al reiniciar o actualizar
# el driver NVIDIA -> ejecuta el perfil antes de jugar.
#   Juego90 : CPU 4000/3000, GPU 1600, tope 90 FPS -> elegido 2026-11-17 (unica GPU que aguanto 10 min al 100%
#             CPU+GPU+RAM sin corte: hot spot 91.8 C, sin freno termico, 0 errores)  [RECOMENDADO]
param([ValidateSet('Juego90','MaxFPS','Fresco','Fabrica','Estado')][string]$Perfil = 'Estado')

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Perfil $Perfil"; exit
}

$smi = "$env:SystemRoot\System32\nvidia-smi.exe"
if (-not (Test-Path $smi)) { $smi = 'nvidia-smi' }
$archivoPerfil = Join-Path (Split-Path $PSCommandPath) "perfil_actual.txt"

$PERFILES = @{
  Juego90 = @{ CPU_P = 4000; CPU_E = 3000; GPU = 1600; FPS = 90 }
  MaxFPS  = @{ CPU_P = 4000; CPU_E = 3000; GPU = 1425 }
  Fresco  = @{ CPU_P = 4000; CPU_E = 3000; GPU = 1350 }
  Fabrica = @{ CPU_P = 0;    CPU_E = 0;    GPU = 0 }      # 0 = sin limite
}

function Set-CpuLimite([int]$P, [int]$E) {
  foreach ($s in 'PROCFREQMAX','PROCFREQMAX1') { powercfg -attributes SUB_PROCESSOR $s -ATTRIB_HIDE 2>$null }
  $schemes = powercfg /list | Select-String '([0-9a-f]{8}-[0-9a-f-]{27})' | ForEach-Object { $_.Matches[0].Value }
  foreach ($sch in $schemes) {   # todos los planes, por si PredatorSense cambia el plan
    foreach ($x in @(@('PROCFREQMAX1',$P), @('PROCFREQMAX',$E))) {
      powercfg /setacvalueindex $sch SUB_PROCESSOR $x[0] $x[1]
      powercfg /setdcvalueindex $sch SUB_PROCESSOR $x[0] $x[1]
    }
  }
  powercfg /setactive SCHEME_CURRENT
}

function Show-Estado {
  Write-Host "`n--- ESTADO ACTUAL ---" -ForegroundColor Cyan
  if (Test-Path $archivoPerfil) { Write-Host "Ultimo perfil aplicado: $(Get-Content $archivoPerfil -TotalCount 1)" }
  foreach ($x in @(@('PROCFREQMAX1','P'), @('PROCFREQMAX','E'))) {
    $hex = (powercfg /query SCHEME_CURRENT SUB_PROCESSOR $x[0] | Select-String 'Current AC' | Select-Object -First 1) -replace '.*0x',''
    $v = [Convert]::ToInt32($hex,16)
    Write-Host ("CPU nucleos {0} max: {1}" -f $x[1], $(if ($v -eq 0) {'sin limite (fabrica)'} else {"$v MHz"}))
  }
  foreach ($t in 'AjusteTemperatura','AjusteTemperatura_GPU') {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) { Write-Host "AVISO: existe la tarea automatica '$t' (deberia estar borrada)" -ForegroundColor Yellow }
  }
  Write-Host "GPU ahora:"
  & $smi --query-gpu=clocks.gr,temperature.gpu,power.draw --format=csv
  Write-Host "(El tope de GPU no se puede leer; si reiniciaste desde el ultimo perfil, vuelve a aplicarlo.)" -ForegroundColor DarkGray
}

if ($Perfil -ne 'Estado') {
  $c = $PERFILES[$Perfil]
  Set-CpuLimite $c.CPU_P $c.CPU_E
  & $smi -rmc | Out-Null                      # memoria de GPU siempre de fabrica (bajarla quita FPS)
  if ($c.GPU -gt 0) { & $smi -lgc "210,$($c.GPU)"; $gpuOk = ($LASTEXITCODE -eq 0) }
  else              { & $smi -rgc | Out-Null;     $gpuOk = $true }
  if ($c.FPS) { & (Join-Path (Split-Path $PSCommandPath) 'Limite_FPS.ps1') -Fps $c.FPS -SinPausa }
  $desc = if ($c.GPU -gt 0) { "$Perfil (CPU $($c.CPU_P)/$($c.CPU_E) MHz, GPU $($c.GPU) MHz$(if ($c.FPS) {", tope $($c.FPS) FPS"}))" } else { "Fabrica (sin limites)" }
  "$desc  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Out-File $archivoPerfil -Encoding ascii
  Write-Host "`nAplicado: $desc" -ForegroundColor Green
  if (-not $gpuOk) { Write-Host "AVISO: nvidia-smi fallo con la GPU. Reinicia o reinstala el driver NVIDIA y repite." -ForegroundColor Red }
}
Show-Estado
try { Read-Host "`nPresiona Enter para cerrar" | Out-Null } catch {}
