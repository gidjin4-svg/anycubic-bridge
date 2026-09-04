<#
=====================================================================
 Druckbett-Monitor einrichten
---------------------------------------------------------------------
 Legt die Anzeige-Dateien nach %APPDATA%\AnycubicBridge, erzeugt einmal
 Daten und eine Verknuepfung auf dem Desktop.

 Aufruf (im entpackten Ordner):
   powershell -ExecutionPolicy Bypass -File .\install.ps1
=====================================================================
#>

[CmdletBinding()]
param(
    # Adresse deines EIGENEN veroeffentlichten Claude-Artifacts fuer den Chat.
    # Ohne Angabe laeuft nur die Anzeige - der Chat-Knopf bleibt aus.
    # Jeder braucht dafuer sein eigenes Claude-Konto, siehe README.
    [string]$ChatUrl = '',
    [switch]$KeineVerknuepfung
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $env:APPDATA 'AnycubicBridge'

Write-Host "Druckbett-Monitor wird eingerichtet..."

# --- Voraussetzungen pruefen ----------------------------------------
$slicerDir = Join-Path $env:APPDATA 'AnycubicSlicerNext'
if (-not (Test-Path -LiteralPath $slicerDir)) {
    Write-Warning "Anycubic Slicer Next scheint nicht eingerichtet zu sein ($slicerDir fehlt)."
    Write-Warning "Starte den Slicer einmal und lade ein Modell, sonst hat das Fenster nichts anzuzeigen."
}

$wv2 = Get-ChildItem 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application' -Directory -ErrorAction SilentlyContinue
if (-not $wv2) {
    Write-Warning "WebView2-Runtime nicht gefunden. Falls das Fenster leer bleibt:"
    Write-Warning "  https://developer.microsoft.com/microsoft-edge/webview2/ (Evergreen Runtime)"
}

# --- Anzeige-Dateien ablegen ----------------------------------------
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

# Im gepackten Ordner liegt die Vorlage daneben, im Quellbaum eine Ebene hoeher.
$source = Join-Path $here 'druckbett-monitor.html'
if (-not (Test-Path -LiteralPath $source)) {
    $source = Join-Path (Split-Path -Parent $here) 'companion\druckbett-monitor.html'
}
if (-not (Test-Path -LiteralPath $source)) { throw "druckbett-monitor.html nicht gefunden." }

# Lokale Fassung: Zeichensatz + Datendatei einbinden.
$html = [System.IO.File]::ReadAllText($source, [System.Text.Encoding]::UTF8)
$prefix = '<meta charset="utf-8">' + "`r`n" +
          '<script src="dashboard-config.js"></script>' + "`r`n" +
          '<script src="dashboard-data.js"></script>' + "`r`n"
[System.IO.File]::WriteAllText(
    (Join-Path $dataDir 'monitor.html'),
    $prefix + $html,
    (New-Object System.Text.UTF8Encoding($true)))
Write-Host "  Anzeige installiert."

# --- Einstellungen: nur die eigene Chat-Adresse ----------------------
# Bewusst pro Nutzer: der Chat laeuft ueber das eigene Claude-Konto.
$existing = ''
$settingsPath = Join-Path $dataDir 'settings.json'
if ($ChatUrl -eq '' -and (Test-Path -LiteralPath $settingsPath)) {
    $m = [regex]::Match((Get-Content -LiteralPath $settingsPath -Raw), '"chatUrl"\s*:\s*"([^"]*)"')
    if ($m.Success) { $existing = $m.Groups[1].Value }
}
$url = if ($ChatUrl -ne '') { $ChatUrl } else { $existing }

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($settingsPath, "{`r`n  `"chatUrl`": `"$url`"`r`n}`r`n", $utf8)
[System.IO.File]::WriteAllText(
    (Join-Path $dataDir 'dashboard-config.js'),
    "window.BRIDGE_CONFIG = { chatUrl: `"$url`" };",
    (New-Object System.Text.UTF8Encoding($true)))
if ($url) { Write-Host "  Chat eingerichtet." } else { Write-Host "  Ohne Chat (nur Anzeige) - siehe README." }

# --- Einmal Daten erzeugen ------------------------------------------
$bridge = Join-Path $here 'anycubic-bridge.ps1'
if (-not (Test-Path -LiteralPath $bridge)) {
    $bridge = Join-Path (Split-Path -Parent $here) 'anycubic-bridge.ps1'
}
try {
    & $bridge dashboard -OutFile (Join-Path $dataDir 'dashboard-data.js') | Out-Null
    Write-Host "  Erste Daten erzeugt."
} catch {
    Write-Warning "  Konnte noch keine Daten erzeugen: $($_.Exception.Message)"
    Write-Warning "  Das ist normal, solange kein Modell geladen wurde."
}

# --- Verknuepfung ----------------------------------------------------
if (-not $KeineVerknuepfung) {
    $exe = Join-Path $here 'Druckbett-Monitor.exe'
    if (Test-Path -LiteralPath $exe) {
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Druckbett-Monitor.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($lnk)
        $sc.TargetPath = $exe
        $sc.WorkingDirectory = $here
        $sc.Arguments = '--mit-slicer'
        $sc.Description = 'Anycubic Slicer Next mit Druckbett-Monitor starten'
        $sc.Save()
        Write-Host "  Verknuepfung auf dem Desktop angelegt (startet auch den Slicer)."
    }
}

Write-Host ""
Write-Host "Fertig. Starte 'Druckbett-Monitor' vom Desktop."
