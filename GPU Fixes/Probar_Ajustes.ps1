# Prueba real a 2560x1600: GPU al 100% (FurMark 2) + CPU con carga tipo juego (Prime95, 8 hilos)
# Registra temperaturas/relojes/consumo y verifica los limites. Requiere administrador.
param([int]$Minutos = 20, [string]$Etiqueta = "", [switch]$SoloGPU, [switch]$SoloCPU, [int]$Hilos = 8)
$LIM_CPU = 80; $LIM_GPU = 75; $LIM_HOT = 85

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Minutos $Minutos"; exit
}
$base = Split-Path $PSCommandPath
$res  = Join-Path $base "Resultados"; New-Item -ItemType Directory -Force $res | Out-Null
$stamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$csv = Join-Path $res "prueba_$stamp.csv"

$lhm = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter "LibreHardwareMonitor*" | Select-Object -First 1 -ExpandProperty FullName
$p95 = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter "mersenne.prime95*" | Select-Object -First 1 -ExpandProperty FullName
$fm  = "C:\Program Files\Geeks3D\FurMark2_x64\furmark.exe"
if (-not $lhm -or -not $p95 -or -not (Test-Path $fm)) { Write-Host "Faltan herramientas (LibreHardwareMonitor / Prime95 / FurMark 2)." -ForegroundColor Red; try { Read-Host } catch {}; exit 1 }

Write-Host "Prueba de $Minutos min a 2560x1600. No uses la laptop. Ctrl+C para cancelar." -ForegroundColor Cyan
Write-Host "Requisito: PredatorSense en Rendimiento/Turbo y cargador conectado.`n"

# Prime95: 8 hilos (carga parecida a un juego pesado), FFT pequenas
@"
V24OptionsConverted=1
WGUID_version=2
StressTester=1
UsePrimenet=0
MinTortureFFT=36
MaxTortureFFT=248
TortureMem=0
TortureTime=3
TortureThreads=$Hilos
"@ | Set-Content "$p95\prime.txt" -Encoding ascii
if (Test-Path "$p95\results.txt") { Remove-Item "$p95\results.txt" -Force }

# Sensores
Get-ChildItem $lhm -Filter *.dll | ForEach-Object { try { [void][Reflection.Assembly]::LoadFrom($_.FullName) } catch {} }
$c = New-Object LibreHardwareMonitor.Hardware.Computer
$c.IsCpuEnabled = $true; $c.IsGpuEnabled = $true; $c.Open()

$t0 = Get-Date
$fmOut = Join-Path $res "furmark_$stamp.txt"
if (-not $SoloGPU) { Start-Process $p95\prime95.exe -ArgumentList '-t' -WorkingDirectory $p95 -WindowStyle Minimized }
if (-not $SoloCPU) { Start-Process $fm -ArgumentList "--demo furmark-vk --width 2560 --height 1600 --hpgfx 1 --vsync 0 --max-time $($Minutos*60+30) --no-score-box --print-render-speed" -WorkingDirectory (Split-Path $fm) -RedirectStandardOutput $fmOut }

# Vigilante de ventiladores (sensor Acer): en "Max" deben quedar fijos ~5357/4615 rpm
$acer = Get-CimInstance -Namespace root\wmi -ClassName AcerGamingFunction -ErrorAction SilentlyContinue
function Get-Rpm($x) { if (-not $acer) { return 0 }; $o = [uint64](Invoke-CimMethod -InputObject $acer -MethodName GetGamingSysInfo -Arguments @{gmInput=[uint32]$x}).gmOutput; [int](($o -shr 8) -band 0xFFFF) }
$caidas = New-Object System.Collections.Generic.List[datetime]; $ventPulsando = $false; $corteTermico = $false

