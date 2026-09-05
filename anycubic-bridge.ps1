<#
=====================================================================
 Anycubic Bridge - lokale AI <-> Anycubic Slicer Next Bruecke fuer Windows
---------------------------------------------------------------------
 Gleiches Prinzip wie die Cura Bridge (dateibasiert, kein COM/Live-Prozess-
 Zugriff), aber fuer Anycubic Slicer Next statt Cura. Die Geometrie-Analyse
 (STL/3MF) ist identisch zur Cura Bridge - Slicer-unabhaengig, unveraendert
 uebernommen.

 WICHTIGE EINSCHRAENKUNG (bewusst, nicht "vergessen"): Anycubic Slicer Next
 speichert seine Haupt-Konfiguration (AnycubicSlicerNext.conf) als JSON PLUS
 einer angehaengten "# MD5 checksum <hash>"-Zeile. Der genaue Checksummen-
 Algorithmus konnte nicht sicher reproduziert werden (mehrere Varianten
 getestet, keine passte) - deshalb schreibt diese Bruecke NIEMALS in diese
 Datei. Neue Profile landen ausschliesslich in user\default\process\ (dort
 gibt es keine Pruefsumme). Das heisst: kein "writeprofile setzt automatisch
 aktiv" wie bei Cura - neue Profile erscheinen im Process-Dropdown, muessen
 aber manuell ausgewaehlt werden.

 Beispiele:
   .\anycubic-bridge.ps1 about
   .\anycubic-bridge.ps1 status
   .\anycubic-bridge.ps1 listprofiles
   .\anycubic-bridge.ps1 analyze
   .\anycubic-bridge.ps1 analyze -ModelPath "C:\Pfad\Teil.stl"
   .\anycubic-bridge.ps1 recommend
   .\anycubic-bridge.ps1 writeprofile -ProfileName "Claude Tuergriff"
   .\anycubic-bridge.ps1 writeprofile -ProfileName "Claude Tuergriff" -Force
=====================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('about', 'status', 'listprofiles', 'analyze', 'recommend', 'writeprofile', 'preview', 'dashboard', 'watch', 'colorchange', 'extrude', 'merge', 'slice')]
    [string]$Action,

    [string]$ModelPath,
    [string]$MachinePreset,
    [string]$ProfileName,
    # Bestimmte Werte statt der automatischen Empfehlung, z. B.
    # -Values "brim_type=outer_only;enable_support=1;sparse_infill_density=25%"
    [string]$Values,
    [string]$OutFile,
    [string]$GcodeFile,
    [string]$AddModel,
    [double]$Thickness,
    [double]$OffsetX,
    [double]$OffsetY,
    [double]$OffsetZ,
    [double]$AtHeight,
    [int]$PreviewSize = 320,
    [double]$LayerHeight = 0.2,
    [string]$ColorChangeCommand = 'M600',
    [double]$OverhangThreshold = 55,
    [int]$IntervalSeconds = 10,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$AnycubicBridgeName = 'Anycubic Bridge'
$AnycubicBridgeVersion = '0.2.1'
$AnycubicBridgeWatermark = 'AnycubicBridge'

# --------------------------------------------------------------------
# Anycubic-Konfiguration
# --------------------------------------------------------------------

function Get-AnycubicConfigRoot {
    $base = Join-Path $env:APPDATA 'AnycubicSlicerNext'
    if (-not (Test-Path -LiteralPath $base)) { throw "Anycubic-Slicer-Next-Konfigurationsordner nicht gefunden: $base [$AnycubicBridgeWatermark]" }
    return $base
}

function Get-AnycubicInstallRoot {
    $path = Join-Path $env:ProgramFiles 'AnycubicSlicerNext'
    if (-not (Test-Path -LiteralPath $path)) { throw "Anycubic Slicer Next Installationsordner nicht gefunden: $path [$AnycubicBridgeWatermark]" }
    return $path
}

# Liest die Haupt-Konfig (JSON + angehaengter "# MD5 checksum"-Zeile). NUR LESEN -
# diese Datei wird von dieser Bruecke nie beschrieben (siehe Kopfkommentar).
function Read-AnycubicMainConf {
    param([string]$ConfigRoot)
    $path = Join-Path $ConfigRoot 'AnycubicSlicerNext.conf'
    if (-not (Test-Path -LiteralPath $path)) { throw "AnycubicSlicerNext.conf nicht gefunden: $path [$AnycubicBridgeWatermark]" }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $idx = $text.IndexOf("`n# MD5 checksum")
    if ($idx -ge 0) { $text = $text.Substring(0, $idx) }
    return $text | ConvertFrom-Json
}

function Get-AnycubicSessionDir {
    <#
      Der Sitzungsordner der LAUFENDEN Slicer-Instanz. Er heisst
      <zeit>#<prozess-id>#<n> und liegt unter %TEMP%\anycubicslicer_model.
      Ohne laufenden Slicer gibt es keinen.
    #>
    $proc = Get-Process -Name '*AnycubicSlicerNext*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return $null }

    $root = Join-Path $env:TEMP 'anycubicslicer_model'
    if (-not (Test-Path -LiteralPath $root)) { return $null }

    return Get-ChildItem -LiteralPath $root -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*#$($proc.Id)#*" } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-AnycubicActiveCombo {
    <#
      Die aktive Kombination aus Drucker, Filament und Prozessprofil.

      Wichtig: NICHT aus presets.filaments lesen - das ist eine Restehalde aus
      Nullen und Leerstrings und ergibt in der Anzeige nur "{0, , 0, ...}".
      Massgeblich ist der Eintrag in anycubic_presets, dessen machine zum
      aktiven Drucker (presets.machine) passt.
    #>
    param($MainConf)

    $maschine = [string]$MainConf.presets.machine
    $treffer = $null
    if ($MainConf.anycubic_presets) {
        $treffer = $MainConf.anycubic_presets |
            Where-Object { [string]$_.machine -eq $maschine } | Select-Object -First 1
    }
    return [pscustomobject]@{
        Maschine = $(if ($maschine) { $maschine } else { '(unbekannt)' })
        Filament = $(if ($treffer -and $treffer.filament) { [string]$treffer.filament } else { '(unbekannt)' })
        Prozess  = $(if ($treffer -and $treffer.process) { [string]$treffer.process } else { '(unbekannt)' })
    }
}

function Get-AnycubicOpenProjectName {
    <#
      Der Fenstertitel nennt das geladene Projekt sofort - lange bevor der
      Slicer seine Sitzungsdatei schreibt (die entsteht erst beim Speichern
      oder Schneiden, nicht beim Laden). Format: "<Projekt>(Modus)", davor
      ein "*" wenn ungespeichert. Ohne Projekt steht dort nur der Programmname.
      Rueckgabe: Projektname oder $null.
    #>
    $proc = Get-Process -Name '*AnycubicSlicerNext*' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle } | Select-Object -First 1
    if (-not $proc) { return $null }

    $titel = $proc.MainWindowTitle
    # Der Klammerzusatz kommt je nach Sprachpaket mit normalen oder mit
    # fernoestlichen Vollbreiten-Klammern.
    $i = $titel.IndexOfAny([char[]]@('(', [char]0xFF08))
    if ($i -gt 0) { $titel = $titel.Substring(0, $i) }
    $titel = $titel.Trim().TrimStart('*').Trim()

    if (-not $titel) { return $null }
    if ($titel -eq 'AnycubicSlicerNext') { return $null }
    return $titel
}

function Resolve-AnycubicProjectFile {
    <#
      Sucht zu einem Projektnamen aus dem Fenstertitel die zugehoerige Datei:
      erst unter den zuletzt geoeffneten Projekten, dann in deren Ordnern,
      zuletzt im Desktop. Rueckgabe: Pfad oder $null.
    #>
    param($MainConf, [string]$Name)
    if (-not $Name) { return $null }

    $ordner = New-Object System.Collections.Generic.List[string]
    if ($MainConf -and $MainConf.recent_projects) {
        foreach ($k in ($MainConf.recent_projects.PSObject.Properties.Name | Sort-Object)) {
            $p = $MainConf.recent_projects.$k
            if (-not $p) { continue }
            if ((Test-Path -LiteralPath $p) -and
                ([System.IO.Path]::GetFileNameWithoutExtension($p) -eq $Name)) {
                return (Resolve-Path -LiteralPath $p).Path
            }
            $d = [System.IO.Path]::GetDirectoryName($p)
            if ($d) { $ordner.Add($d) }
        }
    }
    if ($MainConf -and $MainConf.recent -and $MainConf.recent.last_opened_folder) {
        $ordner.Add([string]$MainConf.recent.last_opened_folder)
    }
    $ordner.Add([Environment]::GetFolderPath('Desktop'))

    foreach ($d in ($ordner | Select-Object -Unique)) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        foreach ($ext in @('.3mf', '.stl')) {
            $kandidat = Join-Path $d ($Name + $ext)
            if (Test-Path -LiteralPath $kandidat) { return (Resolve-Path -LiteralPath $kandidat).Path }
        }
    }
    return $null
}

function Get-AnycubicPlate {
    <#
      Was JETZT auf dem Druckbett liegt - nicht was zuletzt geoeffnet wurde.

      Der Slicer haelt den aktuellen Bett-Zustand in einer .3mf im
      Sitzungsordner. Deren 3dmodel.model verweist per p:path auf die
      Objektdateien. Wichtig: der Objects-Ordner SAMMELT auch entfernte
      Objekte - massgeblich ist allein diese Liste.

      Rueckgabe: Liste aus Pfad + Transformation, oder leere Liste wenn nichts
      geladen ist.
    #>
    $sess = Get-AnycubicSessionDir
    $result = New-Object System.Collections.Generic.List[object]
    if (-not $sess) { return $result }

    $plate = Join-Path $sess.FullName '.3mf'
    if (-not (Test-Path -LiteralPath $plate)) {
        # Direkt nach dem Laden gibt es die Bett-Datei noch nicht - der Slicer
        # schreibt sie erst bei der ersten Aenderung. Solange nehmen wir die
        # Objektdateien der Sitzung. Das ist hier unbedenklich: ohne Bett-Datei
        # wurde in dieser Sitzung auch noch nichts wieder entfernt.
        $objDir = Join-Path $sess.FullName '3D\Objects'
        if (Test-Path -LiteralPath $objDir) {
            foreach ($f in (Get-ChildItem -LiteralPath $objDir -Filter '*.model' -File | Sort-Object LastWriteTime)) {
                $result.Add([pscustomobject]@{
                    File      = $f.FullName
                    Name      = ($f.Name -replace '_\d+\.model$', '')
                    Transform = $null
                })
            }
        }
        if ($result.Count -gt 0) { return $result }

        # Auch die Objektdateien fehlen. Das ist der Normalfall direkt nach dem
        # Laden: der Slicer legt beides erst beim Speichern oder Schneiden an.
        # Der Fenstertitel weiss es aber sofort - darueber die Datei suchen.
        # Bleibt ehrlich: nennt der Titel kein Projekt, ist das Bett wirklich
        # leer, und es wird nichts geraten.
        $offen = Get-AnycubicOpenProjectName
        if ($offen) {
            $conf = $null
            try { $conf = Read-AnycubicMainConf -ConfigRoot (Get-AnycubicConfigRoot) } catch { }
            $datei = Resolve-AnycubicProjectFile -MainConf $conf -Name $offen
            if ($datei) {
                $result.Add([pscustomobject]@{ File = $datei; Name = $offen; Transform = $null })
            }
        }
        return $result
    }

    $xml = $null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($plate)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -match '3dmodel\.model$' } | Select-Object -First 1
        if (-not $entry) { return $result }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        $xml = $reader.ReadToEnd()
        $reader.Close()
    } finally {
        $zip.Dispose()
    }

    # Objekt-Id -> Datei (die Bauteile stehen in eigenen Dateien daneben)
    $pathById = @{}
    foreach ($m in [regex]::Matches($xml, '<object[^>]*id="(\d+)"[^>]*>(.*?)</object>', 'Singleline')) {
        $objId = $m.Groups[1].Value
        $comp = [regex]::Match($m.Groups[2].Value, 'p:path="([^"]+)"')
        if ($comp.Success) { $pathById[$objId] = $comp.Groups[1].Value }
    }

    foreach ($m in [regex]::Matches($xml, '<item[^>]*objectid="(\d+)"[^>]*/>')) {
        $tag = $m.Value
        $objId = $m.Groups[1].Value
        if ($tag -match 'printable="0"') { continue }
        if (-not $pathById.ContainsKey($objId)) { continue }

        $rel = $pathById[$objId].TrimStart('/')
        $file = Join-Path $sess.FullName ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $file)) { continue }

        $transform = $null
        $tm = [regex]::Match($tag, 'transform="([^"]+)"')
        if ($tm.Success) {
            $parts = @($tm.Groups[1].Value -split '\s+' | ForEach-Object { [double]$_ })
            if ($parts.Count -eq 12) { $transform = $parts }
        }

        $result.Add([pscustomobject]@{
            File      = $file
            Name      = ([System.IO.Path]::GetFileName($file) -replace '_\d+\.model$', '')
            Transform = $transform
        })
    }
    return $result
}

