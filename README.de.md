# Anycubic Bridge

Ein Begleitfenster für **Anycubic Slicer Next**, das sieht was wirklich auf dem
Druckbett liegt, sagt welche Einstellungen es ändern würde und warum — und die
Werte auf Wunsch selbst in den Slicer schreibt.

Dazu zwei Dinge, die der Slicer selbst nicht kann:

- **Zwei Modelle verbinden und zweifarbig drucken** mit nur einem Extruder,
  indem der Filamentwechsel genau an der richtigen Schicht gesetzt wird.
- **Flache Konturen extrudieren** — ein Schriftzug ohne Dicke wird zu einem
  echten druckbaren Körper.

Alles läuft lokal: es liest Dateien auf deinem Rechner und schreibt Dateien auf
deinen Rechner.

*English version: [README.md](README.md)*

![Das Fenster](docs/screenshot.png)

---

## Neu in 0.2.0

- **Es folgt dem Druckbett live.** Modell laden, tauschen oder runternehmen —
  das Fenster zieht binnen Sekunden nach, ohne Klick und ohne Neustart. Vorher
  wurde die zuletzt geänderte Datei auf dem Desktop geraten, dadurch klebte ein
  Modell dauerhaft fest.
- **Der Chat kann Einstellungen wirklich setzen.** Bitte ihn darum, und er
  schreibt ein Profil in den Slicer — nach Rückfrage. Vorher konnte er nur
  erklären, was du selbst eintragen sollst.
