<#
=====================================================================
 Platzhalter-Logo erzeugen
---------------------------------------------------------------------
 PLATZHALTER - soll noch durch ein richtiges Logo ersetzt werden.

 Wichtig ist vor allem, dass das Icon FEST ist: vorher wurde es aus der
 Vorschau des gerade geladenen Modells gebaut, dadurch aenderte sich das
 Programm-Symbol bei jedem Bauen.

 Motiv: gestapelte Schichten - das, was ein Drucker tatsaechlich tut.
=====================================================================
#>

[CmdletBinding()]
param(
    [string]$OutPath = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'logo.png'),
    [int]$Size = 256
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$bmp = New-Object System.Drawing.Bitmap($Size, $Size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)

# Gleiche Kupfer-Akzentfarbe wie im Fenster
$copper = [System.Drawing.Color]::FromArgb(255, 201, 97, 46)
$dark   = [System.Drawing.Color]::FromArgb(255, 26, 36, 48)

# Grundplatte (das Bett)
$plate = New-Object System.Drawing.SolidBrush($dark)
$g.FillRectangle($plate, [int]($Size * 0.10), [int]($Size * 0.74), [int]($Size * 0.80), [int]($Size * 0.10))
$plate.Dispose()

# Drei Schichten, nach oben schmaler - eine Wand im Aufbau
$layers = @(
    @{ y = 0.56; w = 0.62; a = 255 },
    @{ y = 0.40; w = 0.50; a = 220 },
    @{ y = 0.24; w = 0.36; a = 185 }
)
foreach ($l in $layers) {
    $c = [System.Drawing.Color]::FromArgb($l.a, $copper.R, $copper.G, $copper.B)
    $b = New-Object System.Drawing.SolidBrush($c)
    $w = [int]($Size * $l.w)
    $x = [int](($Size - $w) / 2)
    $g.FillRectangle($b, $x, [int]($Size * $l.y), $w, [int]($Size * 0.11))
    $b.Dispose()
}

$g.Dispose()
$bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"Platzhalter-Logo: $OutPath"