function Get-AnycubicPlateTriangles {
    param($Plate)
    $all = New-Object System.Collections.Generic.List[object]
    foreach ($obj in $Plate) {
        $tris = Get-AnycubicMeshTriangles -Path $obj.File
        foreach ($t in $tris) {
            if ($obj.Transform) {
                $p1 = Convert-AnycubicMfPoint -P $t[0] -T $obj.Transform
                $p2 = Convert-AnycubicMfPoint -P $t[1] -T $obj.Transform
                $p3 = Convert-AnycubicMfPoint -P $t[2] -T $obj.Transform
                $tri = New-Object 'object[]' 3
                $tri[0] = $p1; $tri[1] = $p2; $tri[2] = $p3
                $all.Add($tri)
            } else {
                $all.Add($t)
            }
        }
    }
    return $all
}

function Get-AnycubicActiveModelPath {
    param($MainConf)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($MainConf.recent_projects) {
        $keys = $MainConf.recent_projects.PSObject.Properties.Name | Sort-Object
        foreach ($k in $keys) { $candidates.Add($MainConf.recent_projects.$k) }
    }
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
    }
    $fallbackDir = $MainConf.recent.last_opened_folder
    if ([string]::IsNullOrWhiteSpace($fallbackDir)) { $fallbackDir = [Environment]::GetFolderPath('Desktop') }
    if (Test-Path -LiteralPath $fallbackDir) {
        $fallback = Get-ChildItem -LiteralPath $fallbackDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.3mf', '.stl' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($fallback) { return $fallback.FullName }
    }
    return $null
}

function Write-AnycubicBridgeTextFile {
    param([string]$Path, [string]$Text)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

# --------------------------------------------------------------------
# Geometrie-Analyse (identisch zur Cura Bridge - Slicer-unabhaengig)
# --------------------------------------------------------------------

function Get-AnycubicMeshFromStl {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $isAscii = $false
    if ($bytes.Length -ge 84) {
        $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 5)
        if ($head -eq 'solid') {
            $declaredTriCount = [System.BitConverter]::ToUInt32($bytes, 80)
            $expectedBinarySize = 84 + ($declaredTriCount * 50)
            if ($bytes.Length -ne $expectedBinarySize) { $isAscii = $true }
        }
    } else {
        $isAscii = $true
    }

    $triangles = New-Object System.Collections.Generic.List[object]
    if ($isAscii) {
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $vertexMatches = [regex]::Matches($text, 'vertex\s+([\-\d\.eE]+)\s+([\-\d\.eE]+)\s+([\-\d\.eE]+)')
        $verts = New-Object System.Collections.Generic.List[object]
        foreach ($m in $vertexMatches) {
            $verts.Add(@([double]$m.Groups[1].Value, [double]$m.Groups[2].Value, [double]$m.Groups[3].Value))
        }
        for ($i = 0; $i + 2 -lt $verts.Count; $i += 3) {
            $triangles.Add(@($verts[$i], $verts[$i + 1], $verts[$i + 2]))
        }
    } else {
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        $br = New-Object System.IO.BinaryReader($ms)
        [void]$br.ReadBytes(80)
        $triCount = $br.ReadUInt32()
        for ($i = 0; $i -lt $triCount; $i++) {
            [void]$br.ReadSingle(); [void]$br.ReadSingle(); [void]$br.ReadSingle()
            $v1 = @([double]$br.ReadSingle(), [double]$br.ReadSingle(), [double]$br.ReadSingle())
            $v2 = @([double]$br.ReadSingle(), [double]$br.ReadSingle(), [double]$br.ReadSingle())
            $v3 = @([double]$br.ReadSingle(), [double]$br.ReadSingle(), [double]$br.ReadSingle())
            [void]$br.ReadUInt16()
            $triangles.Add(@($v1, $v2, $v3))
        }
        $br.Close()
    }
    return $triangles
}

function Convert-AnycubicMfPoint {
    param([double[]]$P, [double[]]$T)
    $x = $P[0] * $T[0] + $P[1] * $T[3] + $P[2] * $T[6] + $T[9]
    $y = $P[0] * $T[1] + $P[1] * $T[4] + $P[2] * $T[7] + $T[10]
    $z = $P[0] * $T[2] + $P[1] * $T[5] + $P[2] * $T[8] + $T[11]
    return @($x, $y, $z)
}

function Get-AnycubicMeshFrom3mf {
    param([string]$Path)
    $externeTeile = @{}   # Eintragsname -> XML-Text der ausgelagerten Geometrie
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        # Normale 3MF-Dateien haben 3D/3dmodel.model. Die Sitzungsdateien des
        # Slicers heissen dagegen nach dem Objekt (3D/Objects/<Name>.model),
        # sind aber derselbe Aufbau - deshalb beides zulassen.
        $entry = $zip.Entries | Where-Object { $_.FullName -match '3dmodel\.model$' } | Select-Object -First 1
        if (-not $entry) {
            $entry = $zip.Entries | Where-Object { $_.FullName -match '\.model$' } | Select-Object -First 1
        }
        if (-not $entry) { throw "Keine Modelldaten in der Datei gefunden: $Path [$AnycubicBridgeWatermark]" }
        $stream = $entry.Open()
        $reader = New-Object System.IO.StreamReader($stream)
        $xmlText = $reader.ReadToEnd()
        $reader.Close(); $stream.Close()

        # 3MF-Production-Erweiterung: dann steht in 3dmodel.model nur noch ein
        # Verweis (p:path) auf einen eigenen Eintrag mit der Geometrie. Genau so
        # speichert Anycubic Slicer Next seine Projekte - ohne das hier kommt
        # ein leeres Modell heraus (0 Dreiecke, Masse -unendlich).
        # Achtung: die Objekt-IDs stimmen zwischen beiden Dateien NICHT ueberein
        # (aussen id="2", innen id="1"), die Zuordnung laeuft allein ueber den
        # Pfad. Deshalb pro Verweis merken statt IDs zusammenzuwerfen.
        foreach ($m in [regex]::Matches($xmlText, 'p:path\s*=\s*"([^"]+)"')) {
            $rel = $m.Groups[1].Value.TrimStart('/')
            if ($externeTeile.ContainsKey($rel)) { continue }
            $ref = $zip.Entries | Where-Object { $_.FullName -eq $rel } | Select-Object -First 1
            if (-not $ref) { continue }
            $s2 = $ref.Open()
            $r2 = New-Object System.IO.StreamReader($s2)
            $externeTeile[$rel] = $r2.ReadToEnd()
            $r2.Close(); $s2.Close()
        }
    } finally {
        $zip.Dispose()
    }

    [xml]$xml = $xmlText
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('m', 'http://schemas.microsoft.com/3dmanufacturing/core/2015/02')

    # Pro Objekt einlesen: die Dreiecks-Indizes beziehen sich immer auf die
    # Punktliste DES EIGENEN Objekts. Alles in einen Topf zu werfen erzeugt bei
    # Dateien mit mehreren Objekten wilden Unsinn.
    $objectNodes = $xml.SelectNodes('//m:resources/m:object', $ns)
    if ($objectNodes.Count -eq 0) { $objectNodes = $xml.SelectNodes('//resources/object') }

    $objects = @{}
    foreach ($obj in $objectNodes) {
        $id = [string]$obj.id
        $vNodes = $obj.SelectNodes('.//m:vertices/m:vertex', $ns)
        if ($vNodes.Count -eq 0) { $vNodes = $obj.SelectNodes('.//vertices/vertex') }
        $tNodes = $obj.SelectNodes('.//m:triangles/m:triangle', $ns)
        if ($tNodes.Count -eq 0) { $tNodes = $obj.SelectNodes('.//triangles/triangle') }

        # Leeres Objekt mit p:path: die Geometrie liegt im verwiesenen Eintrag.
        # Dessen eigene Objekt-ID ist eine andere - es zaehlt der Pfad, und die
        # Punkte werden unter der AEUSSEREN ID abgelegt, denn nur die steht im
        # <build>-Abschnitt.
        if ($vNodes.Count -eq 0) {
            $pfad = $obj.GetAttribute('path', 'http://schemas.microsoft.com/3dmanufacturing/production/2015/06')
            if ($pfad) { $pfad = $pfad.TrimStart('/') } else { $pfad = $null }
            # Notnagel: liegt genau ein ausgelagertes Teil vor, ist die
            # Zuordnung eindeutig, auch wenn das Attribut anders benannt ist.
            if (-not $pfad -and $externeTeile.Count -eq 1) {
                $pfad = @($externeTeile.Keys)[0]
            }
            if ($pfad -and $externeTeile.ContainsKey($pfad)) {
                [xml]$teil = $externeTeile[$pfad]
                $tns = New-Object System.Xml.XmlNamespaceManager($teil.NameTable)
                $tns.AddNamespace('m', 'http://schemas.microsoft.com/3dmanufacturing/core/2015/02')
                $inner = $teil.SelectNodes('//m:resources/m:object', $tns)
                if ($inner.Count -eq 0) { $inner = $teil.SelectNodes('//resources/object') }
                foreach ($io in $inner) {
                    $iv = $io.SelectNodes('.//m:vertices/m:vertex', $tns)
                    if ($iv.Count -eq 0) { $iv = $io.SelectNodes('.//vertices/vertex') }
                    if ($iv.Count -eq 0) { continue }
                    $it = $io.SelectNodes('.//m:triangles/m:triangle', $tns)
                    if ($it.Count -eq 0) { $it = $io.SelectNodes('.//triangles/triangle') }
                    $vNodes = $iv; $tNodes = $it
                    break
                }
            }
        }

        $verts = New-Object System.Collections.Generic.List[object]
        foreach ($v in $vNodes) {
            $p = New-Object 'object[]' 3
            $p[0] = [double]$v.x; $p[1] = [double]$v.y; $p[2] = [double]$v.z
            $verts.Add($p)
        }
        $objects[$id] = [pscustomobject]@{ Verts = $verts; Tris = $tNodes }
    }

    $itemNodes = $xml.SelectNodes('//m:build/m:item', $ns)
    if ($itemNodes.Count -eq 0) { $itemNodes = $xml.SelectNodes('//build/item') }

    # Objektdateien aus dem Sitzungsordner haben keinen <build>-Abschnitt - der
    # steht in der Bett-Datei, die auf sie verweist. Dann einfach alle Objekte
    # nehmen, die Platzierung kommt von aussen.
    $ohneBuild = ($itemNodes.Count -eq 0)

    $triangles = New-Object System.Collections.Generic.List[object]
    $quellen = if ($ohneBuild) { $objects.Keys } else { $itemNodes }

    foreach ($item in $quellen) {
        $oid = if ($ohneBuild) { [string]$item } else { [string]$item.objectid }
        if (-not $objects.ContainsKey($oid)) { continue }
        $o = $objects[$oid]

        $transform = $null
        if (-not $ohneBuild -and $item.transform) {
            $parts = @($item.transform -split '\s+' | ForEach-Object { [double]$_ })
            if ($parts.Count -eq 12) { $transform = $parts }
        }

        foreach ($t in $o.Tris) {
            $p1 = $o.Verts[[int]$t.v1]
            $p2 = $o.Verts[[int]$t.v2]
            $p3 = $o.Verts[[int]$t.v3]
            if ($transform) {
                $p1 = Convert-AnycubicMfPoint -P $p1 -T $transform
                $p2 = Convert-AnycubicMfPoint -P $p2 -T $transform
                $p3 = Convert-AnycubicMfPoint -P $p3 -T $transform
            }
            $tri = New-Object 'object[]' 3
            $tri[0] = $p1; $tri[1] = $p2; $tri[2] = $p3
            $triangles.Add($tri)
        }
    }
    return $triangles
}

