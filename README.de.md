# Anycubic Bridge

Lokale AI-<->Anycubic-Slicer-Next-Bruecke, gleiches Prinzip wie die
[Cura Bridge](../Cura%20Bridge/README.de.md) und die Gidjin Excel Bridge:
dateibasiert, kein COM/Live-Prozess-Zugriff.

## Unterschied zur Cura Bridge

Anycubic Slicer Next (OrcaSlicer-Fork) speichert Profile als reines JSON
unter `%APPDATA%\AnycubicSlicerNext\user\default\process\` — einfacher als
Curas Dateipaar-Format mit Prozent-Encoding, aber die Haupt-Konfigurations-
datei (`AnycubicSlicerNext.conf`) hat eine angehaengte
`# MD5 checksum <hash>`-Zeile, deren genauer Algorithmus sich nicht sicher
reproduzieren liess (mehrere Varianten getestet, keine passte). **Diese
Bruecke schreibt deshalb NIE in `AnycubicSlicerNext.conf`** — zu riskant,
die echte Konfiguration kaputtzumachen. Konsequenz: anders als bei Cura gibt
es **keine automatische Profil-Aktivierung**. Neue Profile landen in
`user\default\process\` und erscheinen im Process-Dropdown, muessen aber
manuell ausgewaehlt werden.

## Voraussetzungen

- Windows, Anycubic Slicer Next installiert
- Mindestens ein eigenes Profil in `user\default\process\` als Vorlage
  (liefert `inherits`/`version`-Schema) — `writeprofile` bricht sonst mit
  klarer Fehlermeldung ab
- Anycubic Slicer Next muss beim Analysieren/Schreiben NICHT laufen

## Verben

```
.\anycubic-bridge.ps1 about
.\anycubic-bridge.ps1 status
.\anycubic-bridge.ps1 listprofiles
.\anycubic-bridge.ps1 analyze
.\anycubic-bridge.ps1 analyze -ModelPath "C:\Pfad\Teil.stl"
.\anycubic-bridge.ps1 recommend
.\anycubic-bridge.ps1 writeprofile -ProfileName "Claude Tuergriff"
.\anycubic-bridge.ps1 writeprofile -ProfileName "Claude Tuergriff" -Force
```

`-MachinePreset` erzwingt eine bestimmte Zielmaschine (statt der aktuell in
`presets.machine` aktiven) — z. B. `-MachinePreset "Anycubic Kobra 1 0.4 nozzle"`.

## Vorlagen-Logik (wichtig fuer Korrektheit)

`writeprofile` sucht zuerst ein vorhandenes eigenes Profil, dessen `inherits`
zur Zielmaschine passt. Gibt es keins, wird aus einem beliebigen vorhandenen
Profil die Qualitaetsstufe (z. B. "0.20mm Standard") entnommen und mit der
Zielmaschine neu kombiniert — aber nur, wenn dieses kombinierte System-Profil
tatsaechlich existiert (sonst klare Fehlermeldung statt Raten). So wird nie
versehentlich die Druckerdefinition einer falschen Maschine geerbt.

## Geometrie-Analyse

Identisch zur Cura Bridge (reines PowerShell, STL binaer + 3MF Zip/XML,
keine Python-Abhaengigkeit) — Slicer-unabhaengig, 1:1 uebernommen.

## Zwei Objekte verbinden und zweifarbig drucken

Kompletter Ablauf, am Beispiel Schriftzug auf einem Türgriff:

```powershell
# 1) Flache Kontur (z. B. FreeCAD-Text ohne Dicke) zu einem Körper machen
.\anycubic-bridge.ps1 extrude -ModelPath "claude schrift.3mf" -Thickness 1.0 -OutFile "claude schrift 3d.3mf"

# 2) Aufsetzen - sucht selbst eine ebene Fläche, auf der es ganz aufliegt
.\anycubic-bridge.ps1 merge -ModelPath "Türgriff.3mf" -AddModel "claude schrift 3d.3mf" -OutFile "Türgriff mit Schriftzug.3mf"
#    -> nennt dir die Höhe für den Farbwechsel

# 3) Vorher ansehen: was wird welche Farbe?
.\anycubic-bridge.ps1 preview -ModelPath "Türgriff mit Schriftzug.3mf" -AtHeight 14.2 -PreviewSize 700 -OutFile vorschau.png