"hora,cpu_c,cpu_w,pcore_mhz_max,gpu_c,gpu_hotspot_c,gpu_w,gpu_mhz,gpu_limitador,vent_cpu_min,vent_gpu_min" | Out-File $csv -Encoding utf8
$rows = @()
$end = $t0.AddMinutes($Minutos)
try {
  while ((Get-Date) -lt $end) {
    $r = @{}
    foreach ($h in $c.Hardware) { $h.Update(); foreach ($s in $h.Sensors) { if ($s.Value -ne $null) { $r["$($s.SensorType)|$($s.Name)"] = [double]$s.Value } } }
    $pmax = ($r.Keys | Where-Object { $_ -match '^Clock\|P-Core #' } | ForEach-Object { $r[$_] } | Measure-Object -Maximum).Maximum
    $g = (& nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.gr,clocks_throttle_reasons.active --format=csv,noheader,nounits) -split ',\s*'
    $hot = if ($r.ContainsKey('Temperature|GPU Hot Spot')) { [math]::Round($r['Temperature|GPU Hot Spot'],1) } else { '' }
    $row = [pscustomobject]@{ hora=(Get-Date -Format HH:mm:ss); cpu=[math]::Round($r['Temperature|CPU Package']); cpuw=[math]::Round($r['Power|CPU Package']);
      pmhz=[math]::Round($pmax); gpu=[double]$g[0]; hot=$hot; gpuw=[double]$g[1]; gmhz=[int]$g[2]; thr=$g[3] }
    # 5 lecturas de ventilador (1 por segundo) en lugar de esperar 5 s
    $vc = @(); $vg = @()
    1..5 | ForEach-Object { $a1 = Get-Rpm 0x0201; $a2 = Get-Rpm 0x0601; $vc += $a1; $vg += $a2; if ($a1 -gt 0 -and $a1 -lt 5000) { $caidas.Add((Get-Date)) }; Start-Sleep 1 }
    $row | Add-Member vcmin (($vc | Measure-Object -Minimum).Minimum); $row | Add-Member vgmin (($vg | Measure-Object -Minimum).Minimum)
    $rows += $row
    "$($row.hora),$($row.cpu),$($row.cpuw),$($row.pmhz),$($row.gpu),$($row.hot),$($row.gpuw),$($row.gmhz),$($row.thr),$($row.vcmin),$($row.vgmin)" | Out-File $csv -Append -Encoding utf8
    Write-Host ("{0}  CPU {1}C {2}W {3}MHz | GPU {4}C hot {5}C {6}W {7}MHz | vent {8}/{9} rpm" -f $row.hora,$row.cpu,$row.cpuw,$row.pmhz,$row.gpu,$row.hot,$row.gpuw,$row.gmhz,$row.vcmin,$row.vgmin)
    if (-not $SoloCPU -and -not (Get-Process furmark -ErrorAction SilentlyContinue)) { Write-Host "FurMark se cerro antes de tiempo (posible crash)" -ForegroundColor Red; break }
    # 3 caidas de ventilador en 60 s = PredatorSense pulsando -> prueba invalida
    $recientes = @($caidas | Where-Object { $_ -gt (Get-Date).AddSeconds(-60) })
    if ($recientes.Count -ge 3) { $ventPulsando = $true; Write-Host "VENTILADORES PULSANDO (CPU $($row.cpu)C, GPU $($row.gpu)C, hot $($row.hot)C) -> prueba invalida" -ForegroundColor Red; break }
    # corte de seguridad
    if ($row.cpu -ge 95 -or ($row.hot -ne '' -and [double]$row.hot -ge 97)) { $corteTermico = $true; Write-Host "CORTE DE SEGURIDAD por temperatura" -ForegroundColor Red; break }
  }
} finally {
  $vivoP95 = $SoloGPU -or [bool](Get-Process prime95 -ErrorAction SilentlyContinue)
  $vivoFM  = $SoloCPU -or [bool](Get-Process furmark -ErrorAction SilentlyContinue)
  Stop-Process -Name prime95,furmark -Force -ErrorAction SilentlyContinue
  $c.Close()
}