function Get-AnycubicMeshTriangles {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        '.stl' { return Get-AnycubicMeshFromStl -Path $Path }
        '.3mf' { return Get-AnycubicMeshFrom3mf -Path $Path }
        # Die Objektdateien im Sitzungsordner des Slicers heissen .model, sind
        # aber derselbe Aufbau wie 3MF.
        '.model' { return Get-AnycubicMeshFrom3mf -Path $Path }
        default { throw "Nicht unterstuetztes Format: $ext (nur .stl/.3mf/.model). [$AnycubicBridgeWatermark]" }
    }
}

function Get-AnycubicMeshStats {
    param($Triangles, [double]$OverhangThreshold, [double]$BedTouchEpsilon = 0.05)

    $minX = [double]::MaxValue; $minY = [double]::MaxValue; $minZ = [double]::MaxValue
    $maxX = [double]::MinValue; $maxY = [double]::MinValue; $maxZ = [double]::MinValue
    foreach ($tri in $Triangles) {
        foreach ($v in $tri) {
            if ($v[0] -lt $minX) { $minX = $v[0] }; if ($v[0] -gt $maxX) { $maxX = $v[0] }
            if ($v[1] -lt $minY) { $minY = $v[1] }; if ($v[1] -gt $maxY) { $maxY = $v[1] }
            if ($v[2] -lt $minZ) { $minZ = $v[2] }; if ($v[2] -gt $maxZ) { $maxZ = $v[2] }
        }
    }

    $volumeSum = 0.0
    $overhangTriCount = 0
    $worstOverhangAngle = 0.0
    foreach ($tri in $Triangles) {
        $v1 = $tri[0]; $v2 = $tri[1]; $v3 = $tri[2]
        $volumeSum += ($v1[0] * ($v2[1] * $v3[2] - $v2[2] * $v3[1]) `
                     - $v1[1] * ($v2[0] * $v3[2] - $v2[2] * $v3[0]) `
                     + $v1[2] * ($v2[0] * $v3[1] - $v2[1] * $v3[0])) / 6.0

        $e1x = $v2[0] - $v1[0]; $e1y = $v2[1] - $v1[1]; $e1z = $v2[2] - $v1[2]
        $e2x = $v3[0] - $v1[0]; $e2y = $v3[1] - $v1[1]; $e2z = $v3[2] - $v1[2]
        $nx = $e1y * $e2z - $e1z * $e2y
        $ny = $e1z * $e2x - $e1x * $e2z
        $nz = $e1x * $e2y - $e1y * $e2x
        $len = [Math]::Sqrt($nx * $nx + $ny * $ny + $nz * $nz)
        if ($len -eq 0) { continue }
        $nz = $nz / $len

        if ($nz -lt -0.001) {
            $angleFromDown = [Math]::Acos([Math]::Min(1.0, [Math]::Max(-1.0, -$nz))) * 180.0 / [Math]::PI
            $overhangFromVertical = 90.0 - $angleFromDown
            $touchesBed = ($v1[2] -le ($minZ + $BedTouchEpsilon)) -and ($v2[2] -le ($minZ + $BedTouchEpsilon)) -and ($v3[2] -le ($minZ + $BedTouchEpsilon))
            if (-not $touchesBed) {
                if ($overhangFromVertical -gt $worstOverhangAngle) { $worstOverhangAngle = $overhangFromVertical }
                if ($overhangFromVertical -gt $OverhangThreshold) { $overhangTriCount++ }
            }
        }
    }

    $volumeMm3 = [Math]::Abs($volumeSum)
    [pscustomobject]@{
        Triangles         = $Triangles.Count
        WidthX_mm         = [Math]::Round($maxX - $minX, 2)
        DepthY_mm         = [Math]::Round($maxY - $minY, 2)
        HeightZ_mm        = [Math]::Round($maxZ - $minZ, 2)
        FootprintArea_cm2 = [Math]::Round((($maxX - $minX) * ($maxY - $minY)) / 100.0, 2)
        Volume_cm3        = [Math]::Round($volumeMm3 / 1000.0, 2)
        OverhangTriangles = $overhangTriCount
        WorstOverhangDeg  = [Math]::Round($worstOverhangAngle, 1)
        HasOverhang       = ($overhangTriCount -gt 0)
    }
}

# --------------------------------------------------------------------
# Profile (process = Druckeinstellungen, wie Curas quality_changes)
# --------------------------------------------------------------------

function Get-AnycubicProcessProfiles {
    param([string]$ConfigRoot)
    $dir = Join-Path $ConfigRoot 'user\default\process'
    $results = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $dir) {
        foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json') {
            $json = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $results.Add([pscustomobject]@{
                Name       = $json.name
                Inherits   = $json.inherits
                FilePath   = $file.FullName
                ValueCount = ($json.PSObject.Properties.Name | Where-Object { $_ -notin @('name','print_settings_id','inherits','from','is_custom_defined','version','type','instantiation','compatible_printers','compatible_printers_condition','filename_format') }).Count
            })
        }
    }
    return $results
}

function Find-AnycubicSystemProcessProfile {
    param([string]$ConfigRoot, [string]$Name)
    $dir = Join-Path $ConfigRoot 'system\Anycubic\process'
    $path = Join-Path $dir ($Name + '.json')
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Build-AnycubicProcessJson {
    param([string]$Name, [string]$Inherits, [string]$Version, $Values)
    $obj = [ordered]@{
        from               = 'User'
        is_custom_defined  = '0'
        inherits           = $Inherits
        name               = $Name
        print_settings_id  = $Name
        version            = $Version
    }
    foreach ($key in $Values.Keys) { $obj[$key] = [string]$Values[$key] }
    return ($obj | ConvertTo-Json -Depth 5)
}

function Find-AnycubicTemplateForMachine {
    param([string]$ConfigRoot, [string]$MachineName, $ExistingProfiles)

    if ($MachineName) {
        $matching = $ExistingProfiles | Where-Object { $_.Inherits -like "*@$MachineName*" } | Select-Object -First 1
        if ($matching) { return $matching }
    }

    if ($ExistingProfiles.Count -eq 0) { return $null }
    $fallback = $ExistingProfiles | Select-Object -First 1
    if (-not $MachineName) { return $fallback }

    $fallbackJson = Get-Content -LiteralPath $fallback.FilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($fallbackJson.inherits -notmatch '^(.*)@.*$') { return $fallback }
    $qualityPrefix = $Matches[1].TrimEnd()
    $candidateInherits = "$qualityPrefix @$MachineName"
    $candidateSystemPath = Join-Path (Join-Path $ConfigRoot 'system\Anycubic\process') ($candidateInherits + '.json')
    if (-not (Test-Path -LiteralPath $candidateSystemPath)) {
        throw "Kein Vorlagen-Profil fuer Maschine '$MachineName' gefunden (weder eigenes Profil noch System-Profil '$candidateInherits'). Bitte -MachinePreset angeben oder erst manuell ein Profil in Anycubic Slicer Next fuer diese Maschine anlegen. [$AnycubicBridgeWatermark]"
    }
    return [pscustomobject]@{
        Name     = $fallback.Name
        Inherits = $candidateInherits
        FilePath = $fallback.FilePath
    }
}

function Build-AnycubicInfoFile {
    param([string]$BaseId)
    $unixNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $lines = @(
        'sync_info = create',
        'user_id = ',
        'setting_id = ',
        "base_id = $BaseId",
        "updated_time = $unixNow"
    )
    return ($lines -join "`r`n") + "`r`n"
}

# --------------------------------------------------------------------
# Vorschaubild aus dem Mesh rendern
# --------------------------------------------------------------------
# Das in 3MF eingebettete Metadata/thumbnail.png ist bei Cura-Exporten oft
# unbrauchbar (leerer Viewport-Ausschnitt), deshalb rendern wir selbst:
# isometrische Projektion, Painter's Algorithm, einfaches Lambert-Shading.

function New-AnycubicPreviewPng {
    param($Triangles, [string]$OutPath, [int]$Size = 320, [double]$HighlightAboveZ = [double]::MaxValue)

    Add-Type -AssemblyName System.Drawing

    $cos30 = [Math]::Cos(30 * [Math]::PI / 180)
    $sin30 = [Math]::Sin(30 * [Math]::PI / 180)

    $faces = New-Object System.Collections.Generic.List[object]
    $minX = [double]::MaxValue; $maxX = [double]::MinValue
    $minY = [double]::MaxValue; $maxY = [double]::MinValue

    foreach ($t in $Triangles) {
        $px = New-Object 'double[]' 3
        $py = New-Object 'double[]' 3
        $depth = 0.0
        for ($i = 0; $i -lt 3; $i++) {
            $v = $t[$i]
            $px[$i] = ($v[0] - $v[1]) * $cos30
            $py[$i] = ($v[0] + $v[1]) * $sin30 - $v[2]
            $depth += $v[0] + $v[1] + $v[2]
            if ($px[$i] -lt $minX) { $minX = $px[$i] }; if ($px[$i] -gt $maxX) { $maxX = $px[$i] }
            if ($py[$i] -lt $minY) { $minY = $py[$i] }; if ($py[$i] -gt $maxY) { $maxY = $py[$i] }
        }

        $e1x = $t[1][0] - $t[0][0]; $e1y = $t[1][1] - $t[0][1]; $e1z = $t[1][2] - $t[0][2]
        $e2x = $t[2][0] - $t[0][0]; $e2y = $t[2][1] - $t[0][1]; $e2z = $t[2][2] - $t[0][2]
        $nx = $e1y * $e2z - $e1z * $e2y
        $ny = $e1z * $e2x - $e1x * $e2z
        $nz = $e1x * $e2y - $e1y * $e2x
        $len = [Math]::Sqrt($nx * $nx + $ny * $ny + $nz * $nz)
        if ($len -eq 0) { continue }

        # Zweite Farbe bekommt, was ECHT oberhalb der Wechselhoehe liegt. Auf
        # Hoehe der Grenze selbst liegt noch die Deckflaeche des Grundkoerpers -
        # die wird in der Schicht darunter gedruckt und bleibt Farbe 1.
        $maxTriZ = [Math]::Max($t[0][2], [Math]::Max($t[1][2], $t[2][2]))
        $isSecond = $maxTriZ -gt ($HighlightAboveZ + 0.001)

        $faces.Add([pscustomobject]@{
            Px = $px; Py = $py; Depth = $depth
            Nx = $nx / $len; Ny = $ny / $len; Nz = $nz / $len
            Second = $isSecond
        })
    }

    if ($faces.Count -eq 0) { throw "Mesh enthaelt keine darstellbaren Flaechen. [$AnycubicBridgeWatermark]" }

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $pad = 14
    $scale = [Math]::Min(($Size - 2 * $pad) / [Math]::Max($maxX - $minX, 0.001), ($Size - 2 * $pad) / [Math]::Max($maxY - $minY, 0.001))
    $offX = ($Size - ($maxX - $minX) * $scale) / 2 - $minX * $scale
    $offY = ($Size - ($maxY - $minY) * $scale) / 2 - $minY * $scale

    # Lichtrichtung (normiert), passend zur Kupfer-Akzentfarbe des Dashboards
    $lx = -0.4; $ly = -0.5; $lz = 0.76

    foreach ($f in ($faces | Sort-Object Depth)) {
        $lambert = $f.Nx * $lx + $f.Ny * $ly + $f.Nz * $lz
        if ($lambert -lt 0) { $lambert = 0 }
        $shade = 0.30 + 0.70 * $lambert
        if ($f.Second) {
            $baseR = 42; $baseG = 96; $baseB = 140    # zweite Farbe: kuehles Blau
        } else {
            $baseR = 201; $baseG = 97; $baseB = 46    # erste Farbe: Kupfer
        }
        $r = [int][Math]::Min(255, $baseR * $shade)
        $gr = [int][Math]::Min(255, $baseG * $shade)
        $b = [int][Math]::Min(255, $baseB * $shade)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, $r, $gr, $b))
        $poly = New-Object 'System.Drawing.PointF[]' 3
        for ($i = 0; $i -lt 3; $i++) {
            $poly[$i] = New-Object System.Drawing.PointF(
                ([float]($f.Px[$i] * $scale + $offX)),
                ([float]($Size - ($f.Py[$i] * $scale + $offY)))
            )
        }
        $g.FillPolygon($brush, $poly)
        $brush.Dispose()
    }

    $g.Dispose()
    $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return $OutPath
}

