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

            dashboardButton = MakeButton("Dashboard", 6);
            dashboardButton.Click += delegate { ShowDashboard(); };
            bar.Controls.Add(dashboardButton);

            chatButton = MakeButton("Chat", 104);
            chatButton.Click += delegate { ShowChat(); };
            if (chatUrl.Length == 0)
            {
                chatButton.Enabled = false;
                ToolTip tip = new ToolTip();
                tip.SetToolTip(chatButton,
                    "Kein Chat eingerichtet.\r\nDafuer braucht es ein eigenes Claude-Konto und ein eigenes\r\n" +
                    "veroeffentlichtes Artifact - Anleitung im README.");
            }
            bar.Controls.Add(chatButton);

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

            ShowDashboard();
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

            if (answer == DialogResult.Yes) { OpenExternally(uri); }
            else { ShowChat(); }
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
                        if (!showingChat && webView != null && webView.CoreWebView2 != null)
                        {
                            webView.CoreWebView2.Reload();
                        }
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
