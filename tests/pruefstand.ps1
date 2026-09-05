<#
  Prueflauf fuer die Anycubic Bridge.

  Faehrt jedes Verb mit echten Dateien auf diesem Rechner an und prueft das
  Ergebnis, statt es nur fuer plausibel zu halten. Gedacht zum Wiederholen:
  reparieren, nochmal laufen lassen, bis nichts mehr rot ist.

      powershell -ExecutionPolicy Bypass -File tests\pruefstand.ps1
#>
[CmdletBinding()]
param(
    # Leer lassen: wird unten aus dem Skriptpfad abgeleitet. Im param-Block ist
    # $PSScriptRoot noch nicht gefuellt.
    [string]$Bridge,
    [string]$Modell = 'C:\Users\Admin\Desktop\Deckenhalterung Beamer.3mf',
    [string]$Schrift = 'C:\Users\Admin\Desktop\claude schrift.3mf',
    [switch]$OhneSlice   # Slicen dauert ~90s je Lauf
)

$ErrorActionPreference = 'Continue'
if (-not $Bridge) { $Bridge = Join-Path (Split-Path -Parent $PSScriptRoot) 'anycubic-bridge.ps1' }
if (-not (Test-Path -LiteralPath $Bridge)) { throw "Bridge-Skript nicht gefunden: $Bridge" }

$arbeit = Join-Path $env:TEMP 'anycubic-pruefstand'
if (Test-Path -LiteralPath $arbeit) { Remove-Item -LiteralPath $arbeit -Recurse -Force }
[void](New-Item -ItemType Directory -Path $arbeit -Force)

$script:ok = 0
$script:fehler = New-Object System.Collections.Generic.List[string]

