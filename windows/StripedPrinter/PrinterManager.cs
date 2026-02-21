using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace StripedPrinter;

/// <summary>
/// Manages printer discovery (subnet scanner), TCP connections, and persistence.
/// Port of PrinterManager.swift (673 lines) — all four responsibilities:
/// persistence, subnet scanner, TCP connection pool, deduplication.
/// </summary>
internal sealed class PrinterManager
{
    private readonly object _lock = new();
    private List<NetworkPrinter> _manualPrinters = [];
    private List<NetworkPrinter> _scannedPrinters = [];
    private string? _defaultPrinterUid;

    public event Action? PrintersChanged;

    // MARK: - Properties

    public IReadOnlyList<NetworkPrinter> ManualPrinters
    {
        get { lock (_lock) return [.. _manualPrinters]; }
    }

    public IReadOnlyList<NetworkPrinter> ScannedPrinters
    {
        get { lock (_lock) return [.. _scannedPrinters]; }
    }

    /// <summary>
    /// All printers (manual + scanned, deduplicated by host+port).
    /// Manual printers take priority.
    /// </summary>
    public List<NetworkPrinter> AllPrinters
    {
        get
        {
            lock (_lock)
            {
                var combined = new List<NetworkPrinter>(_manualPrinters);
                foreach (var printer in _scannedPrinters)
                {
                    if (!combined.Any(p => p.Host == printer.Host && p.Port == printer.Port))
                        combined.Add(printer);
                }
                return combined;
            }
        }
    }

    public List<PrinterDevice> AllDevices => AllPrinters.Select(p => p.ToDevice()).ToList();

    public PrinterDevice? DefaultDevice
    {
        get
        {
            var devices = AllDevices;
            if (_defaultPrinterUid != null)
                return devices.FirstOrDefault(d => d.Uid == _defaultPrinterUid);
            return devices.FirstOrDefault();
        }
    }

    public string? DefaultPrinterUid
    {
        get { lock (_lock) return _defaultPrinterUid; }
    }

    // MARK: - Find Printer

    public NetworkPrinter? FindPrinter(PrinterDevice device)
    {
        var all = AllPrinters;
        return all.FirstOrDefault(p => p.ToDevice().Uid == device.Uid)
            ?? all.FirstOrDefault(p => p.ToDevice().Name == device.Name);
    }

    // MARK: - Manual Printer Management

    public void AddManualPrinter(string name, string host, ushort port = 9100)
    {
        var printer = new NetworkPrinter(name, host, port);
        lock (_lock)
        {
            if (_manualPrinters.Any(p => p.Host == printer.Host && p.Port == printer.Port))
                return;
            _manualPrinters.Add(printer);
        }
        SaveManualPrinters();
        PrintersChanged?.Invoke();
    }

    public void RemoveManualPrinter(NetworkPrinter printer)
    {
        lock (_lock)
        {
            _manualPrinters.RemoveAll(p => p.Host == printer.Host && p.Port == printer.Port);
        }
        SaveManualPrinters();
        PrintersChanged?.Invoke();
    }

    // MARK: - Persistence

    private static string ConfigDir
    {
        get
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "StripedPrinter");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public void LoadManualPrinters()
    {
        var path = Path.Combine(ConfigDir, "printers.json");
        if (File.Exists(path))
        {
            try
            {
                var json = File.ReadAllText(path);
                var saved = JsonSerializer.Deserialize<List<SavedPrinter>>(json);
                if (saved != null)
                {
                    lock (_lock)
                    {
                        _manualPrinters = saved.Select(s =>
                            new NetworkPrinter(s.Name, s.Host, s.Port)).ToList();
                    }
                }
            }
            catch (Exception ex)
            {
                Log($"Failed to load printers.json: {ex.Message}");
            }
        }

        // Try legacy migration if no manual printers
        if (_manualPrinters.Count == 0)
            MigrateLegacyConfig();

        // Load default printer UID
        var defaultPath = Path.Combine(ConfigDir, "default.txt");
        if (File.Exists(defaultPath))
        {
            lock (_lock)
            {
                _defaultPrinterUid = File.ReadAllText(defaultPath).Trim();
            }
        }
    }

    /// <summary>
    /// Migrate printers from legacy iZPL %USERPROFILE%\.zplprinters config file.
    /// </summary>
    private void MigrateLegacyConfig()
    {
        var legacyPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".zplprinters");

        if (!File.Exists(legacyPath)) return;