# Analisis (se ignoran los primeros 60 s de calentamiento)
$sost = $rows | Select-Object -Skip 12
if (-not $sost) { $sost = $rows }
$m = { param($p) [math]::Round(($sost | Measure-Object $p -Maximum).Maximum,1) }
$a = { param($p) [math]::Round(($sost | Measure-Object $p -Average).Average,1) }
$hotVals = $sost | Where-Object { $_.hot -ne '' } | ForEach-Object { [double]$_.hot }
$hotMax = if ($hotVals) { ($hotVals | Measure-Object -Maximum).Maximum } else { 0 }
$fps = (Get-Content $fmOut -ErrorAction SilentlyContinue | Select-String -Pattern 'fps[^\d]*(\d+)' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { [int]$_.Groups[1].Value })
$fpsAvg = if ($fps) { [math]::Round(($fps | Measure-Object -Average).Average) } else { 'N/D' }
$p95err = if (Test-Path "$p95\results.txt") { Select-String "$p95\results.txt" -Pattern 'FATAL|ERROR|failure|rounding' } else { $null }
$ev = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$t0} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match 'WHEA|nvlddmkm' }

$ok = ((& $m 'cpu') -le $LIM_CPU) -and ((& $m 'gpu') -le $LIM_GPU) -and ($hotMax -le $LIM_HOT) -and (-not $p95err) -and (-not $ev) -and $vivoFM -and $vivoP95 -and -not $ventPulsando -and -not $corteTermico
$ventMin = { param($p) ($rows | Where-Object { $_.$p -gt 0 } | Measure-Object $p -Minimum).Minimum }
$cfg = if ($Etiqueta) { @($Etiqueta) } elseif (Test-Path (Join-Path $base "perfil_actual.txt")) { @(Get-Content (Join-Path $base "perfil_actual.txt") -TotalCount 1) } else { @('perfil desconocido (aplica 1, 2 o 3 antes de probar)') }
$informe = @"
PRUEBA $stamp  ($Minutos min, 2560x1600, carga: $(if ($SoloGPU) {'solo GPU'} elseif ($SoloCPU) {"solo CPU $Hilos hilos"} else {"CPU $Hilos hilos + GPU"}))  =>  $(if ($ok) {'APROBADA'} else {'FALLO'})
Ajustes: $($cfg -join ' | ')
CPU  max $(& $m 'cpu') C (limite $LIM_CPU) | prom $(& $a 'cpu') C | prom $(& $a 'cpuw') W | nucleo P max $(& $m 'pmhz') MHz
GPU  max $(& $m 'gpu') C (limite $LIM_GPU) | hot spot max $hotMax C (limite $LIM_HOT) | prom $(& $a 'gpuw') W | prom $(& $a 'gmhz') MHz
FPS FurMark promedio: $fpsAvg
Ventiladores minimo: CPU $(& $ventMin 'vcmin') rpm / GPU $(& $ventMin 'vgmin') rpm | Caidas: $($caidas.Count)$(if ($ventPulsando) {' | INVALIDA: VENTILADORES PULSANDO'})$(if ($corteTermico) {' | CORTE DE SEGURIDAD'})
Errores Prime95: $(if ($p95err) { $p95err.Count } else { 0 }) | Eventos WHEA/NVIDIA: $(if ($ev) { $ev.Count } else { 0 }) | Programas vivos al final: Prime95=$vivoP95 FurMark=$vivoFM
"@
if (-not $SoloCPU -and (& $a 'gpuw') -lt 70) { $informe += "`nAVISO: la GPU uso menos de 70 W. Revisa modo PredatorSense (Turbo/Rendimiento) y el cargador." }
$informe | Out-File (Join-Path $res "RESUMEN_PRUEBAS.txt") -Append -Encoding utf8
"" | Out-File (Join-Path $res "RESUMEN_PRUEBAS.txt") -Append -Encoding utf8
Write-Host "`n$informe" -ForegroundColor $(if ($ok) {'Green'} else {'Red'})
try { Read-Host "`nPresiona Enter para cerrar" | Out-Null } catch {}