function Get-AnycubicPreviewDataUri {
    param($Triangles, [int]$Size = 320)
    $tmp = Join-Path $env:TEMP ('anycubic-preview-' + [Guid]::NewGuid().ToString('N') + '.png')
    try {
        [void](New-AnycubicPreviewPng -Triangles $Triangles -OutPath $tmp -Size $Size)
        $bytes = [System.IO.File]::ReadAllBytes($tmp)
        return 'data:image/png;base64,' + [Convert]::ToBase64String($bytes)
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

# --------------------------------------------------------------------
# Einstellungsempfehlung (OrcaSlicer/Anycubic-Settingnamen, siehe README)
# --------------------------------------------------------------------

function Get-AnycubicRecommendation {
    param($Stats, [double]$OverhangThreshold)

    $notes = New-Object System.Collections.Generic.List[string]
    $values = [ordered]@{}

    $flatRatio = 0
    if ($Stats.HeightZ_mm -gt 0) {
        $flatRatio = [Math]::Max($Stats.WidthX_mm, $Stats.DepthY_mm) / $Stats.HeightZ_mm
    }
    $isFlatAndThin = ($Stats.HeightZ_mm -le 15) -and ($flatRatio -ge 4)

    if ($isFlatAndThin) {
        $values['brim_type'] = 'no_brim'
        $notes.Add("Duenn und flach erkannt (Hoehe $($Stats.HeightZ_mm) mm, Seitenverhaeltnis $([Math]::Round($flatRatio,1))) - grosse Bett-Kontaktflaeche, kein Brim noetig.")
    } else {
        $values['brim_type'] = 'outer_only'
        $notes.Add('Keine flache/duenne Geometrie erkannt - Brim als neutrale Haftungs-Basis.')
    }

    if ($Stats.HasOverhang) {
        $values['enable_support'] = '1'
        $thresholdAngle = [Math]::Max(1, [Math]::Min(89, [Math]::Floor($Stats.WorstOverhangDeg) - 5))
        $values['support_threshold_angle'] = "$thresholdAngle"
        $notes.Add("Ueberhaenge bis $($Stats.WorstOverhangDeg) Grad gefunden ($($Stats.OverhangTriangles) Dreiecke ueber der $OverhangThreshold Grad Schwelle) - support_threshold_angle=$thresholdAngle gesetzt.")
    } else {
        $values['enable_support'] = '0'
        $notes.Add("Keine relevanten Ueberhaenge ueber $OverhangThreshold Grad gefunden - Support aus.")
    }

    [pscustomobject]@{
        Values = $values
        Notes  = $notes
    }
}

# --------------------------------------------------------------------
# Mesh bearbeiten: flache Kontur extrudieren, Objekte verbinden, 3MF schreiben
# --------------------------------------------------------------------

function ConvertTo-AnycubicSolidMesh {
    <#
      Macht aus einer flachen Kontur (alle Punkte auf einer Z-Ebene, z. B. ein
      aus FreeCAD exportierter Schriftzug) einen echten Koerper: Boden, Deckel
      und umlaufende Waende. Ohne das ist so eine Datei nicht druckbar.
    #>
    param($Triangles, [double]$Thickness)

    if ($Thickness -le 0) { throw "Dicke muss groesser als 0 sein. [$AnycubicBridgeWatermark]" }

    $baseZ = $Triangles[0][0][2]
    $topZ = $baseZ + $Thickness

    # Einheitliche Umlaufrichtung herstellen (von oben gesehen gegen den
    # Uhrzeigersinn), sonst zeigen Waende und Deckel in verschiedene Richtungen.
    $flat = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Triangles) {
        $a = $t[0]; $b = $t[1]; $c = $t[2]
        $area2 = ($b[0] - $a[0]) * ($c[1] - $a[1]) - ($c[0] - $a[0]) * ($b[1] - $a[1])
        if ($area2 -lt 0) { $flat.Add(@($a, $c, $b)) } else { $flat.Add(@($a, $b, $c)) }
    }

    # Randkanten finden: eine Kante, die nur zu einem Dreieck gehoert, liegt aussen.
    $edgeCount = @{}
    function EdgeKey($p, $q) {
        $pk = '{0:F4},{1:F4}' -f $p[0], $p[1]
        $qk = '{0:F4},{1:F4}' -f $q[0], $q[1]
        if ($pk -le $qk) { return "$pk|$qk" } else { return "$qk|$pk" }
    }
    foreach ($t in $flat) {
        foreach ($e in @(@($t[0], $t[1]), @($t[1], $t[2]), @($t[2], $t[0]))) {
            $k = EdgeKey $e[0] $e[1]
            if ($edgeCount.ContainsKey($k)) { $edgeCount[$k]++ } else { $edgeCount[$k] = 1 }
        }
    }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $flat) {
        $a = @($t[0][0], $t[0][1], $baseZ)
        $b = @($t[1][0], $t[1][1], $baseZ)
        $c = @($t[2][0], $t[2][1], $baseZ)
        $at = @($t[0][0], $t[0][1], $topZ)
        $bt = @($t[1][0], $t[1][1], $topZ)
        $ct = @($t[2][0], $t[2][1], $topZ)

        $out.Add(@($a, $c, $b))    # Boden, Normale nach unten
        $out.Add(@($at, $bt, $ct)) # Deckel, Normale nach oben

        foreach ($e in @(@($t[0], $t[1]), @($t[1], $t[2]), @($t[2], $t[0]))) {
            if ($edgeCount[(EdgeKey $e[0] $e[1])] -ne 1) { continue }
            $p = @($e[0][0], $e[0][1], $baseZ)
            $q = @($e[1][0], $e[1][1], $baseZ)
            $pt = @($e[0][0], $e[0][1], $topZ)
            $qt = @($e[1][0], $e[1][1], $topZ)
            $out.Add(@($p, $q, $qt))
            $out.Add(@($p, $qt, $pt))
        }
    }
    return $out
}

function Write-Anycubic3mf {
    <#
      Schreibt eine oder mehrere Meshes als 3MF. Jedes Mesh wird ein eigenes
      Objekt, damit man sie im Slicer weiterhin einzeln anfassen kann.
      Transformationen sind bereits in die Punkte eingerechnet (Identitaet).
    #>
    param(
        [Parameter(Mandatory = $true)]$Meshes,
        [Parameter(Mandatory = $true)][string]$OutPath
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$sb.AppendLine('<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">')
    [void]$sb.AppendLine(' <metadata name="Application">Anycubic Bridge</metadata>')
    [void]$sb.AppendLine(' <resources>')

    $objectId = 0
    foreach ($mesh in $Meshes) {
        $objectId++
        [void]$sb.AppendLine("  <object id=`"$objectId`" type=`"model`">")
        [void]$sb.AppendLine('   <mesh>')
        [void]$sb.AppendLine('    <vertices>')

        # Punkte zusammenfassen, sonst waechst die Datei unnoetig.
        # WICHTIG: alle Zahlen mit InvariantCulture schreiben. Mit deutscher
        # Kultur wird aus 26.54 ein "26,54" - beim Zurueckerlesen zaehlt das
        # Komma dann als Tausendertrennzeichen und das Modell ist 100000x zu gross.
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $index = @{}
        $order = New-Object System.Collections.Generic.List[object]
        $triIdx = New-Object System.Collections.Generic.List[object]
        foreach ($t in $mesh) {
            $ids = @(0, 0, 0)
            for ($i = 0; $i -lt 3; $i++) {
                $v = $t[$i]
                $key = [string]::Format($inv, '{0:F5}|{1:F5}|{2:F5}', [double]$v[0], [double]$v[1], [double]$v[2])
                if (-not $index.ContainsKey($key)) {
                    $index[$key] = $order.Count
                    $order.Add($v)
                }
                $ids[$i] = $index[$key]
            }
            $triIdx.Add($ids)
        }
        foreach ($v in $order) {
            [void]$sb.AppendLine([string]::Format($inv, '     <vertex x="{0:F5}" y="{1:F5}" z="{2:F5}" />', [double]$v[0], [double]$v[1], [double]$v[2]))
        }
        [void]$sb.AppendLine('    </vertices>')
        [void]$sb.AppendLine('    <triangles>')
        foreach ($t in $triIdx) {
            [void]$sb.AppendLine(('     <triangle v1="{0}" v2="{1}" v3="{2}" />' -f $t[0], $t[1], $t[2]))
        }
        [void]$sb.AppendLine('    </triangles>')
        [void]$sb.AppendLine('   </mesh>')
        [void]$sb.AppendLine('  </object>')
    }

    [void]$sb.AppendLine(' </resources>')
    [void]$sb.AppendLine(' <build>')
    for ($i = 1; $i -le $objectId; $i++) {
        [void]$sb.AppendLine("  <item objectid=`"$i`" transform=`"1 0 0 0 1 0 0 0 1 0 0 0`" />")
    }
    [void]$sb.AppendLine(' </build>')
    [void]$sb.AppendLine('</model>')

    $contentTypes = @'
<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml" />
 <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml" />
</Types>
'@
    $rels = @'
<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel" />
</Relationships>
'@

    if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force }
    $zip = [System.IO.Compression.ZipFile]::Open($OutPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        function AddEntry($archive, $name, $text) {
            $entry = $archive.CreateEntry($name)
            $stream = $entry.Open()
            $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
            $writer.Write($text)
            $writer.Flush(); $writer.Dispose(); $stream.Dispose()
        }
        AddEntry $zip '[Content_Types].xml' $contentTypes
        AddEntry $zip '_rels/.rels' $rels
        AddEntry $zip '3D/3dmodel.model' $sb.ToString()
    } finally {
        $zip.Dispose()
    }
    return $OutPath
}

function Get-AnycubicTopFaces {
    <#
      Alle nach oben zeigenden Dreiecke - das sind die Flaechen, auf denen
      etwas aufliegen kann.

      Frueher blieben hier nur die Dreiecke dicht an der HOECHSTEN Stelle des
      Modells uebrig. Das ging so lange gut, wie die Oberseite auch die
      groesste Flaeche war. Bei der Deckenhalterung ist es umgekehrt: oben
      sitzen vier kleine Erhebungen, die grosse ebene Flaeche liegt 10 mm
      tiefer - und wurde dadurch weggeworfen, worauf merge behauptete, es gebe
      ueberhaupt keine ebene Flaeche. Die Auswahl der besten Stelle trifft
      Find-AnycubicPlacement, das hohe Lagen ohnehin bevorzugt; hier zu
      filtern nimmt ihm nur die Auswahl weg.
    #>
    param($Triangles)

    $faces = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Triangles) {
        $e1x = $t[1][0] - $t[0][0]; $e1y = $t[1][1] - $t[0][1]
        $e2x = $t[2][0] - $t[0][0]; $e2y = $t[2][1] - $t[0][1]
        $nz = $e1x * $e2y - $e1y * $e2x
        if ($nz -le 0) { continue }   # zeigt nicht nach oben
        $faces.Add($t)
    }
    return $faces
}

function Find-AnycubicPlacement {
    <#
      Sucht eine Stelle auf der Oberseite, auf der das Objekt vollstaendig
      aufliegt. Noetig, weil die Mitte der Bounding-Box durchaus im Leeren
      liegen kann - bei einem Griff zum Beispiel mitten im Griffloch.
      Rueckgabe: Mittelpunkt (X/Y) und Auflagehoehe, oder $null.
    #>
    param($TopFaces, [double]$MinX, [double]$MaxX, [double]$MinY, [double]$MaxY,
          [double]$Width, [double]$Depth)

    $halfW = $Width / 2
    $halfD = $Depth / 2
    $stepX = [Math]::Max(($MaxX - $MinX) / 40, 1.0)
    $stepY = [Math]::Max(($MaxY - $MinY) / 40, 1.0)
    $centerX = ($MinX + $MaxX) / 2
    $centerY = ($MinY + $MaxY) / 2

    $best = $null
    for ($cx = $MinX + $halfW; $cx -le $MaxX - $halfW; $cx += $stepX) {
        for ($cy = $MinY + $halfD; $cy -le $MaxY - $halfD; $cy += $stepY) {
            $zs = New-Object System.Collections.Generic.List[double]
            $ok = $true
            # Erst rechnen, dann das Array bauen - Rechnen direkt in einem
            # @(...)-Literal wirft in PowerShell 5.1 Typfehler.
            $pxLeft = $cx - $halfW * 0.9
            $pxRight = $cx + $halfW * 0.9
            $pyLow = $cy - $halfD * 0.9
            $pyHigh = $cy + $halfD * 0.9
            $xSamples = New-Object 'double[]' 3
            $xSamples[0] = $pxLeft; $xSamples[1] = $cx; $xSamples[2] = $pxRight
            $ySamples = New-Object 'double[]' 3
            $ySamples[0] = $pyLow; $ySamples[1] = $cy; $ySamples[2] = $pyHigh
            foreach ($px in $xSamples) {
                foreach ($py in $ySamples) {
                    $z = Get-AnycubicSurfaceZ -Triangles $TopFaces -X $px -Y $py
                    if ($null -eq $z) { $ok = $false; break }
                    $zs.Add($z)
                }
                if (-not $ok) { break }
            }
            if (-not $ok) { continue }

            $zMin = ($zs | Measure-Object -Minimum).Minimum
            $zMax = ($zs | Measure-Object -Maximum).Maximum
            if (($zMax - $zMin) -gt 0.2) { continue }   # nicht eben genug

            # Hoch und moeglichst mittig bevorzugen.
            $dist = [Math]::Sqrt([Math]::Pow($cx - $centerX, 2) + [Math]::Pow($cy - $centerY, 2))
            $score = $zMin * 1000 - $dist
            if ($null -eq $best -or $score -gt $best.Score) {
                $best = [pscustomobject]@{ X = $cx; Y = $cy; Z = $zMin; Score = $score }
            }
        }
    }
    return $best
}

function Get-AnycubicSurfaceZ {
    <#
      Hoehe der Oberflaeche an einer XY-Stelle. Wichtig: es reicht NICHT, die
      Eckpunkte in der Umgebung zu suchen - ein langer Balken besteht oft aus
      wenigen grossen Dreiecken, deren Ecken nur an den Enden sitzen. Deshalb
      hier ein echter Test, welches Dreieck den Punkt ueberdeckt.
    #>
    param($Triangles, [double]$X, [double]$Y)

    $best = $null
    foreach ($t in $Triangles) {
        $x1 = $t[0][0]; $y1 = $t[0][1]; $z1 = $t[0][2]
        $x2 = $t[1][0]; $y2 = $t[1][1]; $z2 = $t[1][2]
        $x3 = $t[2][0]; $y3 = $t[2][1]; $z3 = $t[2][2]

        $den = ($y2 - $y3) * ($x1 - $x3) + ($x3 - $x2) * ($y1 - $y3)
        if ([Math]::Abs($den) -lt 1e-12) { continue }   # senkrechte Flaeche
        $a = (($y2 - $y3) * ($X - $x3) + ($x3 - $x2) * ($Y - $y3)) / $den
        $b = (($y3 - $y1) * ($X - $x3) + ($x1 - $x3) * ($Y - $y3)) / $den
        $c = 1.0 - $a - $b
        if ($a -lt -1e-9 -or $b -lt -1e-9 -or $c -lt -1e-9) { continue }

        $z = $a * $z1 + $b * $z2 + $c * $z3
        if ($null -eq $best -or $z -gt $best) { $best = $z }
    }
    return $best
}

function Move-AnycubicMesh {
    param($Triangles, [double]$Dx = 0, [double]$Dy = 0, [double]$Dz = 0)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Triangles) {
        # Erst in Einzelwerte rechnen, dann das Array bauen: Rechnen direkt in
        # einem @(...)-Literal fuehrt in PowerShell 5.1 zu Typfehlern.
        $v = New-Object 'object[]' 3
        for ($i = 0; $i -lt 3; $i++) {
            $x = $t[$i][0] + $Dx
            $y = $t[$i][1] + $Dy
            $z = $t[$i][2] + $Dz
            $p = New-Object 'object[]' 3
            $p[0] = $x; $p[1] = $y; $p[2] = $z
            $v[$i] = $p
        }
        $out.Add($v)
    }
    return $out
}