function Pruefe {
    param([string]$Name, [scriptblock]$Test)
    try {
        $r = & $Test
        if ($r -is [string] -and $r) {
            Write-Host ("  FEHLER  {0}: {1}" -f $Name, $r) -ForegroundColor Red
            $script:fehler.Add("$Name : $r")
        } else {
            Write-Host ("  ok      {0}" -f $Name) -ForegroundColor Green
            $script:ok++
        }
    } catch {
        Write-Host ("  ABSTURZ {0}: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:fehler.Add("$Name : ABSTURZ - $($_.Exception.Message)")
    }
}

function Bridge {
    param([string[]]$Argumente)
    $alt = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Bridge @Argumente 2>&1 |
        ForEach-Object { [string]$_ }
    $ErrorActionPreference = $alt
    return ($out -join "`n")
}

Write-Host "`n=== 1. Lesende Verben ===" -ForegroundColor Cyan

Pruefe 'about nennt Werkzeug und Wasserzeichen' {
    $o = Bridge @('about')
    if ($o -notmatch 'Anycubic Bridge') { return "kein Name in der Ausgabe" }
    if ($o -notmatch 'AnycubicBridge') { return "kein Wasserzeichen" }
    $null
}

Pruefe 'status nennt Maschine' {
    $o = Bridge @('status')
    if ($o -notmatch 'Kobra') { return "keine Maschine erkannt" }
    $null
}

Pruefe 'status zeigt lesbares Filament (nicht {0, , 0, ...})' {
    $o = Bridge @('status')
    if ($o -match 'AktivesFilament\s*:\s*\{0,') { return "Filament wird als roher Array-Dump ausgegeben" }
    if ($o -notmatch 'AktivesFilament') { return "Feld fehlt ganz" }
    $null
}

Pruefe 'listprofiles liefert Profile' {
    $o = Bridge @('listprofiles')
    if ($o.Trim().Length -lt 10) { return "Ausgabe leer" }
    $null
}

Write-Host "`n=== 2. Geometrie ===" -ForegroundColor Cyan

Pruefe 'analyze liest die ausgelagerte Geometrie (p:path)' {
    $o = Bridge @('analyze', '-ModelPath', $Modell)
    if ($o -match '(?m)^Dreiecke\s*:\s*0\b') { return "0 Dreiecke - Production-Erweiterung nicht gelesen" }
    if ($o -match '-∞|Infinity') { return "unendliche Masse - Geometrie leer" }
    $null
}

Pruefe 'analyze trifft die Masse aus dem G-Code (162 x 162 x 20)' {
    $o = Bridge @('analyze', '-ModelPath', $Modell)
    if ($o -notmatch 'Breite_X_mm\s*:\s*16[12]') { return "Breite passt nicht: $o" }
    if ($o -notmatch 'Hoehe_Z_mm\s*:\s*20') { return "Hoehe passt nicht" }
    $null
}

Pruefe 'analyze erkennt den 90-Grad-Ueberhang' {
    $o = Bridge @('analyze', '-ModelPath', $Modell)
    if ($o -notmatch 'UeberhangGefunden\s*:\s*True') { return "Ueberhang nicht erkannt - Stuetzen wuerden fehlen" }
    $null
}

Pruefe 'analyze meldet fehlende Datei sauber statt abzustuerzen' {
    $o = Bridge @('analyze', '-ModelPath', (Join-Path $arbeit 'gibtsnicht.3mf'))
    if ($o -notmatch 'nicht|not found|Exception|Fehler') { return "keine verstaendliche Meldung" }
    $null
}

Write-Host "`n=== 3. Empfehlung und Profile ===" -ForegroundColor Cyan

Pruefe 'recommend liefert Werte mit Begruendung' {
    $o = Bridge @('recommend', '-ModelPath', $Modell)
    if ($o.Trim().Length -lt 30) { return "Ausgabe zu duenn" }
    $null
}

Pruefe 'recommend schlaegt bei 90-Grad-Ueberhang Stuetzen vor' {
    $o = Bridge @('recommend', '-ModelPath', $Modell)
    if ($o -notmatch 'support|Stuetz|Stütz') { return "keine Stuetzen empfohlen, obwohl 90 Grad Ueberhang" }
    $null
}

$testProfil = 'ZZ Pruefstand'
Pruefe 'writeprofile ohne -Force schreibt nichts (Trockenlauf)' {
    $ziel = Join-Path $env:APPDATA "AnycubicSlicerNext\user\default\process\$testProfil.json"
    if (Test-Path -LiteralPath $ziel) { Remove-Item -LiteralPath $ziel -Force }
    [void](Bridge @('writeprofile', '-ProfileName', $testProfil, '-Values', 'layer_height=0.24'))
    if (Test-Path -LiteralPath $ziel) { return "Datei wurde ohne -Force angelegt" }
    $null
}

Pruefe 'writeprofile mit -Force schreibt die Werte wirklich' {
    $ziel = Join-Path $env:APPDATA "AnycubicSlicerNext\user\default\process\$testProfil.json"
    [void](Bridge @('writeprofile', '-ProfileName', $testProfil, '-Values', 'layer_height=0.24;sparse_infill_density=17%', '-Force'))
    if (-not (Test-Path -LiteralPath $ziel)) { return "Datei fehlt" }
    $j = Get-Content -LiteralPath $ziel -Raw
    if ($j -notmatch '"layer_height"\s*:\s*"0\.24"') { return "layer_height nicht gesetzt" }
    if ($j -notmatch '"sparse_infill_density"\s*:\s*"17%"') { return "Fuelldichte nicht gesetzt" }
    $null
}

Pruefe 'writeprofile vertraegt Sonderzeichen im Namen' {
    $name = 'ZZ Pruef (Umlaut aeoeue) #1'
    $o = Bridge @('writeprofile', '-ProfileName', $name, '-Values', 'layer_height=0.2', '-Force')
    $ziel = Join-Path $env:APPDATA "AnycubicSlicerNext\user\default\process\$name.json"
    if (-not (Test-Path -LiteralPath $ziel)) { return "Datei fehlt: $o" }
    Remove-Item -LiteralPath $ziel -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($ziel -replace '\.json$', '.info') -Force -ErrorAction SilentlyContinue
    $null
}

Pruefe '-IntoActive verlangt -Values statt blind alles zu ueberschreiben' {
    $o = Bridge @('writeprofile', '-IntoActive', '-Force')
    if ($o -notmatch 'braucht -Values') { return "warnt nicht: $o" }
    $null
}

Pruefe '-IntoActive aendert das ausgewaehlte Profil und sichert es vorher' {
    $st = Bridge @('status')
    $aktiv = ([regex]::Match($st, 'AktivesProfil\s*:\s*(.+)')).Groups[1].Value.Trim()
    if (-not $aktiv -or $aktiv -eq '(unbekannt)') { return $null }   # nichts ausgewaehlt, nicht pruefbar
    $datei = Join-Path $env:APPDATA "AnycubicSlicerNext\user\default\process\$aktiv.json"
    if (-not (Test-Path -LiteralPath $datei)) { return $null }       # System-Profil, wird nicht angefasst

    $vorher = Get-Content -LiteralPath $datei -Raw
    $o = Bridge @('writeprofile', '-IntoActive', '-Values', 'top_shell_layers=9', '-Force')
    try {
        if ($o -notmatch 'AKTIVE Profil') { return "kein Hinweis auf das aktive Profil: $o" }
        if ($o -notmatch 'Sicherung:') { return "keine Sicherung angelegt" }
        $j = Get-Content -LiteralPath $datei -Raw | ConvertFrom-Json
        if ([string]$j.top_shell_layers -ne '9') { return "Wert nicht gesetzt" }
        # Bestehende Werte des Nutzers muessen erhalten bleiben.
        $alt = $vorher | ConvertFrom-Json
        foreach ($k in $alt.PSObject.Properties.Name) {
            if ($k -eq 'top_shell_layers') { continue }
            if ([string]$j.$k -ne [string]$alt.$k) { return "bestehender Wert '$k' wurde veraendert" }
        }
        $null
    } finally {
        # Immer zuruecksetzen - der Prueflauf darf keine echte Konfiguration hinterlassen.
        Set-Content -LiteralPath $datei -Value $vorher -Encoding UTF8 -NoNewline
    }
}

Write-Host "`n=== 4. Anzeige ===" -ForegroundColor Cyan

Pruefe 'preview erzeugt ein echtes PNG' {
    $png = Join-Path $arbeit 'vorschau.png'
    [void](Bridge @('preview', '-ModelPath', $Modell, '-OutFile', $png))
    if (-not (Test-Path -LiteralPath $png)) { return "keine Datei" }
    $len = (Get-Item -LiteralPath $png).Length
    if ($len -lt 2000) { return "PNG verdaechtig klein ($len Bytes) - vermutlich leeres Bild" }
    $bytes = [System.IO.File]::ReadAllBytes($png)
    if ($bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50) { return "keine PNG-Signatur" }
    $null
}

# Ob ein Modell erkannt werden KANN, haengt am laufenden Slicer. Ist er zu, ist
# "leeres Bett" die richtige Antwort - das darf hier nicht als Fehler zaehlen.
$slicerOffen = [bool](Get-Process -Name '*AnycubicSlicerNext*' -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -and $_.MainWindowTitle -ne 'AnycubicSlicerNext' })