# 4) In Anycubic Slicer Next slicen, dann:
.\anycubic-bridge.ps1 colorchange -GcodeFile "teil.gcode" -AtHeight 14.2 -OutFile "zweifarbig.gcode" -Force
```

Mit `-OffsetX` / `-OffsetY` / `-OffsetZ` lässt sich die automatische Platzierung
verschieben.

**Warum eine Schicht über der Auflagefläche gewechselt wird:** die Schicht
genau auf der Grenze enthält noch die Deckfläche des Grundkörpers. Würde man
dort wechseln, käme die ganze Oberseite in der zweiten Farbe statt nur das
aufgesetzte Objekt. `merge` rechnet das schon richtig aus.

## Farbwechsel (zweifarbig drucken mit einem Extruder)

```
.\anycubic-bridge.ps1 colorchange -GcodeFile "...\teil.gcode" -AtHeight 12.4
.\anycubic-bridge.ps1 colorchange -GcodeFile "...\teil.gcode" -AtHeight 12.4 -OutFile "...\zweifarbig.gcode" -Force
```

Setzt `M600` (der Pausen-/Wechselbefehl des Kobra, aus `machine_pause_gcode`)
vor die erste Schicht ab der angegebenen Höhe. Der Drucker hält dort an, du
wechselst das Filament, alles darüber kommt in der zweiten Farbe.

Ohne `-Force` nur Trockenlauf. Ohne `-OutFile` wird die Datei überschrieben —
besser immer `-OutFile` angeben.

**Wichtige Grenze:** das funktioniert nur, wenn der andersfarbige Teil **oben
aufliegt** (z. B. ein erhabener Schriftzug auf der Oberseite). An einer
senkrechten Seitenfläche enthält jede Schicht beides gleichzeitig — ein
schichtbasierter Wechsel kann das nicht trennen.

## Widget: eigenes Fenster, das sich selbst aktualisiert

```
.\install-widget.ps1     einmalig: Fenster + erste Daten nach %APPDATA%\AnycubicBridge
start-widget.bat         startet Slicer + Watcher + Monitor-Fenster zusammen
```

Wie es zusammenhängt:

- `anycubic-bridge.ps1 watch` läuft im Hintergrund, prüft alle 10 Sekunden, ob
  sich das erkannte Modell geändert hat (Pfad oder Änderungszeit), und schreibt
  dann `%APPDATA%\AnycubicBridge\dashboard-data.js` neu — inklusive frisch
  gerenderter Mesh-Vorschau. Nur ein Watcher läuft gleichzeitig (Mutex), egal
  wie oft der Launcher gestartet wird.
- `monitor.html` liest diese Datei direkt. **Dadurch braucht die Anzeige weder
  Datenbank noch Claude-Kontext** — sie funktioniert offline.
- Das Fenster öffnet im Chrome-App-Modus: kein Tab, keine Adressleiste,
  eigenes Taskbar-Symbol.

Dieselbe HTML-Datei läuft in beiden Welten: als veröffentlichtes Artifact mit
Live-Chat, oder lokal aus der Datendatei (dann ohne Chat, mit Link darauf).
Deshalb gibt es nur eine Vorlage, die nicht auseinanderlaufen kann.

## Begleit-Chatfenster (Druckbett-Monitor)

`companion/druckbett-monitor.html` ist als Claude Artifact veröffentlicht —
zeigt die letzte Bridge-Analyse live an (liest `bridge/latest` aus der
Artifact-Datenbank) und hat einen Chat, der über die "sample"-Capability mit
deinem eigenen Claude-Konto spricht (kein separater API-Key, kein extra
Abo — läuft über dein bestehendes Claude-Nutzungskontingent, fragt beim
ersten Mal um Erlaubnis).

**Damit die Anzeige aktuell bleibt:** nach jedem `recommend`/`writeprofile`-
Lauf müssen die Ergebnisse per Claude Code in die Artifact-Datenbank
geschrieben werden (Collection `bridge`, Dokument `latest`) — das passiert
nicht automatisch durchs PowerShell-Skript selbst, sondern dadurch, dass
Claude (in diesem Chat) die Bridge laufen lässt und das Ergebnis weiterreicht.

`start-anycubic-mit-monitor.bat` startet Anycubic Slicer Next UND öffnet den
Druckbett-Monitor im Standardbrowser zusammen — anstelle der normalen
Anycubic-Verknüpfung benutzen. Einschränkung: greift nur über diese
Verknüpfung, nicht bei Doppelklick auf eine `.3mf`-Datei.

## Sicherheitsmodell

- `analyze`/`recommend`/`listprofiles`/`status` lesen nur.
- `writeprofile` ohne `-Force` ist Trockenlauf.
- `writeprofile -Force` schreibt NUR neue Dateien in `user\default\process\`,
  ruehrt nichts sonst an. Keine Aktivierung (siehe oben).
