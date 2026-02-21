using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace StripedPrinter;

/// <summary>
/// System tray application. Port of AppDelegate.swift (409 lines).
/// WinForms ApplicationContext with NotifyIcon, context menu, and dialogs.
/// </summary>
internal sealed class TrayApp : ApplicationContext
{
    private readonly NotifyIcon _notifyIcon;
    private readonly PrinterManager _printerManager;
    private readonly BrowserPrintApi _api;
    private HttpServer? _httpServer;
    private HttpServer? _httpsServer;

    public PrinterManager PrinterManager => _printerManager;

    public TrayApp()
    {
        _printerManager = new PrinterManager();
        _api = new BrowserPrintApi(_printerManager);
        _printerManager.PrintersChanged += RebuildMenu;

        _notifyIcon = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "Striped Printer",
            Visible = true,
        };

        _printerManager.LoadManualPrinters();
        StartServers();
        RebuildMenu();

        // Auto-scan local subnets
        _ = Task.Run(async () =>
        {
            var (subnets, _) = PrinterManager.GetLocalNetworkInfo();
            if (subnets.Count > 0)
            {
                await _printerManager.ScanSubnetsAsync(subnets);
            }
        });
    }

    // MARK: - Icon

    private static Icon LoadIcon()
    {
        // Try loading embedded resource
        var assembly = typeof(TrayApp).Assembly;
        var stream = assembly.GetManifestResourceStream("StripedPrinter.Resources.printer.ico");
        if (stream != null)
            return new Icon(stream);

        // Fallback: use system printer icon
        return SystemIcons.Application;
    }

    // MARK: - Context Menu

    private void RebuildMenu()
    {
        if (_notifyIcon.ContextMenuStrip != null && _notifyIcon.ContextMenuStrip.InvokeRequired)
        {
            _notifyIcon.ContextMenuStrip.Invoke(RebuildMenu);
            return;
        }

        var menu = new ContextMenuStrip();

        // Title
        var title = new ToolStripMenuItem("Striped Printer") { Enabled = false };
        menu.Items.Add(title);
        menu.Items.Add(new ToolStripSeparator());

        // Server status
        var httpStatus = new ToolStripMenuItem("HTTP  :9100  \u2713") { Enabled = false };
        menu.Items.Add(httpStatus);

        var httpsLabel = _httpsServer != null ? "HTTPS :9101  \u2713" : "HTTPS :9101  ...";
        var httpsStatus = new ToolStripMenuItem(httpsLabel) { Enabled = false };
        menu.Items.Add(httpsStatus);

        menu.Items.Add(new ToolStripSeparator());

        // Printers section
        var printersHeader = new ToolStripMenuItem("Printers") { Enabled = false };
        menu.Items.Add(printersHeader);

        var printers = _printerManager.AllPrinters;
        var defaultUid = _printerManager.DefaultPrinterUid;
        var manualHosts = new HashSet<string>(_printerManager.ManualPrinters.Select(p => p.Host));

        if (printers.Count == 0)
        {
            menu.Items.Add(new ToolStripMenuItem("  No printers found") { Enabled = false });
            menu.Items.Add(new ToolStripMenuItem("  Use Scan Network or Add Printer") { Enabled = false });
        }
        else
        {
            foreach (var printer in printers)
            {
                var source = manualHosts.Contains(printer.Host) ? "manual" : "discovered";
                var uid = printer.ToDevice().Uid;
                var isDefault = uid == defaultUid || (defaultUid == null && printer.Equals(printers[0]));

                var item = new ToolStripMenuItem($"  {printer.Name} \u2014 {printer.Host} [{source}]");
                item.Checked = isDefault;
                item.Click += (_, _) =>
                {
                    _printerManager.SetDefaultPrinter(uid);
                    RebuildMenu();
                };
                menu.Items.Add(item);
            }
        }

        menu.Items.Add(new ToolStripSeparator());

        // Actions
        var addPrinter = new ToolStripMenuItem("Add Printer...");
        addPrinter.Click += (_, _) => ShowAddPrinterDialog();
        menu.Items.Add(addPrinter);

        var scanNetwork = new ToolStripMenuItem("Scan Network...");
        scanNetwork.Click += (_, _) => ShowScanNetworkDialog();
        menu.Items.Add(scanNetwork);

        var refresh = new ToolStripMenuItem("Refresh Discovery");
        refresh.Click += (_, _) =>
        {
            _ = Task.Run(async () =>
            {
                var (subnets, _) = PrinterManager.GetLocalNetworkInfo();
                if (subnets.Count > 0)
                    await _printerManager.ScanSubnetsAsync(subnets);
            });
        };
        menu.Items.Add(refresh);

        // Remove Printer submenu (manual printers only)
        var manual = _printerManager.ManualPrinters;
        if (manual.Count > 0)
        {
            menu.Items.Add(new ToolStripSeparator());
            var removeHeader = new ToolStripMenuItem("Remove Printer") { Enabled = false };
            menu.Items.Add(removeHeader);

            foreach (var printer in manual)
            {
                var p = printer; // capture
                var item = new ToolStripMenuItem($"  \u2715 {printer.Name} ({printer.Host})");
                item.Click += (_, _) =>
                {
                    _printerManager.RemoveManualPrinter(p);
                    RebuildMenu();
                };
                menu.Items.Add(item);
            }
        }

        menu.Items.Add(new ToolStripSeparator());

        var quit = new ToolStripMenuItem("Quit");
        quit.Click += (_, _) =>
        {
            _notifyIcon.Visible = false;
            _httpServer?.Dispose();
            _httpsServer?.Dispose();
            Application.Exit();
        };
        menu.Items.Add(quit);

        _notifyIcon.ContextMenuStrip = menu;
    }

    // MARK: - Add Printer Dialog

    private void ShowAddPrinterDialog()
    {
        using var form = new Form
        {
            Text = "Add Printer",
            Width = 360,
            Height = 220,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MaximizeBox = false,
            MinimizeBox = false,
        };

        var nameLabel = new Label { Text = "Printer Name:", Left = 15, Top = 15, Width = 100 };
        var nameBox = new TextBox { Left = 120, Top = 12, Width = 210 };

        var hostLabel = new Label { Text = "IP Address:", Left = 15, Top = 48, Width = 100 };
        var hostBox = new TextBox { Left = 120, Top = 45, Width = 210 };

        var portLabel = new Label { Text = "Port:", Left = 15, Top = 81, Width = 100 };
        var portBox = new TextBox { Left = 120, Top = 78, Width = 210, Text = "9100" };

        var addButton = new Button { Text = "Add", Left = 135, Top = 125, Width = 90, DialogResult = DialogResult.OK };
        var cancelButton = new Button { Text = "Cancel", Left = 240, Top = 125, Width = 90, DialogResult = DialogResult.Cancel };

        form.Controls.AddRange([nameLabel, nameBox, hostLabel, hostBox, portLabel, portBox, addButton, cancelButton]);
        form.AcceptButton = addButton;
        form.CancelButton = cancelButton;

        if (form.ShowDialog() == DialogResult.OK)
        {
            var host = hostBox.Text.Trim();
            var port = ushort.TryParse(portBox.Text.Trim(), out var p) ? p : (ushort)9100;
            var name = string.IsNullOrWhiteSpace(nameBox.Text) ? host : nameBox.Text.Trim();

            if (!string.IsNullOrEmpty(host))
            {
                _printerManager.AddManualPrinter(name, host, port);
                Log($"Added manual printer: {name} at {host}:{port}");
            }
        }
    }

    // MARK: - Scan Network Dialog

    private void ShowScanNetworkDialog()
    {
        var (subnets, _) = PrinterManager.GetLocalNetworkInfo();

        using var form = new Form
        {
            Text = "Scan Network for Printers",
            Width = 400,
            Height = 170,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MaximizeBox = false,
            MinimizeBox = false,
        };

        var label = new Label
        {
            Text = "Subnets to scan (comma-separated):",
            Left = 15,
            Top = 15,
            Width = 350,
        };
        var subnetBox = new TextBox
        {
            Left = 15,
            Top = 40,
            Width = 350,
            Text = string.Join(", ", subnets),
        };

        var scanButton = new Button { Text = "Scan", Left = 165, Top = 80, Width = 90, DialogResult = DialogResult.OK };
        var cancelButton = new Button { Text = "Cancel", Left = 270, Top = 80, Width = 90, DialogResult = DialogResult.Cancel };

        form.Controls.AddRange([label, subnetBox, scanButton, cancelButton]);
        form.AcceptButton = scanButton;
        form.CancelButton = cancelButton;

        if (form.ShowDialog() == DialogResult.OK)
        {
            var scanSubnets = subnetBox.Text
                .Split(',')
                .Select(s => s.Trim())
                .Where(s => !string.IsNullOrEmpty(s))
                .ToList();

            if (scanSubnets.Count > 0)
            {
                Log($"Scanning subnets: {string.Join(", ", scanSubnets)}");
                _notifyIcon.Text = "Striped Printer (scanning...)";

                _ = Task.Run(async () =>
                {
                    await _printerManager.ScanSubnetsAsync(scanSubnets);
                    _notifyIcon.Text = "Striped Printer";
                });
            }
        }
    }

    // MARK: - Printer Picker Dialog (for .zpl files)

    public NetworkPrinter? ShowPrinterPicker(List<NetworkPrinter> printers, string? defaultUid)
    {
        using var form = new Form
        {
            Text = "Select Printer",
            Width = 400,
            Height = 150,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MaximizeBox = false,
            MinimizeBox = false,
        };

        var label = new Label { Text = "Choose which printer to send this file to:", Left = 15, Top = 15, Width = 350 };
        var combo = new ComboBox
        {
            Left = 15,
            Top = 40,
            Width = 350,
            DropDownStyle = ComboBoxStyle.DropDownList,
        };

        foreach (var printer in printers)
        {
            combo.Items.Add($"{printer.Name} \u2014 {printer.Host}:{printer.Port}");
        }

        // Pre-select default
        var defaultIdx = 0;
        if (defaultUid != null)
        {
            var idx = printers.FindIndex(p => p.ToDevice().Uid == defaultUid);
            if (idx >= 0) defaultIdx = idx;
        }
        combo.SelectedIndex = defaultIdx;

        var printButton = new Button { Text = "Print", Left = 165, Top = 75, Width = 90, DialogResult = DialogResult.OK };
        var cancelButton = new Button { Text = "Cancel", Left = 270, Top = 75, Width = 90, DialogResult = DialogResult.Cancel };

        form.Controls.AddRange([label, combo, printButton, cancelButton]);
        form.AcceptButton = printButton;
        form.CancelButton = cancelButton;

        if (form.ShowDialog() == DialogResult.OK && combo.SelectedIndex >= 0 && combo.SelectedIndex < printers.Count)
        {
            return printers[combo.SelectedIndex];
        }

        return null;
    }

    // MARK: - ZPL File Handling

    public void SendZplFile(string filepath)
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(filepath);
        }
        catch
        {
            MessageBox.Show($"Could not read {filepath}", "Cannot Read File",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        var printers = _printerManager.AllPrinters;
        if (printers.Count == 0)
        {
            MessageBox.Show("Add a printer using the system tray icon, or scan your network first.",
                "No Printers Found", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        NetworkPrinter printer;
        if (printers.Count == 1)
        {
            printer = printers[0];
        }
        else
        {
            var picked = ShowPrinterPicker(printers, _printerManager.DefaultPrinterUid);
            if (picked == null) return;
            printer = picked;
        }

        var filename = Path.GetFileName(filepath);

        _ = Task.Run(async () =>
        {
            try
            {
                var conn = new PrinterConnection(printer.Host, printer.Port);
                await conn.SendAsync(data);
                Log($"Sent {filename} to {printer.Name} ({printer.Host}:{printer.Port})");

                MessageBox.Show($"{filename} \u2192 {printer.Host}:{printer.Port}",
                    $"Sent to {printer.Name}", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex)
            {
                Log($"Failed to send {filename}: {ex.Message}");

                MessageBox.Show($"Could not send {filename} to {printer.Name}:\n{ex.Message}",
                    "Print Failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        });
    }

    // MARK: - Server Lifecycle

    private void StartServers()
    {
        // Start HTTP immediately
        _httpServer = new HttpServer(9100);
        _api.RegisterRoutes(_httpServer);

        try
        {
            _httpServer.Start();
            Log("HTTP server started on port 9100");
        }
        catch (Exception ex)
        {
            Log($"Failed to start HTTP server: {ex.Message}");

            _notifyIcon.BalloonTipTitle = "Striped Printer";
            _notifyIcon.BalloonTipText = $"Port 9100 is already in use. Is another instance running?";
            _notifyIcon.BalloonTipIcon = ToolTipIcon.Warning;
            _notifyIcon.ShowBalloonTip(5000);
        }

        // Load TLS cert and start HTTPS asynchronously
        _ = Task.Run(() =>
        {
            var tlsManager = new TlsManager();
            var cert = tlsManager.GetCertificate();
            if (cert == null)
            {
                Log("HTTPS server not started (no TLS certificate)");
                return;
            }

            _httpsServer = new HttpServer(9101, useTls: true, certificate: cert);
            _api.RegisterRoutes(_httpsServer);

            try
            {
                _httpsServer.Start();
                Log("HTTPS server started on port 9101");
                RebuildMenu();
            }
            catch (Exception ex)
            {
                Log($"Failed to start HTTPS server: {ex.Message}");
            }
        });
    }

    // MARK: - Cleanup

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _notifyIcon.Visible = false;
            _notifyIcon.Dispose();
            _httpServer?.Dispose();
            _httpsServer?.Dispose();
        }
        base.Dispose(disposing);
    }

    private static void Log(string message)
    {
        Console.WriteLine($"[StripedPrinter:App] {message}");
    }
}