# WICHTIG: in eine eigene Datei schreiben lassen. Die Standarddatei unter
# %APPDATA% gehoert dem Watcher des Monitor-Fensters - laeuft der im Hintergrund,
# ueberschreibt er sie im Sekundentakt, und der Prueflauf misst dessen Ergebnis
# statt das eigene. Genau darauf bin ich einmal hereingefallen.
$dashDatei = Join-Path $arbeit 'dashboard-data.js'

Pruefe 'dashboard schreibt eine Datendatei' {
    $o = Bridge @('dashboard', '-OutFile', $dashDatei)
    if (-not (Test-Path -LiteralPath $dashDatei)) { return "keine Datei geschrieben: $o" }
    $null
}

if ($slicerOffen) {
    Pruefe 'dashboard erkennt das geladene Modell (nicht leer)' {
        $t = Get-Content -LiteralPath $dashDatei -Raw
        if ($t -match '"empty"\s*:\s*true') { return "meldet leeres Bett, obwohl ein Modell geladen ist" }
        if ($t -notmatch '"preview"\s*:\s*"data:image/png') { return "kein Vorschaubild eingebettet" }
        $null
    }
    Pruefe 'dashboard erkennt das Modell auch OHNE Sitzungsdatei des Slicers' {
        # Der Slicer legt seine .3mf erst beim Speichern oder Schneiden an.
        # Direkt nach dem Laden muss der Fenstertitel als Quelle einspringen.
        $t = Get-Content -LiteralPath $dashDatei -Raw
        $sess = Get-Process -Name '*AnycubicSlicerNext*' -ErrorAction SilentlyContinue | Select-Object -First 1
        $root = Join-Path $env:TEMP 'anycubicslicer_model'
        $sd = Get-ChildItem -LiteralPath $root -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*#$($sess.Id)#*" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($sd -and (Test-Path -LiteralPath (Join-Path $sd.FullName '.3mf'))) {
            return $null   # Sitzungsdatei existiert - dieser Fall ist hier nicht pruefbar
        }
        if ($t -match '"empty"\s*:\s*true') { return "ohne Sitzungsdatei wird das Bett nicht erkannt" }
        $null
    }
} else {
    Pruefe 'dashboard meldet ehrlich leer, wenn der Slicer zu ist' {
        $t = Get-Content -LiteralPath $dashDatei -Raw
        if ($t -notmatch '"empty"\s*:\s*true') { return "behauptet ein Modell, obwohl der Slicer nicht laeuft" }
        $null
    }
    Write-Host "  (Hinweis: Slicer laeuft nicht - Bett-Erkennung nur teilweise pruefbar)" -ForegroundColor Yellow
}

