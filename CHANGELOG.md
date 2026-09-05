# Änderungen

## 0.2.1 — 05.09.2026

**Es liest jetzt wirklich, was im Modell steht.**

- 3MF-Dateien, die Anycubic Slicer Next selbst speichert, legen die Geometrie
  gar nicht in `3dmodel.model` ab, sondern in einem eigenen Eintrag, auf den
  per `p:path` verwiesen wird (3MF-Production-Erweiterung). Der wurde bisher
  übersehen — Ergebnis: „0 Dreiecke" und Maße von minus unendlich. Die
  Objekt-IDs stimmen zwischen beiden Dateien übrigens **nicht** überein
  (außen `id="2"`, innen `id="1"`); maßgeblich ist allein der Pfad.
- Dadurch wurden Überhänge nie erkannt. Bei der Deckenhalterung sind es
  11.450 Dreiecke mit 90° — also genau die Stellen, an denen ohne Stützen
  nichts hält.

**Das Druckbett wird direkt nach dem Laden erkannt.**

- Der Slicer schreibt seine Sitzungsdatei erst beim Speichern oder Schneiden,
  nicht beim Laden. Bis dahin gab es keine Quelle, und das Fenster meldete ein
  leeres Bett, obwohl ein Modell dalag. Jetzt springt der Fenstertitel ein, der
  es sofort weiß. Nennt er kein Projekt, bleibt es ehrlich bei „leer".

**Behoben**

- `slice` übergab dem Slicer das **unveränderte** Filamentprofil, obwohl es
  vorher eine angepasste Kopie geschrieben hatte. Alle Filamentwerte waren
  damit wirkungslos — zu erkennen nur daran, dass die Druckzeiten auf die
  Sekunde gleich blieben.
- Kühlungswerte (`slow_down_layer_time` und Lüfter) gehören bei OrcaSlicer ins
  Filament-, nicht ins Prozessprofil. Im Prozessprofil stehen sie zwar drin,
  wirken aber nicht.
- `merge` behauptete, es gebe keine ebene Auflagefläche, wenn die große Fläche
  **unterhalb** der Oberkante liegt (Deckenhalterung: oben vier kleine
  Erhebungen, die brauchbare Fläche 10 mm tiefer).
- `status` gab das Filament als rohen Array-Dump aus (`{0, , 0, ...}`). Die
  aktive Kombination steht in `anycubic_presets`, nicht in `presets.filaments`.
  Zeigt jetzt zusätzlich das aktive Prozessprofil.
- `build.ps1` beendet einen noch laufenden Watcher. Der lief auf der Kopie in
  `dist` und schrieb die Anzeigedaten im Sekundentakt mit dem alten Stand
  weiter — Änderungen wirkten dadurch folgenlos, obwohl sie längst drin waren.
- Der Chat forderte dazu auf, `anycubic-bridge.ps1 recommend` von Hand zu
  starten — eine Anweisung ins Leere, denn das Fenster ruft die Bridge selbst
  auf. Die Begrüßung wurde geschrieben, bevor die erste Messung eintraf, und
  danach nie ersetzt: oben stand längst das Modell, im Chat weiterhin „noch
  keine Analyse da". Ein laufendes Gespräch wird dabei nicht angetastet.
- Die Versionsnummer im Skript stand noch auf 0.1.0.

**Neu: `tests/pruefstand.ps1`**

26 Prüfungen, die jedes Verb mit echten Dateien anfahren und das Ergebnis
nachmessen. Drei der oben genannten Fehler sind erst dadurch aufgefallen — und
drei vermeintliche Fehler entpuppten sich als Fehler im Prüfstand selbst
(unverankertes Suchmuster, das auch auf `UeberhangDreiecke : 0` passte; nur die
ersten Zeilen des G-Codes gelesen, obwohl der Einstellungsblock am Ende steht;
die gemeinsame Anzeigedatei gelesen, die parallel der Watcher überschrieb).

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
