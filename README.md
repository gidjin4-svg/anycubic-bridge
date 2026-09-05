# Anycubic Bridge

A companion window for **Anycubic Slicer Next** that sees what is actually on
your print bed, tells you which settings it would change and why — and can
write those settings into the slicer for you.

It also does two things the slicer itself cannot:

- **Merge two models and print them in two colours** on a single-extruder
  printer, by inserting the filament change at exactly the right layer.
- **Extrude flat outlines** — a text exported without thickness — into a real
  printable solid.

Everything runs locally. It reads local files and writes local files.

*Deutsche Fassung: [README.de.md](README.de.md)*

![The window](docs/screenshot.png)

---

## What's new in 0.2.0

- **It follows your plate live.** Load, swap or remove a model in the slicer
  and the window follows within seconds — no clicking, no restart. Earlier
  versions guessed from the most recently changed file on your desktop, which
  meant one model got stuck on screen forever.
- **The chat can actually change settings.** Ask it to apply values and it
  writes a profile into the slicer — after asking you first. It used to only
  explain what you should type in yourself.
- **The chat runs in the window**, answered by [Claude Code](https://claude.com/claude-code)
  on your own machine. No login inside the app, no API key.
- **Nothing on the bed now shows as nothing**, instead of a leftover model.

---

## The window

- Model preview, rendered from the mesh currently on the plate (the thumbnail
  embedded in a 3MF is often blank, so it draws its own)
- Print time, filament in grams, material cost and layer count — read from
  your exported G-code, never estimated
- The settings it recommends, each with the reason
- A chat that knows all of the above and can apply it

## Install

Requirements: Windows, Anycubic Slicer Next, and the
[WebView2 runtime](https://developer.microsoft.com/microsoft-edge/webview2/)
(already present on most Windows 11 machines).

1. Download the [latest release](../../releases/latest) and unpack it
2. Run the installer:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

It installs the display files, generates the first data set, checks the chat
setup (see below) and puts two shortcuts on your desktop — one starts the
slicer and the window together, one opens just the window.

## Chat (optional)

Ask about the part right in the window — *why is support on? what changes at
0.3 mm? apply those values.* The installer sets this up and explains it; the
same in writing, because you should know what you are agreeing to:

**How it works.** Your question is handed, together with the dashboard data
(model name, dimensions, overhangs, the settings and their reasons), to
Claude Code running **on your own machine**. Claude Code sends that to
Anthropic and returns the answer to the window.

**What that means concretely:**

- Your question and the model data go to Anthropic. Your model files
  themselves are never uploaded.
- It runs on **your** Claude account and your own usage allowance.
- This tool stores **no key and no password**. The login belongs to Claude
  Code, not to this widget.
- Skip it and everything else still works — the dashboard runs offline.

**Applying settings.** If you ask it to set values, the window asks you to
confirm first, then writes a **new** profile into Anycubic Slicer Next.
Existing profiles are never modified, and you still pick the new profile in
the slicer yourself.

To skip the chat: `.\install.ps1 -OhneChat`

## Command line

The window is built on `anycubic-bridge.ps1`, which works on its own:

```powershell
.\anycubic-bridge.ps1 status         # printer, filament, what is on the plate
.\anycubic-bridge.ps1 analyze        # size, volume, overhangs
.\anycubic-bridge.ps1 recommend      # suggested settings with reasons
.\anycubic-bridge.ps1 watch          # keeps the window's data current
.\anycubic-bridge.ps1 writeprofile -ProfileName "My profile" -Force
.\anycubic-bridge.ps1 writeprofile -ProfileName "Custom" -Values "brim_type=outer_only;enable_support=1" -Force
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
stacked in Z. Lettering raised on a top surface works. Lettering on a vertical
side does not — every layer there contains both parts at once. That needs two
extruders.

## Build it yourself

```powershell
cd widget
.\build.ps1
```

No .NET SDK needed: it compiles with the C# compiler that ships with Windows.
The WebView2 libraries are fetched from NuGet on first build (they belong to
Microsoft and are not committed here).

Two switches help when something misbehaves:

```powershell
.\Druckbett-Monitor.exe --chat-test "hello"   # is Claude Code reachable?
.\Druckbett-Monitor.exe --bridge-test          # page -> app -> Claude -> page
```

## What it does not do

- It never writes to `AnycubicSlicerNext.conf`. That file carries an MD5
  trailer whose algorithm could not be reproduced reliably, so profiles are
  written as new files and selected by hand — corrupting a working config is
  not worth the convenience.
- No printer connection. Progress, temperatures and ETA need a link to the
  printer; this reads the slicer side only.
- No automatic rotation or plate arrangement.
- The two-colour workflow has been verified on screen but **not yet on a real
  print**.

## How it knows what is on the plate

Worth writing down, because it is not obvious: neither `recent_projects` nor
the newest file on disk tells you what is loaded. Anycubic Slicer Next keeps a
live project under
`%TEMP%\anycubicslicer_model\<time>#<pid>#<n>\.3mf`, whose `3dmodel.model`
references the loaded objects by `p:path`, with their placement. That is the
source this tool reads. The `3D\Objects` folder next to it also keeps objects
you already removed, so it is not a valid source on its own.

## Licence

MIT, see [LICENSE](LICENSE). WebView2 is Microsoft's and carries its own
licence, included with the release.