Pruefe 'dashboard-data.js ist gueltiges JSON' {
    $d = Join-Path $env:APPDATA 'AnycubicBridge\dashboard-data.js'
    $t = Get-Content -LiteralPath $dashDatei -Raw
    $t = $t -replace '^\uFEFF', '' -replace '^\s*window\.BRIDGE_DATA\s*=\s*', '' -replace ';\s*$', ''
    try { [void]($t | ConvertFrom-Json) } catch { return "kein gueltiges JSON: $($_.Exception.Message)" }
    $null
}

Write-Host "`n=== 5. Zweifarbig ===" -ForegroundColor Cyan

if (Test-Path -LiteralPath $Schrift) {
    $extrudiert = Join-Path $arbeit 'schrift-3d.3mf'
    Pruefe 'extrude macht aus der flachen Kontur einen Koerper' {
        [void](Bridge @('extrude', '-ModelPath', $Schrift, '-Thickness', '1.0', '-OutFile', $extrudiert))
        if (-not (Test-Path -LiteralPath $extrudiert)) { return "keine Ausgabedatei" }
        $o = Bridge @('analyze', '-ModelPath', $extrudiert)
        if ($o -match '(?m)^Dreiecke\s*:\s*0\b') { return "Ergebnis hat keine Geometrie" }
        if ($o -notmatch 'Hoehe_Z_mm\s*:\s*(1|0,9|1,0)') { return "Hoehe ist nicht ~1 mm:`n$o" }
        $null
    }

    Pruefe 'merge setzt die Schrift auf das Teil' {
        $verbunden = Join-Path $arbeit 'verbunden.3mf'
        $o = Bridge @('merge', '-ModelPath', $Modell, '-AddModel', $extrudiert, '-OutFile', $verbunden)
        if (-not (Test-Path -LiteralPath $verbunden)) { return "keine Ausgabedatei: $o" }
        if ($o -notmatch '\d') { return "keine Hoehe fuer den Farbwechsel genannt" }
        $a = Bridge @('analyze', '-ModelPath', $verbunden)
        if ($a -match '(?m)^Dreiecke\s*:\s*0\b') { return "verbundenes Modell ist leer" }
        $null
    }

    Pruefe 'merge findet auch eine Flaeche UNTERHALB der Oberkante' {
        # Die Deckenhalterung hat oben nur vier kleine Erhebungen; die grosse
        # ebene Flaeche liegt 10 mm tiefer. Wird nur nahe der Oberkante gesucht,
        # behauptet merge faelschlich, es gebe keine Auflage.
        $o = Bridge @('merge', '-ModelPath', $Modell, '-AddModel', $extrudiert,
                      '-OutFile', (Join-Path $arbeit 'tief.3mf'))
        if ($o -match 'Keine ebene Flaeche') { return "grosse Flaeche unterhalb der Oberkante wird uebersehen" }
        if ($o -notmatch 'auf Flaeche Z') { return "keine Auflagehoehe gemeldet" }
        $null
    }

    $griff = 'C:\Users\Admin\Desktop\Türgriff für Küche.3mf'
    if (Test-Path -LiteralPath $griff) {
        Pruefe 'merge setzt beim Tuergriff weiterhin oben auf (Rueckschlag-Test)' {
            $o = Bridge @('merge', '-ModelPath', $griff, '-AddModel', $extrudiert,
                          '-OutFile', (Join-Path $arbeit 'griff.3mf'))
            if ($o -notmatch 'auf Flaeche Z = 14[.,]2') { return "landet nicht mehr auf der Oberseite (14.2 mm):`n$o" }
            $null
        }
    }
} else {
    Write-Host "  (uebersprungen - $Schrift fehlt)" -ForegroundColor Yellow
}

