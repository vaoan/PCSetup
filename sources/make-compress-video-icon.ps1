# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# make-compress-video-icon.ps1
# Regenerates optional\compress-video.ico: the same Vista Aero glass orb as download-video.ico
# (make-download-video-icon.ps1 - gloss cap, rim light, drop shadow, every size drawn natively
# from a 256-unit grid), in a cool sweep - deep blue -> teal -> green, "smaller and cleaner" - with
# two white arrows pushing in on a bar: the file being squeezed. It is the icon of the "Compress
# all videos here" shortcut and of anything else that compresses. Pure System.Drawing.
Add-Type -AssemblyName System.Drawing
function C([int]$a, [int]$r, [int]$gg, [int]$b) { [System.Drawing.Color]::FromArgb($a, $r, $gg, $b) }
function P([single]$x, [single]$y) { New-Object System.Drawing.PointF $x, $y }

function Render([int]$S) {
    $k = $S / 256.0
    $bmp = New-Object System.Drawing.Bitmap $S, $S
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.CompositingQuality = 'HighQuality'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    $cx = 128 * $k; $cy = 116 * $k; $R = 106 * $k
    $small = $S -lt 40

    # --- tight drop shadow
    if (-not $small) {
        for ($i = 6; $i -ge 1; $i--) {
            $a = [int](6 + $i * 3)
            $w = (170 + $i * 4) * $k; $h = (30 + $i * 2) * $k
            $g.FillEllipse((New-Object System.Drawing.SolidBrush (C $a 0 30 40)), [single]($cx - $w/2), [single](216 * $k - $h/2), [single]$w, [single]$h)
        }
    }

    $orb = New-Object System.Drawing.Drawing2D.GraphicsPath
    $orb.AddEllipse([single]($cx - $R), [single]($cy - $R), [single](2*$R), [single](2*$R))
    $g.SetClip((New-Object System.Drawing.Region $orb), 'Replace')

    # --- cool sweep: deep blue -> azure -> teal -> green (left to right, slight diagonal)
    $sweep = New-Object System.Drawing.Drawing2D.LinearGradientBrush (P ($cx - $R) ($cy - 40*$k)), (P ($cx + $R) ($cy + 40*$k)), (C 255 30 70 220), (C 255 60 200 90)
    $blend = New-Object System.Drawing.Drawing2D.ColorBlend
    $blend.Colors = [System.Drawing.Color[]]@((C 255 25 50 200), (C 255 30 90 230), (C 255 0 150 235), (C 255 0 175 200), (C 255 20 190 140), (C 255 70 205 80))
    $blend.Positions = [single[]]@(0, 0.16, 0.42, 0.58, 0.82, 1)
    $sweep.InterpolationColors = $blend
    $g.FillPath($sweep, $orb)

    # --- 3D shading: clear at the light source, darker toward the edge
    $pg = New-Object System.Drawing.Drawing2D.PathGradientBrush $orb
    $pg.CenterPoint = P ($cx - 28*$k) ($cy - 42*$k)
    $pg.CenterColor = C 0 0 0 0
    $pg.SurroundColors = [System.Drawing.Color[]]@((C 85 0 20 60))
    $g.FillPath($pg, $orb)

    # --- cool rim light hugging the bottom edge
    $rim = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rim.AddEllipse([single]($cx - $R + 10*$k), [single]($cy - $R + 60*$k), [single](2*$R - 20*$k), [single](2*$R - 50*$k))
    $rimBr = New-Object System.Drawing.Drawing2D.PathGradientBrush $rim
    $rimBr.CenterPoint = P $cx ($cy + $R - 6*$k)
    $rimBr.CenterColor = C 130 180 255 230
    $rimBr.SurroundColors = [System.Drawing.Color[]]@((C 0 180 255 230))
    $g.FillPath($rimBr, $rim)

    # --- hard-edged glass highlight (classic Aero cap)
    $hl = New-Object System.Drawing.Drawing2D.GraphicsPath
    $hl.AddEllipse([single]($cx - $R + 12*$k), [single]($cy - $R + 4*$k), [single](2*$R - 24*$k), [single]($R - 4*$k))
    $hlBr = New-Object System.Drawing.Drawing2D.LinearGradientBrush (P 0 ($cy - $R + 4*$k)), (P 0 ($cy)), (C 165 255 255 255), (C 20 255 255 255)
    $g.FillPath($hlBr, $hl)
    $g.ResetClip()

    # --- crisp outline
    $ow = [Math]::Max(1.0, 3.0 * $k)
    $g.DrawEllipse((New-Object System.Drawing.Pen (C 220 0 35 80), $ow), [single]($cx - $R), [single]($cy - $R), [single](2*$R), [single](2*$R))

    # --- glyph: two arrows pushing in on a bar (the file being squeezed), white, hard shadow, dark outline
    # Arrowheads point AT the bar (tips at 112 and 144, bar at 120..136): "push in", not "expand".
    $left  = @(@(40,98), @(82,98), @(82,72), @(112,116), @(82,160), @(82,134), @(40,134))
    $right = @(@(216,98), @(174,98), @(174,72), @(144,116), @(174,160), @(174,134), @(216,134))
    $glyph = New-Object System.Drawing.Drawing2D.GraphicsPath
    $glyph.AddPolygon([System.Drawing.PointF[]]($left  | ForEach-Object { P ($_[0]*$k) ($_[1]*$k) }))
    $glyph.StartFigure()
    $glyph.AddPolygon([System.Drawing.PointF[]]($right | ForEach-Object { P ($_[0]*$k) ($_[1]*$k) }))
    $glyph.StartFigure()
    $glyph.AddRectangle((New-Object System.Drawing.RectangleF ([single](120*$k)), ([single](62*$k)), ([single](16*$k)), ([single](108*$k))))
    $m = New-Object System.Drawing.Drawing2D.Matrix; $m.Translate([single](3*$k), [single](4*$k))
    $shadow = $glyph.Clone(); $shadow.Transform($m)
    if (-not $small) { $g.FillPath((New-Object System.Drawing.SolidBrush (C 150 0 30 70)), $shadow) }
    $aBr = New-Object System.Drawing.Drawing2D.LinearGradientBrush (P 0 (62*$k)), (P 0 (170*$k)), (C 255 255 255 255), (C 255 228 244 255)
    $g.FillPath($aBr, $glyph)
    $aw = [Math]::Max(1.0, 2.0 * $k)
    $g.DrawPath((New-Object System.Drawing.Pen (C 200 0 45 95), $aw), $glyph)

    # --- sparkle
    if (-not $small) {
        $sp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $sp.AddEllipse([single](58*$k), [single](40*$k), [single](28*$k), [single](16*$k))
        $spBr = New-Object System.Drawing.Drawing2D.PathGradientBrush $sp
        $spBr.CenterColor = C 240 255 255 255; $spBr.SurroundColors = [System.Drawing.Color[]]@((C 0 255 255 255))
        $g.FillPath($spBr, $sp)
    }
    $g.Dispose()
    return $bmp
}

. (Join-Path $PSScriptRoot 'icon-writer.ps1')
Write-NativeIcon -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'optional\compress-video.ico') -Render ${function:Render} -PreviewName 'compress-video'
