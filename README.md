# Anycubic Bridge

A companion window for **Anycubic Slicer Next** that reads your actual slicer
setup and the model on your plate — then tells you what it would change and why.

It also does two things the slicer itself can't:

- **Merge two models and print them in two colours** on a single-extruder
  printer, by inserting the filament change at exactly the right layer.
- **Extrude flat outlines** (a text exported without thickness) into a real
  printable solid.

Nothing is sent anywhere. It reads local files and writes local files.

*Deutsche Fassung: [README.de.md](README.de.md)*

---

## The window

A real desktop window — not a browser tab — that sits next to the slicer and
updates itself:

- Model preview, rendered from your mesh (the thumbnail embedded in a 3MF is
  often blank, so it draws its own)
- Print time, filament in grams, material cost and layer count — read from
  your exported G-code, never estimated
- The settings it recommends, each with the reason it recommends them

![The window](docs/screenshot.png)

## Install

Requirements: Windows, Anycubic Slicer Next, and the
[WebView2 runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
(already present on most Windows 11 machines).

1. Download the latest release and unpack it
2. Run `install.ps1`:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

That installs the display files, generates the first data set, and puts a
shortcut on your desktop which starts the slicer and the window together.

## Command line

The window is built on `anycubic-bridge.ps1`, which works on its own:

```powershell
.\anycubic-bridge.ps1 status         # which model, which printer, which filament
.\anycubic-bridge.ps1 analyze        # size, volume, overhangs
.\anycubic-bridge.ps1 recommend      # suggested settings with reasons
.\anycubic-bridge.ps1 writeprofile -ProfileName "My profile" -Force
.\anycubic-bridge.ps1 watch          # keeps the window's data current
```

### Two colours on one extruder

```powershell
# flat outline -> real solid
.\anycubic-bridge.ps1 extrude -ModelPath "text.3mf" -Thickness 1.0 -OutFile "text-3d.3mf"

# place it on the base part; finds a flat surface it fully rests on
.\anycubic-bridge.ps1 merge -ModelPath "part.3mf" -AddModel "text-3d.3mf" -OutFile "combined.3mf"
#   -> prints the height you need for the colour change

# see which part gets which colour before printing
.\anycubic-bridge.ps1 preview -ModelPath "combined.3mf" -AtHeight 14.2 -OutFile preview.png

# slice in Anycubic Slicer Next, then insert the filament change
.\anycubic-bridge.ps1 colorchange -GcodeFile "part.gcode" -AtHeight 14.2 -OutFile "twocolour.gcode" -Force
```

**Limitation worth knowing:** a layer-based colour change only separates parts
that are stacked in Z. Lettering raised on a top surface works. Lettering on a
vertical side does not — every layer there contains both parts at once. That
needs two extruders.

## Chat (optional)

You can ask questions about the part right in the window — *why is support on?
what changes at 0.3 mm?* The installer sets this up and explains it; here is
the same information in writing, because you should know what you are agreeing
to before you install anything.

**How it works.** Your question is handed, together with the dashboard data
(model name, dimensions, overhangs, the settings and their reasons), to
[Claude Code](https://claude.com/claude-code) running **on your own machine**.
Claude Code sends that to Anthropic and returns the answer to the window.

**What that means concretely:**

- Your question and the model data go to Anthropic. Your model files
  themselves are never uploaded.
- It runs on **your** Claude account and your own usage allowance.
- This tool stores **no key and no password**. The login belongs to Claude
  Code, not to this widget — it is not passed through here.
- Skip it and everything else still works. The dashboard runs entirely offline.

**Setup.** The installer checks whether Claude Code is present, offers to
install it (`npm i -g @anthropic-ai/claude-code`), and checks whether you are
signed in by actually asking it a question. Signing in is Claude Code's own
browser flow: it opens your browser, you confirm with your Claude account,
done. No password is typed into this tool.

To skip the chat entirely:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -OhneChat
```

**Alternative: chat in the browser.** If you would rather not install Claude
Code, you can publish `companion/druckbett-monitor.html` as your own Claude
artifact (it needs the `db` and `sample` capabilities) and point the installer
at it with `-ChatUrl "https://claude.ai/code/artifact/<your-id>"`. That opens
in a browser instead of the window.

## Build it yourself

```powershell
cd widget
.\build.ps1
```

No .NET SDK needed: it compiles with the C# compiler that ships with Windows.
The WebView2 libraries are fetched from NuGet on first build (they belong to
Microsoft and are not committed here).

## What it does not do

- It never writes to `AnycubicSlicerNext.conf`. That file carries an MD5
  trailer whose algorithm could not be reproduced reliably, so profiles are
  written as new files and selected by hand — corrupting a working config is
  not worth the convenience.
- No printer connection. Progress, temperatures and ETA need a link to the
  printer; this reads the slicer side only.
- No automatic rotation or plate arrangement.

## Licence

MIT, see [LICENSE](LICENSE). WebView2 is Microsoft's and carries its own
licence, included with the release.