Write-Host "`n=== 6. Slicen und G-Code ===" -ForegroundColor Cyan

if ($OhneSlice) {
    Write-Host "  (uebersprungen per -OhneSlice)" -ForegroundColor Yellow
} else {
    $gcode = Join-Path $arbeit 'test.gcode'
    Pruefe 'slice erzeugt G-Code mit Dauer und Filament' {
        $o = Bridge @('slice', '-ModelPath', $Modell, '-Values', 'layer_height=0.28;sparse_infill_density=10%', '-OutFile', $gcode)
        if (-not (Test-Path -LiteralPath $gcode)) { return "keine G-Code-Datei: $o" }
        if ($o -notmatch 'Dauer') { return "keine Dauer gemeldet" }
        if ($o -notmatch 'Filament') { return "kein Filamentverbrauch gemeldet" }
        $null
    }

    Pruefe 'slice traegt die eigenen Prozesswerte wirklich ein' {
        $kopf = Get-Content -LiteralPath $gcode -Tail 3000
        if (-not ($kopf -match '^;\s*layer_height\s*=\s*0\.28')) { return "layer_height nicht uebernommen" }
        if (-not ($kopf -match '^;\s*sparse_infill_density\s*=\s*10%')) { return "Fuelldichte nicht uebernommen" }
        $null
    }

    Pruefe 'slice leitet Filamentwerte ins Filamentprofil (nicht ins Prozessprofil)' {
        $g2 = Join-Path $arbeit 'test2.gcode'
        [void](Bridge @('slice', '-ModelPath', $Modell, '-Values', 'filament_max_volumetric_speed=16;slow_down_layer_time=4', '-OutFile', $g2))
        $kopf = Get-Content -LiteralPath $g2 -Tail 3000
        if (-not ($kopf -match '^;\s*filament_max_volumetric_speed\s*=\s*16')) { return "Flusswert nicht angekommen" }
        if (-not ($kopf -match '^;\s*slow_down_layer_time\s*=\s*4')) { return "Kuehlwert nicht angekommen (gehoert ins Filamentprofil)" }
        $null
    }

    Pruefe 'colorchange setzt M600 an der richtigen Schicht' {
        $zwei = Join-Path $arbeit 'zweifarbig.gcode'
        [void](Bridge @('colorchange', '-GcodeFile', $gcode, '-AtHeight', '10', '-OutFile', $zwei, '-Force'))
        if (-not (Test-Path -LiteralPath $zwei)) { return "keine Ausgabedatei" }
        $t = Get-Content -LiteralPath $zwei -Raw
        if ($t -notmatch '(?m)^M600') { return "kein M600 eingefuegt" }
        $vorher = (Get-Item -LiteralPath $gcode).Length
        $nachher = (Get-Item -LiteralPath $zwei).Length
        if ($nachher -lt $vorher) { return "Ausgabe kleiner als Eingabe - da ging etwas verloren" }
        $null
    }
}

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host ("  bestanden: {0}    fehlgeschlagen: {1}" -f $script:ok, $script:fehler.Count) -ForegroundColor $(if ($script:fehler.Count -eq 0) { 'Green' } else { 'Red' })
if ($script:fehler.Count -gt 0) {
    Write-Host "`n  Offen:" -ForegroundColor Red
    foreach ($f in $script:fehler) { Write-Host "   - $f" -ForegroundColor Red }
}
exit $script:fehler.Count