# --------------------------------------------------------------------
# G-Code auslesen (echte Druckdauer, Filament, Kosten)
# --------------------------------------------------------------------
# Anycubic Slicer Next schreibt am Dateiende einen Statistik-Block plus die
# ausfuehrlichen "filament used"-Zeilen. Nur diese Werte sind echt - aus der
# Geometrie allein laesst sich Dauer/Filament nicht berechnen.

function Read-AnycubicGcodeTail {
    param([string]$Path, [int]$Bytes = 262144)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $len = $fs.Length
        $take = [Math]::Min([long]$Bytes, $len)
        [void]$fs.Seek($len - $take, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $take
        [void]$fs.Read($buf, 0, $take)
        return [System.Text.Encoding]::UTF8.GetString($buf)
    } finally {
        $fs.Dispose()
    }
}

function Get-AnycubicGcodeStats {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $tail = Read-AnycubicGcodeTail -Path $Path

    function Match1($pattern) {
        $m = [regex]::Match($tail, $pattern)
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
        return $null
    }

    $printTime    = Match1 ';\s*print_time\s*=\s*(.+)'
    $filamentMm   = Match1 ';\s*filament used \[mm\]\s*=\s*([\d\.]+)'
    $filamentGram = Match1 ';\s*filament used \[g\]\s*=\s*([\d\.]+)'
    $cost         = Match1 ';\s*(?:total )?filament cost\s*=\s*([\d\.]+)'
    $layers       = Match1 ';\s*total_layers\s*=\s*(\d+)'
    $modelSize    = Match1 ';\s*model_size\s*=\s*(.+)'

    if (-not $printTime -and -not $filamentGram) { return $null }

    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        duration      = $printTime
        filamentGram  = if ($filamentGram) { [double]$filamentGram } else { $null }
        filamentMeter = if ($filamentMm) { [Math]::Round([double]$filamentMm / 1000.0, 2) } else { $null }
        costEuro      = if ($cost) { [double]$cost } else { $null }
        layers        = if ($layers) { [int]$layers } else { $null }
        modelSize     = $modelSize
        source        = $item.Name
        slicedAt      = $item.LastWriteTime.ToString('o')
    }
}

function Add-AnycubicColorChange {
    <#
      Setzt einen Filamentwechsel (M600) an die erste Schicht ab einer Hoehe.
      Damit druckt alles ab dieser Hoehe in der zweiten Farbe - z. B. ein
      erhabener Schriftzug auf der Oberseite.

      Achtung: das funktioniert nur, wenn das andersfarbige Teil OBEN aufliegt.
      Bei einem Schriftzug an einer senkrechten Seitenflaeche enthaelt jede
      Schicht beides, ein schichtbasierter Wechsel kann das nicht trennen.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$GcodePath,
        [Parameter(Mandatory = $true)][double]$AtHeightMm,
        [string]$OutPath,
        [string]$Command = 'M600'
    )

    if (-not (Test-Path -LiteralPath $GcodePath)) { throw "G-Code nicht gefunden: $GcodePath [$AnycubicBridgeWatermark]" }
    $lines = [System.IO.File]::ReadAllLines($GcodePath)

    $insertAt = -1
    $foundZ = $null
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^;Z:([\d\.]+)') {
            $z = [double]$Matches[1]
            if ($z -ge $AtHeightMm) {
                # Vor den zugehoerigen ;LAYER_CHANGE einsetzen, damit der Wechsel
                # passiert bevor die erste Bahn der neuen Schicht gedruckt wird.
                $insertAt = $i
                for ($j = $i; $j -ge 0 -and $j -ge $i - 5; $j--) {
                    if ($lines[$j] -eq ';LAYER_CHANGE') { $insertAt = $j; break }
                }
                $foundZ = $z
                break
            }
        }
    }
    if ($insertAt -lt 0) { throw "Keine Schicht auf oder ueber $AtHeightMm mm gefunden - ist die Hoehe groesser als das Teil? [$AnycubicBridgeWatermark]" }

    $target = if ($OutPath) { $OutPath } else { $GcodePath }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($i -eq $insertAt) {
            $out.Add('; --- Farbwechsel eingefuegt von der Anycubic Bridge ---')
            $out.Add("; Wechsel auf Z = $foundZ mm")
            $out.Add($Command)
        }
        $out.Add($lines[$i])
    }
    [System.IO.File]::WriteAllLines($target, $out)

    return [pscustomobject]@{
        GcodePath = $target
        AtZ       = $foundZ
        LineIndex = $insertAt
        Command   = $Command
    }
}

function Find-AnycubicNewestGcode {
    param($MainConf)
    $dirs = New-Object System.Collections.Generic.List[string]
    $dirs.Add([Environment]::GetFolderPath('Desktop'))
    if ($MainConf -and $MainConf.app -and $MainConf.app.download_path) { $dirs.Add([string]$MainConf.app.download_path) }
    if ($MainConf -and $MainConf.app -and $MainConf.app.last_export_path) { $dirs.Add([string]$MainConf.app.last_export_path) }

    $newest = $null
    foreach ($d in ($dirs | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path -LiteralPath $d)) { continue }
        $cand = Get-ChildItem -LiteralPath $d -Filter '*.gcode' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($cand -and (-not $newest -or $cand.LastWriteTime -gt $newest.LastWriteTime)) { $newest = $cand }
    }
    return $newest
}

# --------------------------------------------------------------------
# Dashboard-Dokument (lokale Datenquelle fuer das Monitor-Fenster)
# --------------------------------------------------------------------

function Get-AnycubicDefaultDataFile {
    return (Join-Path (Join-Path $env:APPDATA 'AnycubicBridge') 'dashboard-data.js')
}

