# Änderungen

## 0.2.0 — 05.09.2026

**Erkennt jetzt, was wirklich auf dem Druckbett liegt.**

- Quelle ist das Live-Projekt des Slicers unter
  `%TEMP%\anycubicslicer_model\<zeit>#<pid>#<n>\.3mf` statt der zuletzt
  geänderten Datei auf dem Desktop. Vorher klebte ein Modell dauerhaft fest,
  und Modelle aus anderen Ordnern kamen nie an.
- Liegt nichts auf dem Bett, steht das jetzt auch so da.
- Mehrere Objekte auf dem Bett werden zusammen ausgewertet.

**Der Chat kann Einstellungen setzen, nicht nur erklären.**

- `writeprofile` nimmt mit `-Values` auch vorgegebene Werte statt nur der
  automatischen Empfehlung.
- Der Chat kann eine Aktion vorschlagen; das Fenster fragt nach und schreibt
  erst nach Bestätigung. Vorhandene Profile bleiben unangetastet.

**Chat läuft im Fenster.**

- Beantwortet von Claude Code auf dem eigenen Rechner — kein Login im
  Programm, kein API-Schlüssel, keine Zugangsdaten in diesem Werkzeug.
- Die Installation prüft, ob Claude Code da und angemeldet ist, und erklärt
  vorher, welche Daten wohin gehen.

**Behoben**

- Die Anzeige aktualisierte sich nicht: Daten kamen über `file://` aus dem
  Zwischenspeicher von WebView2, auch beim Neuladen — nur ein Neustart half.
  Jetzt reicht das Programm die Daten aktiv in die Seite.
- Der Chat blieb bei „Denkt nach…" hängen: Ausgabe und Fehlerkanal wurden
  nacheinander gelesen, wodurch sich beide Seiten blockierten.
- „Aktualisieren" zeichnete nur neu, statt neu zu messen.
- Der Installer legte keine Verknüpfungen an (Programm wurde am falschen Ort
  gesucht).
- Das Programmsymbol wurde aus dem gerade geladenen Modell erzeugt und änderte
  sich dadurch bei jedem Bauen. Jetzt ein festes Logo.

## 0.1.0 — 04.09.2026

Erste Version.

- Geometrie-Analyse für STL und 3MF, ohne Fremdbibliotheken
- Selbst gerenderte Modellvorschau
- Einstellungs-Empfehlungen mit Begründung, auf Wunsch als Profil geschrieben
- Echte Druckdauer, Filament und Kosten aus dem exportierten G-Code
- Flache Konturen zu druckbaren Körpern extrudieren
- Zwei Objekte verbinden und per Filamentwechsel (M600) zweifarbig drucken
- Eigenes Fenster mit WebView2, gebaut mit dem Windows-eigenen C#-Compiler
