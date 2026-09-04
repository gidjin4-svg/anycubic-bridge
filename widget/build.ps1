<#
=====================================================================
 Druckbett-Monitor bauen
---------------------------------------------------------------------
 Kompiliert das Widget mit dem C#-Compiler, der in Windows enthalten ist.
 Es wird KEIN .NET SDK benoetigt.

 Ergebnis: dist\Druckbett-Monitor.exe samt allem, was dazugehoert.
=====================================================================
#>

[CmdletBinding()]
param(
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$dist = Join-Path $here 'dist'

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path -LiteralPath $csc)) { throw "C#-Compiler nicht gefunden: $csc" }

if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist -Force | Out-Null

# --- Icon aus einer echten Mesh-Vorschau erzeugen -------------------
# PNG-basierte ICO-Datei (ab Windows Vista erlaubt): Header + der PNG-Block.
function New-IcoFromPng {
    param([string]$PngPath, [string]$IcoPath)
    $png = [System.IO.File]::ReadAllBytes($PngPath)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]0)        # reserviert
    $bw.Write([uint16]1)        # Typ 1 = Icon
    $bw.Write([uint16]1)        # ein Bild
    $bw.Write([byte]0)          # Breite 0 = 256
    $bw.Write([byte]0)          # Hoehe 0 = 256
    $bw.Write([byte]0)          # Farben in der Palette
    $bw.Write([byte]0)          # reserviert
    $bw.Write([uint16]1)        # Farbebenen
    $bw.Write([uint16]32)       # Bit pro Pixel
    $bw.Write([uint32]$png.Length)
    $bw.Write([uint32]22)       # Offset der Bilddaten
    $bw.Write($png)
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($IcoPath, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

$iconPng = Join-Path $env:TEMP 'monitor-icon.png'
$bridge = Join-Path $root 'anycubic-bridge.ps1'
$iconMade = $false
try {
    & $bridge preview -PreviewSize 256 -OutFile $iconPng | Out-Null
    New-IcoFromPng -PngPath $iconPng -IcoPath (Join-Path $dist 'monitor.ico')
    $iconMade = $true
    "Icon aus aktueller Modell-Vorschau erzeugt."
} catch {
    "Hinweis: Icon konnte nicht erzeugt werden ($($_.Exception.Message)) - Widget laeuft trotzdem."
}

# --- Kompilieren ----------------------------------------------------
# WebView2-DLLs gehoeren Microsoft und liegen deshalb nicht im Repo - beim
# ersten Bauen werden sie vom offiziellen NuGet-Paket geholt.
$lib = Join-Path $here 'lib'
if (-not (Test-Path (Join-Path $lib 'Microsoft.Web.WebView2.Core.dll'))) {
    "WebView2-Paket wird von nuget.org geladen..."
    New-Item -ItemType Directory -Path $lib -Force | Out-Null
    $tmp = Join-Path $env:TEMP ('wv2-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $idx = Invoke-RestMethod -Uri 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json' -TimeoutSec 60
        $ver = ($idx.versions | Where-Object { $_ -notmatch '-' } | Select-Object -Last 1)
        $nupkg = Join-Path $tmp 'wv2.zip'
        Invoke-WebRequest -TimeoutSec 300 -OutFile $nupkg `
            -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$ver/microsoft.web.webview2.$ver.nupkg"
        Expand-Archive -Path $nupkg -DestinationPath (Join-Path $tmp 'pkg') -Force
        Copy-Item (Join-Path $tmp 'pkg\lib\net462\Microsoft.Web.WebView2.Core.dll') $lib -Force
        Copy-Item (Join-Path $tmp 'pkg\lib\net462\Microsoft.Web.WebView2.WinForms.dll') $lib -Force
        Copy-Item (Join-Path $tmp 'pkg\runtimes\win-x64\native\WebView2Loader.dll') $lib -Force
        Copy-Item (Join-Path $tmp 'pkg\LICENSE.txt') (Join-Path $lib 'WebView2-LICENSE.txt') -Force -ErrorAction SilentlyContinue
        "  WebView2 $ver bereit."
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$refs = @(
    (Join-Path $lib 'Microsoft.Web.WebView2.Core.dll'),
    (Join-Path $lib 'Microsoft.Web.WebView2.WinForms.dll')
)
foreach ($r in $refs) { if (-not (Test-Path -LiteralPath $r)) { throw "Fehlt: $r" } }

$exe = Join-Path $dist 'Druckbett-Monitor.exe'
$cscArgs = @(
    '/target:winexe'
    '/optimize+'
    "/out:$exe"
    '/reference:System.dll'
    '/reference:System.Drawing.dll'
    '/reference:System.Windows.Forms.dll'
)
foreach ($r in $refs) { $cscArgs += "/reference:$r" }
if ($iconMade) { $cscArgs += "/win32icon:$(Join-Path $dist 'monitor.ico')" }
$cscArgs += (Join-Path $here 'DruckbettMonitor.cs')

& $csc @cscArgs | ForEach-Object { if ($_ -match 'error|warning') { $_ } }
if (-not (Test-Path -LiteralPath $exe)) { throw "Kompilieren fehlgeschlagen." }

# --- Alles daneben legen, was zur Laufzeit gebraucht wird ------------
Copy-Item (Join-Path $here 'lib\*.dll') $dist -Force
Copy-Item $bridge $dist -Force
Copy-Item (Join-Path $root 'companion\druckbett-monitor.html') $dist -Force
Copy-Item (Join-Path $here 'lib\WebView2-LICENSE.txt') $dist -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $here 'install.ps1') $dist -Force
Copy-Item (Join-Path $root 'README.de.md') $dist -Force -ErrorAction SilentlyContinue

# --- Zum Verteilen packen -------------------------------------------
$zip = Join-Path $here 'Druckbett-Monitor.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $dist '*') -DestinationPath $zip
"Paket: $zip ($([Math]::Round((Get-Item $zip).Length/1MB,1)) MB)"

""
"Fertig: $exe"
"Groesse: $([Math]::Round((Get-Item $exe).Length/1KB)) KB"
Get-ChildItem $dist | Select-Object Name, @{n='KB';e={[Math]::Round($_.Length/1KB)}}