function Get-AnycubicDashboardDoc {
    param([string]$ModelPathOverride, [string]$MachineOverride, [double]$OverhangThreshold = 55)

    $configRoot = Get-AnycubicConfigRoot
    $mainConf = Read-AnycubicMainConf -ConfigRoot $configRoot

    # Massgeblich ist, was JETZT auf dem Bett liegt. Nur wenn jemand ausdruecklich
    # eine Datei vorgibt, wird die genommen.
    $plate = @()
    $resolvedModelPath = $null
    $modelName = $null
    if ($ModelPathOverride) {
        $resolvedModelPath = $ModelPathOverride
        $modelName = [System.IO.Path]::GetFileName($ModelPathOverride)
        $triangles = Get-AnycubicMeshTriangles -Path $resolvedModelPath
    } else {
        $plate = @(Get-AnycubicPlate)
        if ($plate.Count -eq 0) {
            # Nichts geladen: ehrlich leer melden, statt irgendeine alte Datei
            # von der Platte zu zeigen.
            return [ordered]@{
                empty     = $true
                machine   = $mainConf.presets.machine
                updatedAt = (Get-Date).ToString('o')
                hinweis   = 'Nichts auf dem Druckbett - lade ein Modell in Anycubic Slicer Next.'
            }
        }
        $triangles = Get-AnycubicPlateTriangles -Plate $plate
        $modelName = (($plate | ForEach-Object { $_.Name }) -join ' + ')
        $resolvedModelPath = $plate[0].File
    }

    $stats = Get-AnycubicMeshStats -Triangles $triangles -OverhangThreshold $OverhangThreshold
    $rec = Get-AnycubicRecommendation -Stats $stats -OverhangThreshold $OverhangThreshold

    $targetMachine = if ($MachineOverride) { $MachineOverride } else { $mainConf.presets.machine }
    $existingProfiles = Get-AnycubicProcessProfiles -ConfigRoot $configRoot
    $template = $null
    $layerHeight = $null
    if ($existingProfiles.Count -gt 0) {
        $template = Find-AnycubicTemplateForMachine -ConfigRoot $configRoot -MachineName $targetMachine -ExistingProfiles $existingProfiles
        $systemTemplate = Find-AnycubicSystemProcessProfile -ConfigRoot $configRoot -Name $template.Inherits
        if ($systemTemplate -and $systemTemplate.layer_height) { $layerHeight = [double]$systemTemplate.layer_height }
    }

    # Schichtzahl ist deterministisch aus Hoehe/Schichthoehe ableitbar - im
    # Gegensatz zu Druckdauer und Filament, die es erst nach dem Slicen gibt.
    $layerCount = $null
    if ($layerHeight -and $layerHeight -gt 0) {
        $layerCount = [int][Math]::Ceiling($stats.HeightZ_mm / $layerHeight)
    }

    $whyByKey = @{
        brim_type               = if ($stats.HeightZ_mm -le 15) { 'Duenn und flach - grosse Bett-Kontaktflaeche, Brim unnoetig' } else { 'Kleine Standflaeche - Brim gibt Halt' }
        enable_support          = if ($stats.HasOverhang) { "$($stats.OverhangTriangles) Dreiecke mit Ueberhang, bis $($stats.WorstOverhangDeg) Grad" } else { 'Keine Ueberhaenge ueber der Schwelle' }
        support_threshold_angle = "knapp unter dem groessten gemessenen Ueberhang ($($stats.WorstOverhangDeg) Grad)"
    }
    $changes = @()
    foreach ($k in $rec.Values.Keys) {
        $changes += [pscustomobject]@{
            key   = $k
            value = [string]$rec.Values[$k]
            why   = [string]$whyByKey[$k]
        }
    }

    # Echte Slice-Werte, falls es eine passende .gcode gibt. Nur beruecksichtigen,
    # wenn sie nach dem Modell entstanden ist - sonst gehoert sie zu einem
    # frueheren Teil und wuerde falsche Zahlen anzeigen.
    $slice = $null
    $gcode = Find-AnycubicNewestGcode -MainConf $mainConf
    if ($gcode) {
        $modelItem = Get-Item -LiteralPath $resolvedModelPath
        if ($gcode.LastWriteTime -ge $modelItem.LastWriteTime) {
            $slice = Get-AnycubicGcodeStats -Path $gcode.FullName
        }
    }
    if ($slice -and $slice.layers) { $layerCount = $slice.layers }

    return [ordered]@{
        empty     = $false
        model     = $modelName
        modelPath = $resolvedModelPath
        objects   = @($plate | ForEach-Object { $_.Name })
        machine   = $targetMachine
        updatedAt = (Get-Date).ToString('o')
        preview   = Get-AnycubicPreviewDataUri -Triangles $triangles
        geometry  = [ordered]@{
            triangles         = $stats.Triangles
            widthMm           = $stats.WidthX_mm
            depthMm           = $stats.DepthY_mm
            heightMm          = $stats.HeightZ_mm
            volumeCm3         = $stats.Volume_cm3
            hasOverhang       = $stats.HasOverhang
            worstOverhangDeg  = $stats.WorstOverhangDeg
            overhangTriangles = $stats.OverhangTriangles
            layerCount        = $layerCount
            layerHeightMm     = $layerHeight
        }
        changes         = $changes
        slice           = $slice
        profileTemplate = if ($template) { $template.Inherits } else { $null }
    }
}

function Write-AnycubicDashboardData {
    param($Doc, [string]$OutFile)
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $json = $Doc | ConvertTo-Json -Depth 6 -Compress
    # Als .js schreiben, damit das Monitor-Fenster die Daten auch von file://
    # laden kann - fetch() waere dort durch CORS blockiert, ein <script src> nicht.
    if ([System.IO.Path]::GetExtension($OutFile).ToLowerInvariant() -eq '.js') {
        $json = 'window.BRIDGE_DATA = ' + $json + ';'
        # Mit BOM schreiben: so erkennt der Browser die Kodierung auch bei
        # file:// zweifelsfrei, sonst werden Umlaute im Modellnamen zerschossen.
        [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($true)))
    } else {
        Write-AnycubicBridgeTextFile -Path $OutFile -Text $json
    }
}

# --------------------------------------------------------------------
# Verben
# --------------------------------------------------------------------

