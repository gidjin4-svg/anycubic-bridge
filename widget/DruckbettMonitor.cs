// =====================================================================
//  Druckbett-Monitor - Begleitfenster fuer Anycubic Slicer Next
// ---------------------------------------------------------------------
//  Eigenes Fenster (kein Browser-Tab) mit WebView2. Zeigt das lokale
//  Dashboard aus %APPDATA%\AnycubicBridge\monitor.html, das vom
//  Hintergrund-Watcher der Bridge aktuell gehalten wird - laeuft damit
//  offline.
//
//  Der Chat laeuft ebenfalls IM Fenster - das ist der Sinn eines eigenen
//  Programms. Sonderfall Anmeldung: Google verbietet sie in eingebetteten
//  Fenstern. Deshalb wird an dieser Stelle erklaert, dass die Anmeldung per
//  E-Mail-Code hier im Fenster funktioniert. Eine Anmeldung im externen
//  Browser wuerde dem Programm nichts nuetzen - die Sitzung bliebe dort.
//
//  Gebaut mit dem in Windows enthaltenen C#-Compiler, kein SDK noetig.
//  Siehe build.ps1.
// =====================================================================

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace AnycubicBridge
{
    public class MonitorForm : Form
    {
        private readonly string dataDir;
        private readonly string monitorPath;
        private readonly string dataFile;
        private readonly string settingsPath;

        // Kein fest eingebauter Link: der Chat laeuft ueber das EIGENE
        // Claude-Konto jedes Nutzers und dessen eigenes Artifact. Die Adresse
        // steht in settings.json, siehe README.
        private string chatUrl = "";

        private WebView2 webView;
        private Button dashboardButton;
        private Button chatButton;
        private Label statusLabel;
        private FileSystemWatcher fileWatcher;
        private bool showingChat;
        private bool claudeAvailable;

        public MonitorForm()
        {
            dataDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "AnycubicBridge");
            monitorPath = Path.Combine(dataDir, "monitor.html");
            dataFile = Path.Combine(dataDir, "dashboard-data.js");
            settingsPath = Path.Combine(dataDir, "settings.json");
            chatUrl = ReadChatUrl();

            Text = "Druckbett-Monitor";
            Width = 480;
            Height = 900;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(
                Math.Max(0, Screen.PrimaryScreen.WorkingArea.Right - 500),
                Screen.PrimaryScreen.WorkingArea.Top + 40);
            BackColor = Color.FromArgb(238, 241, 244);

            string iconPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "monitor.ico");
            if (File.Exists(iconPath))
            {
                try { Icon = new Icon(iconPath); } catch { }
            }

            BuildToolbar();
            BuildWebView();
            WatchDataFile();
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            // Erst hier initialisieren: vorher gibt es noch kein Fensterhandle,
            // und der Rueckruf aus dem Hintergrundthread laeuft dann ins Leere.
            InitializeWebView();
        }

        private void BuildToolbar()
        {
            Panel bar = new Panel();
            bar.Dock = DockStyle.Top;
            bar.Height = 34;
            bar.BackColor = Color.FromArgb(238, 241, 244);

            dashboardButton = MakeButton("Aktualisieren", 6);
            dashboardButton.Click += delegate { RefreshNow(); };
            bar.Controls.Add(dashboardButton);

            // Der Chat sitzt in der Anzeige selbst, sobald Claude Code da ist.
            // Der Knopf zur Online-Seite ist dann ueberfluessig und wuerde nur
            // verwirren - er erscheint nur als Ausweichweg ohne Claude Code.
            claudeAvailable = FindClaudeCli() != null;
            if (!claudeAvailable && chatUrl.Length > 0)
            {
                chatButton = MakeButton("Chat online", 104);
                chatButton.Click += delegate { ShowChat(); };
                bar.Controls.Add(chatButton);
            }

            statusLabel = new Label();
            statusLabel.AutoSize = false;
            statusLabel.Left = 200;
            statusLabel.Top = 9;
            statusLabel.Width = 260;
            statusLabel.Height = 20;
            statusLabel.ForeColor = Color.FromArgb(82, 98, 111);
            statusLabel.Font = new Font("Segoe UI", 8f);
            statusLabel.TextAlign = ContentAlignment.MiddleRight;
            statusLabel.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            bar.Controls.Add(statusLabel);

            Controls.Add(bar);
        }

        private Button MakeButton(string text, int left)
        {
            Button b = new Button();
            b.Text = text;
            b.Left = left;
            b.Top = 5;
            b.Width = 92;
            b.Height = 24;
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderColor = Color.FromArgb(199, 208, 218);
            b.BackColor = Color.White;
            b.ForeColor = Color.FromArgb(26, 36, 48);
            b.Font = new Font("Segoe UI", 8.5f);
            return b;
        }

        private void BuildWebView()
        {
            webView = new WebView2();
            webView.Dock = DockStyle.Fill;
            Controls.Add(webView);
            webView.BringToFront();
        }

        private void InitializeWebView()
        {
            // Eigenes Profil-Verzeichnis: so bleibt ein Claude-Login im
            // Chat-Fenster erhalten und stoert keinen anderen Browser.
            string profile = Path.Combine(dataDir, "webview");
            Directory.CreateDirectory(profile);

            webView.CoreWebView2InitializationCompleted += OnWebViewReady;

            CoreWebView2Environment.CreateAsync(null, profile, null)
                .ContinueWith(task =>
                {
                    if (task.IsFaulted)
                    {
                        BeginInvoke((MethodInvoker)delegate { ShowFatal(task.Exception); });
                        return;
                    }
                    BeginInvoke((MethodInvoker)delegate
                    {
                        try { webView.EnsureCoreWebView2Async(task.Result); }
                        catch (Exception ex) { ShowFatal(ex); }
                    });
                });
        }

        private void OnWebViewReady(object sender, CoreWebView2InitializationCompletedEventArgs e)
        {
            if (!e.IsSuccess) { ShowFatal(e.InitializationException); return; }

            webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            webView.CoreWebView2.Settings.IsStatusBarEnabled = false;

            // Popups (Anmeldefenster, externe Links) im selben Fenster zeigen,
            // damit man nicht aus dem Programm faellt.
            webView.CoreWebView2.NewWindowRequested += delegate (
                object s, CoreWebView2NewWindowRequestedEventArgs args)
            {
                args.Handled = true;
                if (HandleAuthUrl(args.Uri)) { return; }
                webView.CoreWebView2.Navigate(args.Uri);
                showingChat = true;
                UpdateStatus();
            };

            webView.CoreWebView2.NavigationStarting += delegate (
                object s, CoreWebView2NavigationStartingEventArgs args)
            {
                if (HandleAuthUrl(args.Uri)) { args.Cancel = true; }
            };

            // Die Anzeige schickt Chat-Fragen hierher; beantwortet werden sie
            // von der lokalen Claude-Code-Installation.
            webView.CoreWebView2.WebMessageReceived += OnPageMessage;

            if (bridgeTest) { RunBridgeTest(); return; }

            // Der Seite mitteilen, dass hier ein Chat moeglich ist - und erst
            // DANACH die Anzeige laden. Sonst waere die Seite unter Umstaenden
            // schon da, bevor die Kennzeichnung gesetzt ist, und der Chat bliebe
            // ausgeblendet.
            webView.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                "window.BRIDGE_HOST = { chat: " + (claudeAvailable ? "true" : "false") + " };")
                .ContinueWith(delegate
                {
                    try { BeginInvoke((MethodInvoker)delegate { ShowDashboard(); }); }
                    catch { }
                });
        }

        // Prueft den kompletten Weg: Seite -> Programm -> Claude Code -> zurueck
        // in die Seite. Aufruf: Druckbett-Monitor.exe --bridge-test
        public static bool bridgeTest;

        private void RunBridgeTest()
        {
            webView.CoreWebView2.NavigateToString("<html><body>Test</body></html>");
            webView.CoreWebView2.NavigationCompleted += delegate
            {
                webView.CoreWebView2.ExecuteScriptAsync(
                    "window.chrome.webview.addEventListener('message', function (e) {" +
                    "  document.title = 'ERGEBNIS:' + e.data;" +
                    "});" +
                    "window.chrome.webview.postMessage('frage:Antworte mit genau einem Wort: bruecke-ok');");

                Timer poll = new Timer();
                poll.Interval = 1000;
                int ticks = 0;
                poll.Tick += delegate
                {
                    ticks++;
                    string title = webView.CoreWebView2.DocumentTitle;
                    if (title != null && title.StartsWith("ERGEBNIS:"))
                    {
                        poll.Stop();
                        Console.WriteLine(title);
                        Application.Exit();
                    }
                    else if (ticks > 90)
                    {
                        poll.Stop();
                        Console.WriteLine("FEHLER: keine Antwort in 90 Sekunden");
                        Application.Exit();
                    }
                };
                poll.Start();
            };
        }

        private void OnPageMessage(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            string raw;
            try { raw = e.TryGetWebMessageAsString(); }
            catch { return; }
            if (raw == null || !raw.StartsWith("frage:")) { return; }

            string frage = raw.Substring("frage:".Length);

            // In einem eigenen Thread, damit das Fenster waehrenddessen bedienbar
            // bleibt - eine Antwort dauert einige Sekunden.
            System.Threading.ThreadPool.QueueUserWorkItem(delegate
            {
                string antwort;
                try { antwort = AskClaude(frage); }
                catch (Exception ex) { antwort = "Fehler: " + ex.Message; }

                try
                {
                    BeginInvoke((MethodInvoker)delegate
                    {
                        if (webView == null || webView.CoreWebView2 == null) { return; }
                        // Aus der Antwort eine eventuelle Aktion herausloesen -
                        // sie wird nicht mitangezeigt, sondern nachgefragt.
                        string rest = HandleActionLine(antwort);
                        webView.CoreWebView2.PostWebMessageAsString("antwort:" + rest);
                    });
                }
                catch { }
            });
        }

        // Der Chat kann eine Aktion vorschlagen, indem er als letzte Zeile
        //   AKTION: writeprofile | <Name> | key=wert;key=wert
        // anhaengt. Ausgefuehrt wird sie erst nach Rueckfrage - der Chat
        // schreibt nichts ungefragt in den Slicer.
        private string HandleActionLine(string antwort)
        {
            if (antwort == null) { return ""; }
            int pos = antwort.LastIndexOf("AKTION: writeprofile", StringComparison.OrdinalIgnoreCase);
            if (pos < 0) { return antwort; }

            string zeile = antwort.Substring(pos).Split('\n')[0].Trim();
            string text = antwort.Substring(0, pos).TrimEnd();

            string[] teile = zeile.Split('|');
            if (teile.Length < 3)
            {
                return text + "\n\n(Eine Aktion war angehaengt, aber unvollstaendig - nichts geschrieben.)";
            }
            string name = teile[1].Trim();
            string werte = teile[2].Trim();
            if (name.Length == 0 || werte.Length == 0)
            {
                return text + "\n\n(Eine Aktion war angehaengt, aber unvollstaendig - nichts geschrieben.)";
            }

            DialogResult antwortDlg = MessageBox.Show(
                "Profil \"" + name + "\" in Anycubic Slicer Next anlegen?\r\n\r\n" +
                werte.Replace(";", "\r\n") + "\r\n\r\n" +
                "Vorhandene Profile werden nicht veraendert.\r\n\r\n" +
                "WICHTIG: Anycubic Slicer Next liest Profile nur beim Start ein. " +
                "Das neue Profil erscheint erst nach einem Neustart des Slicers - " +
                "dann im Prozess-Dropdown auswaehlen.",
                "Werte uebernehmen", MessageBoxButtons.YesNo, MessageBoxIcon.Question);

            if (antwortDlg != DialogResult.Yes)
            {
                return text + "\n\n(Nicht geschrieben - abgebrochen.)";
            }

            try
            {
                string ergebnis = RunBridge("writeprofile -ProfileName \"" + name +
                                            "\" -Values \"" + werte + "\" -Force");
                return text + "\n\n" + ergebnis;
            }
            catch (Exception ex)
            {
                return text + "\n\nSchreiben fehlgeschlagen: " + ex.Message;
            }
        }

        private string RunBridge(string argumente)
        {
            string bridge = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "anycubic-bridge.ps1");
            if (!File.Exists(bridge)) { throw new Exception("anycubic-bridge.ps1 nicht gefunden."); }

            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe");
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + bridge + "\" " + argumente;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = System.Text.Encoding.UTF8;

            using (Process proc = new Process())
            {
                proc.StartInfo = psi;
                System.Text.StringBuilder o = new System.Text.StringBuilder();
                System.Text.StringBuilder err = new System.Text.StringBuilder();
                proc.OutputDataReceived += delegate (object s, DataReceivedEventArgs a) { if (a.Data != null) { o.AppendLine(a.Data); } };
                proc.ErrorDataReceived += delegate (object s, DataReceivedEventArgs a) { if (a.Data != null) { err.AppendLine(a.Data); } };
                proc.Start();
                proc.BeginOutputReadLine();
                proc.BeginErrorReadLine();
                proc.WaitForExit(120000);

                string ausgabe = o.ToString().Trim();
                if (ausgabe.Length > 0) { return ausgabe; }
                string fehler = err.ToString().Trim();
                if (fehler.Length > 0) { throw new Exception(fehler); }
                return "(keine Ausgabe)";
            }
        }

        private void OnDashboardLoaded(object sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            webView.CoreWebView2.NavigationCompleted -= OnDashboardLoaded;
            PushDataToPage();
        }

        // Daten aktiv in die Seite reichen. Ueber file:// wuerde ein Neuladen
        // die Datendatei aus dem Zwischenspeicher holen und die Anzeige bliebe
        // auf altem Stand - genau deshalb half vorher nur ein Neustart.
        private void PushDataToPage()
        {
            if (webView == null || webView.CoreWebView2 == null) { return; }
            if (!File.Exists(dataFile)) { return; }
            try
            {
                string js = File.ReadAllText(dataFile);
                if (js.Length > 0 && js[0] == '﻿') { js = js.Substring(1); }
                webView.CoreWebView2.ExecuteScriptAsync(
                    js + "\nif (window.bridgeRefresh) { window.bridgeRefresh(); }");
            }
            catch { }
        }

        // Die Bridge einmal laufen lassen und danach die Anzeige auffrischen.
        private void RefreshNow()
        {
            string bridge = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "anycubic-bridge.ps1");
            if (!File.Exists(bridge)) { PushDataToPage(); return; }

            statusLabel.Text = "aktualisiere...";
            System.Threading.ThreadPool.QueueUserWorkItem(delegate
            {
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo("powershell.exe");
                    psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + bridge +
                                    "\" dashboard -OutFile \"" + dataFile + "\"";
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    using (Process p = Process.Start(psi)) { p.WaitForExit(120000); }
                }
                catch { }

                try
                {
                    BeginInvoke((MethodInvoker)delegate
                    {
                        PushDataToPage();
                        UpdateStatus();
                    });
                }
                catch { }
            });
        }

        private void ShowDashboard()
        {
            showingChat = false;
            if (!File.Exists(monitorPath))
            {
                webView.CoreWebView2.NavigateToString(
                    "<body style='font-family:Segoe UI;padding:24px;color:#1a2430'>" +
                    "<h2>Noch nicht eingerichtet</h2>" +
                    "<p>Bitte einmal <code>install-widget.ps1</code> ausfuehren.</p>" +
                    "<p style='color:#52626f'>Erwartet: " + monitorPath + "</p></body>");
            }
            else
            {
                webView.CoreWebView2.Navigate(new Uri(monitorPath).AbsoluteUri);
                // Nach dem Laden die aktuellen Daten reinreichen.
                webView.CoreWebView2.NavigationCompleted += OnDashboardLoaded;
            }
            UpdateStatus();
        }

        // Der Chat laeuft IM Fenster - das ist der Sinn eines eigenen Programms.
        // Nur die Anmeldung ist der Sonderfall, siehe HandleAuthUrl.
        private void ShowChat()
        {
            if (chatUrl.Length == 0) { return; }
            showingChat = true;
            webView.CoreWebView2.Navigate(chatUrl);
            UpdateStatus();
        }

        // Google verbietet die Anmeldung in eingebetteten Fenstern. Statt den
        // Nutzer in eine Sackgasse laufen zu lassen, wird hier erklaert, was
        // funktioniert: die Anmeldung per E-Mail-Code laeuft direkt hier im
        // Fenster - nur dann bleibt die Sitzung auch im Programm bestehen.
        // Eine Anmeldung im externen Browser wuerde dem Fenster nichts nuetzen,
        // weil sie in dessen eigener Sitzung landet.
        private bool HandleAuthUrl(string uri)
        {
            if (uri == null) { return false; }
            if (uri.IndexOf("accounts.google.com", StringComparison.OrdinalIgnoreCase) < 0) { return false; }

            DialogResult answer = MessageBox.Show(
                "Google laesst die Anmeldung in eingebetteten Fenstern nicht zu.\r\n\r\n" +
                "Melde dich hier im Fenster stattdessen mit E-Mail und Code an - dann " +
                "bleibt die Anmeldung im Programm erhalten.\r\n\r\n" +
                "Trotzdem im Browser oeffnen? (Die Anmeldung gilt dann nur dort, " +
                "nicht in diesem Fenster.)",
                "Anmeldung", MessageBoxButtons.YesNo, MessageBoxIcon.Information,
                MessageBoxDefaultButton.Button2);

            // Bei "Nein" bewusst NICHT zurueckspringen: ein erneutes Navigieren
            // wertet die Anmeldeseite als fehlgeschlagenen Versuch und zeigt
            // eine rote Fehlermeldung. Einfach stehenbleiben, dann kann direkt
            // das E-Mail-Feld benutzt werden.
            if (answer == DialogResult.Yes) { OpenExternally(uri); }
            return true;
        }

        private void OpenExternally(string url)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(url);
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Konnte den Browser nicht oeffnen:\r\n" + ex.Message +
                                "\r\n\r\nAdresse:\r\n" + url,
                                "Druckbett-Monitor", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        // --- Chat ueber die lokale Claude-Code-Installation ------------------
        // Der eleganteste Weg zum Chat im eigenen Fenster: Claude Code ist auf
        // dem Rechner bereits angemeldet. Ein Aufruf im Hintergrund braucht
        // deshalb weder Login noch API-Schluessel und laeuft ueber das
        // bestehende Abo. Antwortzeit rund 5-10 Sekunden.

        private static string FindClaudeCli()
        {
            string path = Environment.GetEnvironmentVariable("PATH");
            if (path == null) { return null; }
            foreach (string dir in path.Split(';'))
            {
                if (dir.Length == 0) { continue; }
                try
                {
                    string candidate = Path.Combine(dir.Trim(), "claude.cmd");
                    if (File.Exists(candidate)) { return candidate; }
                }
                catch { }
            }
            return null;
        }

        public string AskClaude(string prompt)
        {
            string cli = FindClaudeCli();
            if (cli == null) { throw new Exception("Claude Code wurde nicht gefunden."); }

            ProcessStartInfo psi = new ProcessStartInfo(cli);
            psi.Arguments = "-p";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = System.Text.Encoding.UTF8;

            using (Process proc = new Process())
            {
                proc.StartInfo = psi;

                // Beide Ausgabekanaele NEBENLAEUFIG lesen. Nacheinander zu lesen
                // blockiert, sobald der andere Puffer volllaeuft - dann haengt
                // die Antwort fuer immer.
                System.Text.StringBuilder outBuf = new System.Text.StringBuilder();
                System.Text.StringBuilder errBuf = new System.Text.StringBuilder();
                proc.OutputDataReceived += delegate (object s, DataReceivedEventArgs a)
                {
                    if (a.Data != null) { outBuf.AppendLine(a.Data); }
                };
                proc.ErrorDataReceived += delegate (object s, DataReceivedEventArgs a)
                {
                    if (a.Data != null) { errBuf.AppendLine(a.Data); }
                };

                proc.Start();
                proc.BeginOutputReadLine();
                proc.BeginErrorReadLine();

                // Die Frage ueber die Standardeingabe schicken statt als
                // Argument: so koennen Anfuehrungszeichen und Umbrueche im Text
                // nichts zerlegen.
                proc.StandardInput.Write(prompt);
                proc.StandardInput.Close();

                if (!proc.WaitForExit(180000))
                {
                    try { proc.Kill(); } catch { }
                    throw new Exception("Claude Code hat nicht geantwortet (Zeitueberschreitung).");
                }

                string output = outBuf.ToString().Trim();
                string error = errBuf.ToString().Trim();
                if (output.Length > 0) { return output; }
                if (error.Length > 0) { throw new Exception(error); }
                return "(keine Antwort)";
            }
        }

        private string ReadChatUrl()
        {
            // Bewusst ohne JSON-Bibliothek: eine Zeile aus einer winzigen Datei.
            try
            {
                if (!File.Exists(settingsPath)) { return ""; }
                string text = File.ReadAllText(settingsPath);
                int key = text.IndexOf("\"chatUrl\"", StringComparison.OrdinalIgnoreCase);
                if (key < 0) { return ""; }
                int colon = text.IndexOf(':', key);
                if (colon < 0) { return ""; }
                int first = text.IndexOf('"', colon + 1);
                if (first < 0) { return ""; }
                int last = text.IndexOf('"', first + 1);
                if (last < 0) { return ""; }
                string value = text.Substring(first + 1, last - first - 1).Trim();
                return value.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? value : "";
            }
            catch { return ""; }
        }

        private void UpdateStatus()
        {
            if (showingChat) { statusLabel.Text = "Chat - dein Claude-Konto"; return; }
            statusLabel.Text = File.Exists(dataFile)
                ? "Daten von " + File.GetLastWriteTime(dataFile).ToString("HH:mm:ss")
                : "keine Daten";
        }

        private void WatchDataFile()
        {
            if (!Directory.Exists(dataDir)) { return; }
            fileWatcher = new FileSystemWatcher(dataDir, "dashboard-data.js");
            fileWatcher.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size;
            fileWatcher.Changed += delegate
            {
                // Der Watcher meldet oft mehrfach pro Schreibvorgang; kurz warten,
                // damit die Datei vollstaendig geschrieben ist.
                BeginInvoke((MethodInvoker)delegate
                {
                    Timer t = new Timer();
                    t.Interval = 400;
                    t.Tick += delegate
                    {
                        t.Stop();
                        t.Dispose();
                        PushDataToPage();
                        UpdateStatus();
                    };
                    t.Start();
                });
            };
            fileWatcher.EnableRaisingEvents = true;
        }

        private void ShowFatal(Exception ex)
        {
            string message = ex == null ? "Unbekannter Fehler" : ex.Message;
            MessageBox.Show(
                "WebView2 konnte nicht starten.\n\n" + message +
                "\n\nIst die WebView2-Runtime installiert?",
                "Druckbett-Monitor", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        [STAThread]
        public static void Main(string[] args)
        {
            // Diagnose: prueft die Chat-Anbindung ueber genau denselben Weg,
            // den auch das Fenster benutzt. Aufruf:
            //   Druckbett-Monitor.exe --chat-test "deine frage"
            if (Array.IndexOf(args, "--chat-test") >= 0)
            {
                int i = Array.IndexOf(args, "--chat-test");
                string frage = (i + 1 < args.Length) ? args[i + 1] : "Antworte mit einem Wort: bereit";
                MonitorForm form = new MonitorForm();
                try
                {
                    string antwort = form.AskClaude(frage);
                    Console.WriteLine("OK: " + antwort);
                }
                catch (Exception ex)
                {
                    Console.WriteLine("FEHLER: " + ex.Message);
                }
                return;
            }

            bridgeTest = Array.IndexOf(args, "--bridge-test") >= 0;

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string bridge = Path.Combine(baseDir, "anycubic-bridge.ps1");

            bool noWatcher = Array.IndexOf(args, "--kein-watcher") >= 0;
            bool startSlicer = Array.IndexOf(args, "--mit-slicer") >= 0;

            if (!noWatcher && File.Exists(bridge))
            {
                // Der Watcher haelt die Daten aktuell. Mehrfachstart ist
                // unkritisch: die Bridge laesst per Mutex nur einen zu.
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo("powershell.exe");
                    psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \""
                                    + bridge + "\" watch";
                    psi.WindowStyle = ProcessWindowStyle.Hidden;
                    psi.CreateNoWindow = true;
                    psi.UseShellExecute = false;
                    Process.Start(psi);
                }
                catch { }
            }

            if (startSlicer)
            {
                try
                {
                    string slicer = @"C:\Program Files\AnycubicSlicerNext\AnycubicSlicerNext.exe";
                    if (File.Exists(slicer) && Process.GetProcessesByName("AnycubicSlicerNext").Length == 0)
                    {
                        Process.Start(slicer);
                    }
                }
                catch { }
            }

            Application.Run(new MonitorForm());
        }
    }
}