- **Der Chat läuft im Fenster**, beantwortet von
  [Claude Code](https://claude.com/claude-code) auf deinem eigenen Rechner.
  Kein Login im Programm, kein API-Schlüssel.
- **Nichts auf dem Bett heißt jetzt auch „nichts"** statt einer Karteileiche.

---

## Das Fenster

- Vorschau, gerendert aus dem Modell das **gerade** auf dem Bett liegt (das in
  3MF eingebettete Vorschaubild ist oft leer, deshalb zeichnet es selbst)
- Druckdauer, Filament in Gramm, Materialkosten und Schichtzahl — aus dem
  exportierten G-Code gelesen, nie geschätzt
- Die empfohlenen Einstellungen, jede mit ihrem Grund
- Ein Chat, der das alles kennt und es auch anwenden kann

## Installation

Voraussetzungen: Windows, Anycubic Slicer Next und die
[WebView2-Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
(auf den meisten Windows-11-Rechnern schon vorhanden).

1. [Neueste Version](../../releases/latest) herunterladen und entpacken
2. Installer starten:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Er legt die Anzeige an, erzeugt die ersten Daten, richtet auf Wunsch den Chat
ein und erstellt zwei Verknüpfungen — eine startet Slicer und Fenster zusammen,
eine nur das Fenster.

## Chat (optional)

Fragen zum Teil direkt im Fenster — *warum ist Support an? was ändert sich bei
0,3 mm? setz die Werte.* Die Installation richtet das ein und erklärt es; hier
dasselbe schriftlich, weil man vor einer Installation wissen sollte, worauf man
sich einlässt:

**Wie es läuft:** Die Frage geht zusammen mit den Dashboard-Daten (Modellname,
Maße, Überhänge, gesetzte Werte samt Begründung) an Claude Code, das **auf
deinem eigenen Rechner** läuft. Claude Code schickt das an Anthropic und gibt
die Antwort zurück ins Fenster.

**Was das konkret heißt:**

- Frage und Modelldaten gehen an Anthropic. Die Modelldateien selbst werden
  **nicht** hochgeladen.
- Es läuft über **dein** Claude-Konto und dein Kontingent.
- Dieses Werkzeug speichert **keinen Schlüssel und kein Passwort**. Die
  Anmeldung gehört Claude Code, nicht diesem Programm.
- Ohne Chat funktioniert alles andere weiter — die Anzeige läuft offline.

**Werte übernehmen:** Bittest du den Chat, Werte zu setzen, fragt das Fenster
erst nach und schreibt dann ein **neues** Profil in Anycubic Slicer Next.
Vorhandene Profile werden nie verändert, und ausgewählt wird das neue Profil im
Slicer weiterhin von dir.

Chat überspringen: `.\install.ps1 -OhneChat`

## Auf der Kommandozeile

Das Fenster sitzt auf `anycubic-bridge.ps1`, das auch allein läuft:

```powershell
.\anycubic-bridge.ps1 status         # Drucker, Filament, was auf dem Bett liegt
.\anycubic-bridge.ps1 analyze        # Größe, Volumen, Überhänge
.\anycubic-bridge.ps1 recommend      # Vorschläge mit Begründung
.\anycubic-bridge.ps1 watch          # hält die Daten des Fensters aktuell
.\anycubic-bridge.ps1 writeprofile -ProfileName "Mein Profil" -Force
.\anycubic-bridge.ps1 writeprofile -ProfileName "Eigen" -Values "brim_type=outer_only;enable_support=1" -Force
```

### Zweifarbig mit einem Extruder

```powershell
# flache Kontur -> echter Körper
.\anycubic-bridge.ps1 extrude -ModelPath "schrift.3mf" -Thickness 1.0 -OutFile "schrift-3d.3mf"

# aufsetzen - sucht selbst eine ebene Fläche, auf der es ganz aufliegt
.\anycubic-bridge.ps1 merge -ModelPath "teil.3mf" -AddModel "schrift-3d.3mf" -OutFile "verbunden.3mf"
#   -> nennt dir die Höhe für den Farbwechsel

# vorher ansehen: was wird welche Farbe?
.\anycubic-bridge.ps1 preview -ModelPath "verbunden.3mf" -AtHeight 14.2 -OutFile vorschau.png

# in Anycubic Slicer Next slicen, dann:
.\anycubic-bridge.ps1 colorchange -GcodeFile "teil.gcode" -AtHeight 14.2 -OutFile "zweifarbig.gcode" -Force
```

**Wichtige Grenze:** Ein schichtbasierter Farbwechsel trennt nur, was in der
Höhe übereinander liegt. Ein erhabener Schriftzug auf der Oberseite geht. Ein
Schriftzug an einer senkrechten Seite nicht — dort enthält jede Schicht beides
gleichzeitig. Das bräuchte zwei Extruder.

## Selbst bauen

```powershell
cd widget
.\build.ps1
```

Kein .NET-SDK nötig: es kompiliert mit dem C#-Compiler, der in Windows
enthalten ist. Die WebView2-Bibliotheken holt der erste Build von NuGet — sie
gehören Microsoft und liegen deshalb nicht im Repo.

Zwei Prüfschalter, wenn etwas klemmt:

```powershell
.\Druckbett-Monitor.exe --chat-test "hallo"   # ist Claude Code erreichbar?
.\Druckbett-Monitor.exe --bridge-test          # Seite -> Programm -> Claude -> Seite
```

## Was es nicht tut

- Es schreibt nie in `AnycubicSlicerNext.conf`. Die Datei trägt eine
  MD5-Prüfsumme, deren Verfahren sich nicht sicher nachbilden ließ. Profile
  werden deshalb als neue Dateien angelegt und von Hand ausgewählt — eine
  funktionierende Konfiguration zu zerschießen ist die Bequemlichkeit nicht wert.
- Keine Druckerverbindung. Fortschritt, Temperaturen und Restzeit brauchen eine
  Verbindung zum Drucker; hier wird nur die Slicer-Seite gelesen.
- Keine automatische Rotation oder Anordnung auf dem Bett.
- Der Zweifarb-Ablauf ist am Rechner geprüft, aber **noch nie wirklich
  gedruckt** worden.

## Woher es weiß, was auf dem Bett liegt

Festgehalten, weil es alles andere als offensichtlich ist: Weder
`recent_projects` noch die neueste Datei auf der Platte sagen, was geladen ist.
Anycubic Slicer Next führt ein Live-Projekt unter
`%TEMP%\anycubicslicer_model\<zeit>#<prozess-id>#<n>\.3mf`. Deren
`3dmodel.model` verweist per `p:path` auf die geladenen Objekte, samt
Platzierung. Das ist die Quelle. Der `3D\Objects`-Ordner daneben behält auch
Objekte, die du längst entfernt hast — er allein taugt also nicht.

## Lizenz

MIT, siehe [LICENSE](LICENSE). WebView2 gehört Microsoft und hat eine eigene
Lizenz, die dem Release beiliegt.