switch ($Action) {

    'about' {
        [pscustomobject]@{
            Name      = $AnycubicBridgeName
            Version   = $AnycubicBridgeVersion
            Watermark = $AnycubicBridgeWatermark
            Safety    = 'Schreibt nur mit -Force, nur in user\default\process\ (neue Datei). Ruehrt AnycubicSlicerNext.conf NIE an - Checksummen-Format nicht sicher reproduzierbar, zu riskant fuer die echte Konfiguration.'
            Scope     = 'Liest Anycubic Slicer Next JSON-Konfiguration + Profile. Keine Live-Verbindung zu einer laufenden Instanz.'
        } | Format-List
    }

    'status' {
        $configRoot = Get-AnycubicConfigRoot
        $mainConf = Read-AnycubicMainConf -ConfigRoot $configRoot
        $resolvedModelPath = if ($ModelPath) { $ModelPath } else { Get-AnycubicActiveModelPath -MainConf $mainConf }
        $aktiv = Get-AnycubicActiveCombo -MainConf $mainConf
        [pscustomobject]@{
            Tool             = "$AnycubicBridgeName $AnycubicBridgeVersion"
            Watermark        = $AnycubicBridgeWatermark
            ConfigRoot       = $configRoot
            AktuellesModell  = $resolvedModelPath
            AktiveMaschine   = $aktiv.Maschine
            AktivesFilament  = $aktiv.Filament
            AktivesProfil    = $aktiv.Prozess
        } | Format-List
    }

    'listprofiles' {
        $configRoot = Get-AnycubicConfigRoot
        Get-AnycubicProcessProfiles -ConfigRoot $configRoot | Sort-Object Name | Format-Table -AutoSize
    }

    'analyze' {
        $configRoot = Get-AnycubicConfigRoot
        $mainConf = Read-AnycubicMainConf -ConfigRoot $configRoot
        $resolvedModelPath = if ($ModelPath) { $ModelPath } else { Get-AnycubicActiveModelPath -MainConf $mainConf }
        if (-not $resolvedModelPath) { throw "Kein Modell gefunden (weder recent_projects noch Ordner-Scan). Bitte -ModelPath angeben. [$AnycubicBridgeWatermark]" }

        $triangles = Get-AnycubicMeshTriangles -Path $resolvedModelPath
        $stats = Get-AnycubicMeshStats -Triangles $triangles -OverhangThreshold $OverhangThreshold

        [pscustomobject]@{
            Modell                  = $resolvedModelPath
            Dreiecke                = $stats.Triangles
            Breite_X_mm             = $stats.WidthX_mm
            Tiefe_Y_mm              = $stats.DepthY_mm
            Hoehe_Z_mm              = $stats.HeightZ_mm
            Grundflaeche_cm2        = $stats.FootprintArea_cm2
            Volumen_cm3             = $stats.Volume_cm3
            UeberhangGefunden       = $stats.HasOverhang
            GroessterUeberhang_Grad = $stats.WorstOverhangDeg
            UeberhangDreiecke       = $stats.OverhangTriangles
            Hinweis                 = 'Grundflaeche ist eine Bounding-Box-Naeherung (keine Rotations-/Nesting-Optimierung). Duennwand-Erkennung ist NICHT enthalten.'
        } | Format-List
    }

    'preview' {
        $configRoot = Get-AnycubicConfigRoot
        $mainConf = Read-AnycubicMainConf -ConfigRoot $configRoot
        $resolvedModelPath = if ($ModelPath) { $ModelPath } else { Get-AnycubicActiveModelPath -MainConf $mainConf }
        if (-not $resolvedModelPath) { throw "Kein Modell gefunden. Bitte -ModelPath angeben. [$AnycubicBridgeWatermark]" }

        $triangles = Get-AnycubicMeshTriangles -Path $resolvedModelPath
        $target = if ($OutFile) { $OutFile } else { Join-Path ([Environment]::GetFolderPath('Desktop')) 'anycubic-preview.png' }
        $highlight = if ($AtHeight -gt 0) { $AtHeight } else { [double]::MaxValue }
        [void](New-AnycubicPreviewPng -Triangles $triangles -OutPath $target -Size $PreviewSize -HighlightAboveZ $highlight)
        "Vorschau gerendert: $target [$AnycubicBridgeWatermark]"
        if ($AtHeight -gt 0) { "Alles ab Z = $AtHeight mm ist blau dargestellt - das wird die zweite Farbe." }
    }

    'dashboard' {
        $doc = Get-AnycubicDashboardDoc -ModelPathOverride $ModelPath -MachineOverride $MachinePreset -OverhangThreshold $OverhangThreshold
        if ($OutFile) {
            Write-AnycubicDashboardData -Doc $doc -OutFile $OutFile
            "Geschrieben: $OutFile [$AnycubicBridgeWatermark]"
        } else {
            $doc | ConvertTo-Json -Depth 6 -Compress
        }
    }

    'extrude' {
        if (-not $ModelPath) { throw "-ModelPath wird benoetigt (die flache Datei). [$AnycubicBridgeWatermark]" }
        if (-not $OutFile) { throw "-OutFile wird benoetigt (Ziel-3MF). [$AnycubicBridgeWatermark]" }
        if ($Thickness -le 0) { throw "-Thickness (mm) wird benoetigt, z. B. -Thickness 0.8 [$AnycubicBridgeWatermark]" }

        $tris = Get-AnycubicMeshTriangles -Path $ModelPath
        $before = Get-AnycubicMeshStats -Triangles $tris -OverhangThreshold $OverhangThreshold
        if ($before.HeightZ_mm -gt 0.001) {
            throw "Das Modell hat bereits $($before.HeightZ_mm) mm Hoehe - extrudieren wuerde es verfaelschen. [$AnycubicBridgeWatermark]"
        }

        $solid = ConvertTo-AnycubicSolidMesh -Triangles $tris -Thickness $Thickness
        $after = Get-AnycubicMeshStats -Triangles $solid -OverhangThreshold $OverhangThreshold
        [void](Write-Anycubic3mf -Meshes @(, $solid) -OutPath $OutFile)

        "Extrudiert: $([System.IO.Path]::GetFileName($ModelPath)) -> $OutFile [$AnycubicBridgeWatermark]"
        "Dreiecke:   $($before.Triangles) flach -> $($after.Triangles) als Koerper"
        "Groesse:    $($after.WidthX_mm) x $($after.DepthY_mm) x $($after.HeightZ_mm) mm"
        "Volumen:    $($after.Volume_cm3) cm3 (vorher 0 - war nicht druckbar)"
    }

    'merge' {
        if (-not $ModelPath) { throw "-ModelPath wird benoetigt (Grundkoerper). [$AnycubicBridgeWatermark]" }
        if (-not $AddModel) { throw "-AddModel wird benoetigt (das aufzusetzende Objekt). [$AnycubicBridgeWatermark]" }
        if (-not $OutFile) { throw "-OutFile wird benoetigt (Ziel-3MF). [$AnycubicBridgeWatermark]" }

        $baseTris = Get-AnycubicMeshTriangles -Path $ModelPath
        $addTris = Get-AnycubicMeshTriangles -Path $AddModel
        $baseStats = Get-AnycubicMeshStats -Triangles $baseTris -OverhangThreshold $OverhangThreshold
        $addStats = Get-AnycubicMeshStats -Triangles $addTris -OverhangThreshold $OverhangThreshold

        if ($addStats.HeightZ_mm -le 0.001) {
            throw "Das aufzusetzende Objekt ist flach (0 mm hoch). Erst mit 'extrude' zu einem Koerper machen. [$AnycubicBridgeWatermark]"
        }

        # Grenzen bestimmen, um mittig auf die Oberseite zu setzen.
        $bMinX = [double]::MaxValue; $bMaxX = [double]::MinValue
        $bMinY = [double]::MaxValue; $bMaxY = [double]::MinValue
        $bMaxZ = [double]::MinValue
        foreach ($t in $baseTris) { foreach ($v in $t) {
            if ($v[0] -lt $bMinX) { $bMinX = $v[0] }; if ($v[0] -gt $bMaxX) { $bMaxX = $v[0] }
            if ($v[1] -lt $bMinY) { $bMinY = $v[1] }; if ($v[1] -gt $bMaxY) { $bMaxY = $v[1] }
            if ($v[2] -gt $bMaxZ) { $bMaxZ = $v[2] }
        } }
        $aMinX = [double]::MaxValue; $aMaxX = [double]::MinValue
        $aMinY = [double]::MaxValue; $aMaxY = [double]::MinValue
        $aMinZ = [double]::MaxValue
        foreach ($t in $addTris) { foreach ($v in $t) {
            if ($v[0] -lt $aMinX) { $aMinX = $v[0] }; if ($v[0] -gt $aMaxX) { $aMaxX = $v[0] }
            if ($v[1] -lt $aMinY) { $aMinY = $v[1] }; if ($v[1] -gt $aMaxY) { $aMaxY = $v[1] }
            if ($v[2] -lt $aMinZ) { $aMinZ = $v[2] }
        } }

        # Aufsetzstelle suchen: eine ebene Flaeche, auf der das Objekt komplett
        # aufliegt. Die Bounding-Box-Mitte taugt dafuer nicht - bei einem Griff
        # liegt die mitten im Griffloch.
        $topFaces = Get-AnycubicTopFaces -Triangles $baseTris
        $spot = Find-AnycubicPlacement -TopFaces $topFaces `
            -MinX $bMinX -MaxX $bMaxX -MinY $bMinY -MaxY $bMaxY `
            -Width ($aMaxX - $aMinX) -Depth ($aMaxY - $aMinY)
        if (-not $spot) {
            throw "Keine ebene Flaeche gefunden, auf der das Objekt ganz aufliegt. Passt es ueberhaupt drauf? [$AnycubicBridgeWatermark]"
        }

        $dx = $spot.X - (($aMinX + $aMaxX) / 2) + $OffsetX
        $dy = $spot.Y - (($aMinY + $aMaxY) / 2) + $OffsetY

        # Minimal einsinken lassen, damit die Flaechen verschmelzen.
        $surfaceZ = $spot.Z
        $overlap = 0.05
        $dz = $surfaceZ - $aMinZ - $overlap + $OffsetZ

        $moved = Move-AnycubicMesh -Triangles $addTris -Dx $dx -Dy $dy -Dz $dz

        # Bewusst als Liste sammeln: @($a, $b) wuerde beide Meshes zu einer
        # einzigen flachen Dreiecksliste zusammenziehen.
        $meshes = New-Object System.Collections.Generic.List[object]
        $meshes.Add($baseTris)
        $meshes.Add($moved)
        [void](Write-Anycubic3mf -Meshes $meshes -OutPath $OutFile)

        # Eine Schicht ueber der Auflageflaeche wechseln: die Schicht, die genau
        # auf der Grenze liegt, enthaelt noch die Deckflaeche des Grundkoerpers.
        # Wuerde man dort wechseln, waere die ganze Oberseite mit umgefaerbt.
        $changeZ = [Math]::Round($surfaceZ + $LayerHeight, 2)
        "Verbunden -> $OutFile [$AnycubicBridgeWatermark]"
        "Grundkoerper: $($baseStats.WidthX_mm) x $($baseStats.DepthY_mm) x $($baseStats.HeightZ_mm) mm"
        "Aufgesetzt:   $($addStats.WidthX_mm) x $($addStats.DepthY_mm) x $($addStats.HeightZ_mm) mm, verschoben um ($([Math]::Round($dx,2)) / $([Math]::Round($dy,2)) / $([Math]::Round($dz,2))) mm"
        "Aufgesetzt bei X=$([Math]::Round($spot.X,1)) Y=$([Math]::Round($spot.Y,1)) auf Flaeche Z = $changeZ mm"
        ""
        "Fuer den Farbwechsel: das aufgesetzte Objekt beginnt bei Z = $changeZ mm."
        "Nach dem Slicen:"
        "  .\anycubic-bridge.ps1 colorchange -GcodeFile <datei.gcode> -AtHeight $changeZ -OutFile <zweifarbig.gcode> -Force"
    }

    'slice' {
        # Slict direkt ueber die Kommandozeile des Slicers - ohne Oberflaeche,
        # ohne Profil anzulegen, ohne Neustart. Damit wirken vorgegebene Werte
        # sofort, statt erst nach Profilwahl im Programm.
        $installRoot = Get-AnycubicInstallRoot
        $exe = Join-Path $installRoot 'AnycubicSlicerNext.exe'
        if (-not (Test-Path -LiteralPath $exe)) { throw "Slicer nicht gefunden: $exe [$AnycubicBridgeWatermark]" }

        $configRoot = Get-AnycubicConfigRoot
        $mainConf = Read-AnycubicMainConf -ConfigRoot $configRoot
        $maschine = if ($MachinePreset) { $MachinePreset } else { $mainConf.presets.machine }

        # Modell: Vorgabe, sonst die Projektdatei der laufenden Sitzung.
        $quelle = $ModelPath
        if (-not $quelle) {
            $sess = Get-AnycubicSessionDir
            if ($sess) {
                $origin = Join-Path $sess.FullName 'origin.txt'
                if (Test-Path -LiteralPath $origin) {
                    $p = (Get-Content -LiteralPath $origin -Raw).Trim()
                    if ($p -and (Test-Path -LiteralPath $p)) { $quelle = $p }
                }
            }
        }
        if (-not $quelle) { throw "Keine Modelldatei. Bitte -ModelPath angeben (die Sitzung nennt keine Quelldatei). [$AnycubicBridgeWatermark]" }

        $sys = Join-Path $configRoot 'system\Anycubic'
        $machineJson = Join-Path $sys ('machine\' + $maschine + '.json')
        if (-not (Test-Path -LiteralPath $machineJson)) { throw "Maschinenprofil nicht gefunden: $machineJson [$AnycubicBridgeWatermark]" }

        # Prozessprofil: Standard der Maschine, bei Bedarf mit eigenen Werten.
        $prozessName = '0.20mm Standard @' + $maschine
        $prozessJson = Join-Path $sys ('process\' + $prozessName + '.json')
        if (-not (Test-Path -LiteralPath $prozessJson)) { throw "Prozessprofil nicht gefunden: $prozessJson [$AnycubicBridgeWatermark]" }

        $tempDir = Join-Path $env:TEMP ('anycubic-bridge-slice-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        [void](New-Item -ItemType Directory -Path $tempDir -Force)

        # Werte aufteilen: was zum Filament gehoert, muss ins Filamentprofil.
        $filamentEigene = [ordered]@{}
        if ($Values) {
            # Eigene Werte als abgeleitetes Profil daneben legen. Das Original
            # bleibt unangetastet, und es landet nichts in der Slicer-Konfig.
            $eigene = [ordered]@{}
            foreach ($paar in ($Values -split ';')) {
                if ($paar -notmatch '=') { continue }
                $k = $paar.Substring(0, $paar.IndexOf('=')).Trim()
                $v = $paar.Substring($paar.IndexOf('=') + 1).Trim()
                if (-not $k) { continue }
                # Kuehlung und Luefter sitzen bei OrcaSlicer ebenfalls im
                # Filamentprofil. Im Prozessprofil werden sie stillschweigend
                # ignoriert - der Wert steht dann drin und wirkt trotzdem nicht.
                $istFilament = ($k -like 'filament_*' -or $k -like 'nozzle_temperature*' -or
                    $k -like 'hot_plate_temp*' -or $k -like '*fan_speed*' -or
                    $k -in @('slow_down_layer_time','slow_down_min_speed','slow_down_for_layer_cooling',
                             'fan_cooling_layer_time','close_fan_the_first_x_layers','full_fan_speed_layer',
                             'enable_overhang_bridge_fan','overhang_fan_threshold','reduce_fan_stop_start_freq'))
                if ($istFilament) {
                    $filamentEigene[$k] = $v
                } else {
                    $eigene[$k] = $v
                }
            }
            if ($eigene.Count -gt 0) {
            $basis = Get-Content -LiteralPath $prozessJson -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in $eigene.Keys) {
                $basis | Add-Member -NotePropertyName $k -NotePropertyValue ([string]$eigene[$k]) -Force
            }
            $basis | Add-Member -NotePropertyName 'name' -NotePropertyValue 'Bridge Slice' -Force
            $basis | Add-Member -NotePropertyName 'print_settings_id' -NotePropertyValue 'Bridge Slice' -Force
            $prozessJson = Join-Path $tempDir 'process.json'
            Write-AnycubicBridgeTextFile -Path $prozessJson -Text ($basis | ConvertTo-Json -Depth 8)
            "Eigene Werte: " + (($eigene.Keys | ForEach-Object { "$_=$($eigene[$_])" }) -join ', ')
            }
        }

        # Filament: erstes passendes des Druckers.
        $filamentJson = Get-ChildItem -LiteralPath (Join-Path $sys 'filament') -Filter ('*PLA @' + $maschine + '.json') -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $filamentJson) {
            $filamentJson = Get-ChildItem -LiteralPath (Join-Path $sys 'filament') -Filter '*PLA*' | Select-Object -First 1
        }
        $filamentPfad = $filamentJson.FullName

        # Filament-Einstellungen gehoeren ins Filamentprofil, nicht ins
        # Prozessprofil - dort werden sie stillschweigend ignoriert.
        if ($filamentEigene -and $filamentEigene.Count -gt 0) {
            $fbasis = Get-Content -LiteralPath $filamentPfad -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in $filamentEigene.Keys) {
                # Einige Filamentwerte sind Listen (ein Eintrag je Extruder).
                $alt = $fbasis.$k
                $neu = if ($alt -is [array]) { ,@([string]$filamentEigene[$k]) } else { [string]$filamentEigene[$k] }
                $fbasis | Add-Member -NotePropertyName $k -NotePropertyValue $neu -Force
            }
            $fbasis | Add-Member -NotePropertyName 'name' -NotePropertyValue 'Bridge Filament' -Force
            $fbasis | Add-Member -NotePropertyName 'filament_settings_id' -NotePropertyValue 'Bridge Filament' -Force
            $filamentPfad = Join-Path $tempDir 'filament.json'
            Write-AnycubicBridgeTextFile -Path $filamentPfad -Text ($fbasis | ConvertTo-Json -Depth 8)
            "Filament-Werte: " + (($filamentEigene.Keys | ForEach-Object { "$_=$($filamentEigene[$_])" }) -join ', ')
        }

        $ziel = if ($OutFile) { Split-Path -Parent $OutFile } else { $tempDir }
        if (-not $ziel) { $ziel = $tempDir }
        if (-not (Test-Path -LiteralPath $ziel)) { [void](New-Item -ItemType Directory -Path $ziel -Force) }

        $argLine = '--slice 0 --datadir "' + $configRoot + '" --load-settings "' + $machineJson + ';' + $prozessJson +
                   '" --load-filaments "' + $filamentPfad + '" --outputdir "' + $ziel + '" "' + $quelle + '"'

        "Slicen: $([System.IO.Path]::GetFileName($quelle))  ->  $ziel"
        $logOut = Join-Path $tempDir 'out.txt'
        $logErr = Join-Path $tempDir 'err.txt'
        $proc = Start-Process -FilePath $exe -PassThru -NoNewWindow -RedirectStandardOutput $logOut -RedirectStandardError $logErr -ArgumentList $argLine
        if (-not $proc.WaitForExit(600000)) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            throw "Slicen hat zu lange gedauert und wurde abgebrochen. [$AnycubicBridgeWatermark]"
        }

        $gcode = Get-ChildItem -LiteralPath $ziel -Filter '*.gcode' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $gcode) {
            $fehler = if (Test-Path -LiteralPath $logErr) { (Get-Content -LiteralPath $logErr -Raw).Trim() } else { '' }
            if (-not $fehler -and (Test-Path -LiteralPath $logOut)) { $fehler = (Get-Content -LiteralPath $logOut -Tail 5) -join ' ' }
            throw "Kein G-Code entstanden. $fehler [$AnycubicBridgeWatermark]"
        }

        if ($OutFile -and $gcode.FullName -ne $OutFile) {
            Move-Item -LiteralPath $gcode.FullName -Destination $OutFile -Force
            $gcode = Get-Item -LiteralPath $OutFile
        }

        $stats = Get-AnycubicGcodeStats -Path $gcode.FullName
        "Fertig: $($gcode.FullName)"
        if ($stats) {
            "Dauer:    $($stats.duration)"
            "Filament: $($stats.filamentGram) g / $($stats.filamentMeter) m" + $(if ($stats.costEuro -ne $null) { ", $($stats.costEuro) EUR" } else { '' })
            "Schichten: $($stats.layers)"
        }
        "[$AnycubicBridgeWatermark]"
    }

    'colorchange' {
        if (-not $GcodeFile) { throw "-GcodeFile wird benoetigt. [$AnycubicBridgeWatermark]" }
        if ($AtHeight -le 0) { throw "-AtHeight (mm) wird benoetigt, z. B. -AtHeight 12.4 [$AnycubicBridgeWatermark]" }

        if (-not $Force) {
            "TROCKENLAUF (kein -Force) - es wurde nichts geschrieben. [$AnycubicBridgeWatermark]"
            $stats = Get-AnycubicGcodeStats -Path $GcodeFile
            if ($stats) { "Datei: $($stats.source), $($stats.layers) Schichten, Modellhoehe aus model_size: $($stats.modelSize)" }
            "Wuerde $($ColorChangeCommand) vor der ersten Schicht ab $AtHeight mm einfuegen."
            "Mit -Force ausfuehren. Ziel: " + $(if ($OutFile) { $OutFile } else { "$GcodeFile (wird ueberschrieben)" })
        } else {
            $res = Add-AnycubicColorChange -GcodePath $GcodeFile -AtHeightMm $AtHeight -OutPath $OutFile -Command $ColorChangeCommand
            "Farbwechsel gesetzt: $($res.Command) bei Z = $($res.AtZ) mm"
            "Geschrieben: $($res.GcodePath) [$AnycubicBridgeWatermark]"
            "Der Drucker haelt an dieser Stelle an - Filament wechseln, dann fortsetzen."
        }
    }

    'watch' {
        # Haelt die Datendatei aktuell, ohne dass jemand etwas anstossen muss:
        # prueft, ob sich das erkannte Modell (Pfad oder Aenderungszeit) geaendert
        # hat, und schreibt nur dann neu (Mesh-Rendern kostet sonst unnoetig Zeit).
        # Nur ein Watcher gleichzeitig - sonst startet jeder Launcher-Aufruf einen
        # weiteren, die sich beim Schreiben derselben Datei in die Quere kommen.
        $mutexCreated = $false
        $watchMutex = New-Object System.Threading.Mutex($true, 'Global\AnycubicBridgeWatch', [ref]$mutexCreated)
        if (-not $mutexCreated) {
            "Es laeuft bereits ein Watcher - dieser Aufruf beendet sich. [$AnycubicBridgeWatermark]"
            return
        }

        $target = if ($OutFile) { $OutFile } else { Get-AnycubicDefaultDataFile }
        $dir = Split-Path -Parent $target
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }

        "Beobachte Anycubic Slicer Next, schreibe nach: $target"
        "Intervall: $IntervalSeconds s. Beenden mit Strg+C. [$AnycubicBridgeWatermark]"

        try {
            $lastKey = $null
            while ($true) {
                try {
                    $configRoot = Get-AnycubicConfigRoot
                    $mainConf = Read-AnycubicMainConf -ConfigRoot $configRoot
                    $model = $ModelPath

                    # Kennung des aktuellen Zustands. Massgeblich ist das Bett -
                    # so wird auch bemerkt, wenn ein Objekt entfernt oder ein
                    # ganz anderes geladen wird.
                    $key = $null
                    if ($model) {
                        if (Test-Path -LiteralPath $model) {
                            $item = Get-Item -LiteralPath $model
                            $key = $item.FullName + '|' + $item.LastWriteTimeUtc.Ticks
                        }
                    } else {
                        $sess = Get-AnycubicSessionDir
                        if ($sess) {
                            # Bett-Datei ist massgeblich, sobald es sie gibt.
                            # Direkt nach dem Laden fehlt sie noch - dann zaehlen
                            # die Objektdateien, sonst wuerde ein frisch
                            # geladenes Modell nicht bemerkt.
                            $plateFile = Join-Path $sess.FullName '.3mf'
                            $stamp = if (Test-Path -LiteralPath $plateFile) {
                                (Get-Item -LiteralPath $plateFile).LastWriteTimeUtc.Ticks
                            } else {
                                $objDir = Join-Path $sess.FullName '3D\Objects'
                                if (Test-Path -LiteralPath $objDir) {
                                    $objs = @(Get-ChildItem -LiteralPath $objDir -Filter '*.model' -File)
                                    if ($objs.Count -gt 0) {
                                        'obj:' + $objs.Count + ':' + (($objs | Sort-Object LastWriteTimeUtc | Select-Object -Last 1).LastWriteTimeUtc.Ticks)
                                    } else { 'leer' }
                                } else { 'leer' }
                            }
                            $key = $sess.FullName + '|' + $stamp
                        } else {
                            $key = 'kein-slicer'
                        }
                    }
                    if ($key) { $key = $key + '|' + $mainConf.presets.machine }

                    if ($key -and $key -ne $lastKey) {
                        $doc = Get-AnycubicDashboardDoc -ModelPathOverride $model -MachineOverride $MachinePreset -OverhangThreshold $OverhangThreshold
                        Write-AnycubicDashboardData -Doc $doc -OutFile $target
                        $lastKey = $key
                        "$(Get-Date -Format 'HH:mm:ss')  aktualisiert: $($doc.model)"
                    }
                } catch {
                    "$(Get-Date -Format 'HH:mm:ss')  Fehler: $($_.Exception.Message)"
                }
                Start-Sleep -Seconds $IntervalSeconds
            }
        } finally {
            $watchMutex.ReleaseMutex()
            $watchMutex.Dispose()
        }
    }

    'recommend' {
        $configRoot = Get-AnycubicConfigRoot
        $mainConf = Read-AnycubicMainConf -ConfigRoot $configRoot
        $resolvedModelPath = if ($ModelPath) { $ModelPath } else { Get-AnycubicActiveModelPath -MainConf $mainConf }
        if (-not $resolvedModelPath) { throw "Kein Modell gefunden. Bitte -ModelPath angeben. [$AnycubicBridgeWatermark]" }

        $triangles = Get-AnycubicMeshTriangles -Path $resolvedModelPath
        $stats = Get-AnycubicMeshStats -Triangles $triangles -OverhangThreshold $OverhangThreshold
        $rec = Get-AnycubicRecommendation -Stats $stats -OverhangThreshold $OverhangThreshold

        "Modell: $resolvedModelPath [$AnycubicBridgeWatermark]"
        "Maschine: $($mainConf.presets.machine)"
        ""
        "Empfohlene Werte:"
        foreach ($key in $rec.Values.Keys) {
            "  {0,-24} = {1}" -f $key, $rec.Values[$key]
        }
        ""
        "Begruendung:"
        foreach ($n in $rec.Notes) { "  - $n" }
        ""
        'Zum Schreiben als Profil: .\anycubic-bridge.ps1 writeprofile -ProfileName "Claude <Name>" -Force'
    }

    'writeprofile' {
        if ([string]::IsNullOrWhiteSpace($ProfileName)) {
            throw "-ProfileName wird benoetigt, z. B. 'Claude Tuergriff'. [$AnycubicBridgeWatermark]"
        }
        $configRoot = Get-AnycubicConfigRoot
        $mainConf = Read-AnycubicMainConf -ConfigRoot $configRoot

        # Mit -Values werden genau die angegebenen Werte geschrieben. Dann ist
        # kein Modell noetig - die Werte kommen ja von aussen.
        $rec = $null
        if ($Values) {
            $eigene = [ordered]@{}
            foreach ($paar in ($Values -split ';')) {
                if ($paar -notmatch '=') { continue }
                $k = $paar.Substring(0, $paar.IndexOf('=')).Trim()
                $v = $paar.Substring($paar.IndexOf('=') + 1).Trim()
                if ($k) { $eigene[$k] = $v }
            }
            if ($eigene.Count -eq 0) { throw "-Values konnte nicht gelesen werden. Format: ""key=wert;key=wert"" [$AnycubicBridgeWatermark]" }
            $rec = [pscustomobject]@{ Values = $eigene; Notes = @('Werte von Hand vorgegeben.') }
        } else {
            $resolvedModelPath = if ($ModelPath) { $ModelPath } else { Get-AnycubicActiveModelPath -MainConf $mainConf }
            if (-not $resolvedModelPath) { throw "Kein Modell gefunden. Bitte -ModelPath oder -Values angeben. [$AnycubicBridgeWatermark]" }
            $triangles = Get-AnycubicMeshTriangles -Path $resolvedModelPath
            $stats = Get-AnycubicMeshStats -Triangles $triangles -OverhangThreshold $OverhangThreshold
            $rec = Get-AnycubicRecommendation -Stats $stats -OverhangThreshold $OverhangThreshold
        }

        $existingProfiles = Get-AnycubicProcessProfiles -ConfigRoot $configRoot
        if ($existingProfiles.Count -eq 0) {
            throw "Kein bestehendes user-Profil in user\default\process\ gefunden, das als Vorlage (inherits/version) dienen kann. [$AnycubicBridgeWatermark]"
        }
        $targetMachine = if ($MachinePreset) { $MachinePreset } else { $mainConf.presets.machine }
        $template = Find-AnycubicTemplateForMachine -ConfigRoot $configRoot -MachineName $targetMachine -ExistingProfiles $existingProfiles
        $templateJsonForVersion = Get-Content -LiteralPath $template.FilePath -Raw -Encoding UTF8 | ConvertFrom-Json

        $systemTemplate = Find-AnycubicSystemProcessProfile -ConfigRoot $configRoot -Name $template.Inherits
        if (-not $systemTemplate -or -not $systemTemplate.setting_id) {
            throw "System-Profil '$($template.Inherits)' hat keine setting_id - kann base_id fuer die .info-Datei nicht sicher bestimmen. [$AnycubicBridgeWatermark]"
        }
        $baseId = $systemTemplate.setting_id

        $newJsonText = Build-AnycubicProcessJson -Name $ProfileName -Inherits $template.Inherits -Version $templateJsonForVersion.version -Values $rec.Values
        $newInfoText = Build-AnycubicInfoFile -BaseId $baseId

        $processDir = Join-Path $configRoot 'user\default\process'
        $newJsonPath = Join-Path $processDir ($ProfileName + '.json')
        $newInfoPath = Join-Path $processDir ($ProfileName + '.info')

        if (-not $Force) {
            "TROCKENLAUF (kein -Force) - es wurde NICHTS geschrieben. [$AnycubicBridgeWatermark]"
            "Ziel-Maschine: $targetMachine"
            "Vorlage: inherits $($template.Inherits) (base_id $baseId)"
            "Wuerde schreiben nach: $newJsonPath"
            "--- json ---"
            $newJsonText
            "Wuerde schreiben nach: $newInfoPath"
            "--- info ---"
            $newInfoText
        } else {
            $anycubicProcess = Get-Process -Name '*AnycubicSlicerNext*' -ErrorAction SilentlyContinue | Select-Object -First 1
            Write-AnycubicBridgeTextFile -Path $newJsonPath -Text $newJsonText
            Write-AnycubicBridgeTextFile -Path $newInfoPath -Text $newInfoText
            "Geschrieben: $newJsonPath"
            "Geschrieben: $newInfoPath"
            if ($anycubicProcess) {
                "Anycubic Slicer Next laeuft gerade (PID $($anycubicProcess.Id)) - neu starten, damit das Profil im Process-Dropdown erscheint."
            } else {
                "Anycubic Slicer Next starten - das Profil sollte im Process-Dropdown fuer '$($template.Inherits)'-kompatible Drucker erscheinen."
            }
            "Hinweis: automatische AKTIVIERUNG ist bei Anycubic Slicer Next NICHT implementiert (Hauptkonfig ist pruefsummengeschuetzt) - Profil manuell im Dropdown auswaehlen. [$AnycubicBridgeWatermark]"
        }
    }
}