        try
        {
            var lines = File.ReadAllLines(legacyPath)
                .Select(l => l.Trim())
                .Where(l => !string.IsNullOrEmpty(l))
                .ToList();

            if (lines.Count == 0) return;

            foreach (var line in lines)
            {
                var parts = line.Split(':');
                if (parts.Length < 2 || !ushort.TryParse(parts[1], out var port))
                    continue;
                var host = parts[0];
                var name = parts.Length >= 3
                    ? string.Join(":", parts.Skip(2))
                    : host;
                AddManualPrinter(name, host, port);
            }

            // Rename so migration only runs once
            var migratedPath = Path.Combine(
                Path.GetDirectoryName(legacyPath)!,
                ".zplprinters.migrated");
            File.Move(legacyPath, migratedPath);
            Log($"Migrated {lines.Count} printer(s) from .zplprinters");
        }
        catch (Exception ex)
        {
            Log($"Legacy migration failed: {ex.Message}");
        }
    }

    private void SaveManualPrinters()
    {
        try
        {
            List<SavedPrinter> saved;
            lock (_lock)
            {
                saved = _manualPrinters.Select(p =>
                    new SavedPrinter { Name = p.Name, Host = p.Host, Port = p.Port }).ToList();
            }
            var json = JsonSerializer.Serialize(saved, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(Path.Combine(ConfigDir, "printers.json"), json);
        }
        catch (Exception ex)
        {
            Log($"Failed to save printers.json: {ex.Message}");
        }
    }

    public void SetDefaultPrinter(string? uid)
    {
        lock (_lock)
        {
            _defaultPrinterUid = uid;
        }

        var path = Path.Combine(ConfigDir, "default.txt");
        if (uid != null)
            File.WriteAllText(path, uid);
        else if (File.Exists(path))
            File.Delete(path);
    }

    // MARK: - Subnet Scanner

    /// <summary>
    /// Get local IPv4 subnets and addresses.
    /// Port of Swift getLocalNetworkInfo() using System.Net.NetworkInformation.
    /// </summary>
    public static (List<string> Subnets, List<string> Addresses) GetLocalNetworkInfo()
    {
        var subnets = new HashSet<string>();
        var addresses = new List<string>();

        try
        {
            foreach (var iface in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (iface.OperationalStatus != OperationalStatus.Up)
                    continue;
                if (iface.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                    continue;
                if (iface.NetworkInterfaceType == NetworkInterfaceType.Tunnel)
                    continue;

                foreach (var addr in iface.GetIPProperties().UnicastAddresses)
                {
                    if (addr.Address.AddressFamily != AddressFamily.InterNetwork)
                        continue;

                    var ip = addr.Address.ToString();
                    addresses.Add(ip);

                    var octets = ip.Split('.');
                    if (octets.Length == 4)
                    {
                        var subnet = $"{octets[0]}.{octets[1]}.{octets[2]}";
                        // Skip link-local and common VM ranges
                        if (!subnet.StartsWith("169.254") && subnet != "192.168.64")
                            subnets.Add(subnet);
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Log($"GetLocalNetworkInfo failed: {ex.Message}");
        }

        return (subnets.ToList(), addresses);
    }

    /// <summary>
    /// Scan subnets for hosts listening on port 9100.
    /// Each responding host is probed with ~hi\r\n to identify Zebra printers.
    /// </summary>
    public async Task ScanSubnetsAsync(List<string> subnets, ushort port = 9100)
    {
        Log($"Scanning {string.Join(", ", subnets)} on port {port}");

        var found = new List<NetworkPrinter>();
        var foundLock = new object();
        var localIPs = new HashSet<string>(GetLocalNetworkInfo().Addresses);

        using var semaphore = new SemaphoreSlim(30);
        var tasks = new List<Task>();

        foreach (var subnet in subnets)
        {
            for (int hostNum = 1; hostNum <= 254; hostNum++)
            {
                var ip = $"{subnet}.{hostNum}";
                if (localIPs.Contains(ip)) continue;

                await semaphore.WaitAsync();
                tasks.Add(Task.Run(async () =>
                {
                    try
                    {
                        var result = await ProbePrinterAsync(ip, port);
                        if (result != null)
                        {
                            lock (foundLock)
                            {
                                found.Add(result);
                            }
                            Log($"Found printer: {result.Name} at {result.Host}");
                        }
                    }
                    finally
                    {
                        semaphore.Release();
                    }
                }));
            }
        }

        await Task.WhenAll(tasks);
        Log($"Scan complete: {found.Count} printer(s) found");

        lock (_lock)
        {
            foreach (var p in found)
            {
                if (!_scannedPrinters.Any(s => s.Host == p.Host && s.Port == p.Port))
                    _scannedPrinters.Add(p);
            }
        }

        PrintersChanged?.Invoke();
    }

    /// <summary>
    /// Probe a single IP:port. Returns a NetworkPrinter if port is open.
    /// Port of Swift probePrinter() using Socket.ConnectAsync with timeout.
    /// </summary>
    private static async Task<NetworkPrinter?> ProbePrinterAsync(string ip, ushort port)
    {
        try
        {
            using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);

            // Connect with 1s timeout
            using var connectCts = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            try
            {
                await socket.ConnectAsync(new IPEndPoint(IPAddress.Parse(ip), port), connectCts.Token);
            }
            catch { return null; }

            // Send Zebra identification command
            var cmd = Encoding.UTF8.GetBytes("~hi\r\n");
            socket.SendTimeout = 2000;
            socket.ReceiveTimeout = 2000;

            try
            {
                socket.Send(cmd);
            }
            catch { return null; }

            // Read response
            var buffer = new byte[4096];
            int bytesRead;
            try
            {
                bytesRead = socket.Receive(buffer);
            }
            catch
            {
                bytesRead = 0;
            }

            var name = ip;
            if (bytesRead > 0)
            {
                var response = Encoding.UTF8.GetString(buffer, 0, bytesRead);
                var trimmed = response.Trim().Trim('\x02', '\x03');
                var firstLine = trimmed.Split("\r\n")[0];
                if (!string.IsNullOrEmpty(firstLine))
                {
                    var parts = firstLine.Split(',');
                    var model = parts[0].Trim();
                    if (!string.IsNullOrEmpty(model))
                        name = $"{model} ({ip})";
                }
            }

            return new NetworkPrinter(name, ip, port);
        }
        catch
        {
            return null;
        }
    }

    private static void Log(string message)
    {
        Console.WriteLine($"[StripedPrinter:Printer] {message}");
    }
}

// MARK: - TCP Printer Connection

internal sealed class PrinterConnection
{
    private readonly string _host;
    private readonly ushort _port;

    // Connection pool: keyed by "host:port"
    private static readonly object PoolLock = new();
    private static readonly Dictionary<string, TcpClient> Pool = new();
    private static readonly Dictionary<string, CancellationTokenSource> PoolTimers = new();
    private const int IdleTimeoutMs = 30_000;

    public PrinterConnection(string host, ushort port)
    {
        _host = host;
        _port = port;
    }

    private string PoolKey => $"{_host}:{_port}";

    private TcpClient? GetCachedConnection()
    {
        lock (PoolLock)
        {
            if (Pool.TryGetValue(PoolKey, out var client) && client.Connected)
            {
                // Reset idle timer
                if (PoolTimers.TryGetValue(PoolKey, out var oldCts))
                {
                    oldCts.Cancel();
                    oldCts.Dispose();
                }
                ScheduleIdleCleanup();
                return client;
            }

            // Remove stale entry
            if (Pool.Remove(PoolKey, out var stale))
            {
                try { stale.Dispose(); } catch { }
            }
            if (PoolTimers.Remove(PoolKey, out var staleCts))
            {
                staleCts.Cancel();
                staleCts.Dispose();
            }
            return null;
        }
    }

    private void CacheConnection(TcpClient client)
    {
        lock (PoolLock)
        {
            Pool[PoolKey] = client;
            ScheduleIdleCleanup();
        }
    }

    /// <summary>Must be called with PoolLock held.</summary>
    private void ScheduleIdleCleanup()
    {
        var key = PoolKey;
        var cts = new CancellationTokenSource();
        PoolTimers[key] = cts;

        _ = Task.Delay(IdleTimeoutMs, cts.Token).ContinueWith(_ =>
        {
            lock (PoolLock)
            {
                if (Pool.Remove(key, out var conn))
                {
                    try { conn.Dispose(); } catch { }
                }
                if (PoolTimers.Remove(key, out var timer))
                {
                    timer.Dispose();
                }
            }
        }, TaskContinuationOptions.OnlyOnRanToCompletion);
    }

    /// <summary>
    /// Send data to the printer. Uses connection pool with fallback to new connection.
    /// </summary>
    public async Task SendAsync(byte[] data, int timeoutMs = 10_000)
    {
        // Try cached connection first
        var cached = GetCachedConnection();
        if (cached != null)
        {
            try
            {
                var stream = cached.GetStream();
                using var cts = new CancellationTokenSource(timeoutMs);
                await stream.WriteAsync(data, cts.Token);
                await stream.FlushAsync(cts.Token);
                CacheConnection(cached);
                return;
            }
            catch
            {
                // Cached connection failed, fall through to new one
                try { cached.Dispose(); } catch { }
            }
        }

        // New connection
        var client = new TcpClient();
        try
        {
            using var connectCts = new CancellationTokenSource(timeoutMs);
            await client.ConnectAsync(_host, _port, connectCts.Token);

            var stream = client.GetStream();
            using var writeCts = new CancellationTokenSource(timeoutMs);
            await stream.WriteAsync(data, writeCts.Token);
            await stream.FlushAsync(writeCts.Token);

            CacheConnection(client);
        }
        catch
        {
            try { client.Dispose(); } catch { }
            throw;
        }
    }

    /// <summary>
    /// Send data and receive response. Always uses a fresh connection (no pool).
    /// 500ms delay between send and receive, 5s default timeout.
    /// </summary>
    public async Task<byte[]> SendAndReceiveAsync(byte[]? data, int timeoutMs = 5_000)
    {
        using var client = new TcpClient();
        using var cts = new CancellationTokenSource(timeoutMs);

        await client.ConnectAsync(_host, _port, cts.Token);
        var stream = client.GetStream();

        if (data != null)
        {
            await stream.WriteAsync(data, cts.Token);
            await stream.FlushAsync(cts.Token);
        }

        // Small delay to allow printer to process
        await Task.Delay(500, cts.Token);

        var buffer = new byte[65536];
        var bytesRead = await stream.ReadAsync(buffer, cts.Token);
        if (bytesRead > 0)
        {
            var result = new byte[bytesRead];
            Array.Copy(buffer, result, bytesRead);
            return result;
        }

        return [];
    }
}
