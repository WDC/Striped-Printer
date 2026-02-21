using System.Text.Json.Serialization;

namespace StripedPrinter;

// MARK: - Device Model (matches Browser Print JSON format)

public class PrinterDevice
{
    [JsonPropertyName("deviceType")]
    public string DeviceType { get; set; } = "printer";

    [JsonPropertyName("uid")]
    public string Uid { get; set; } = "";

    [JsonPropertyName("provider")]
    public string Provider { get; set; } = "com.zebra.ds.webdriver.desktop.provider.DefaultDeviceProvider";

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("connection")]
    public string Connection { get; set; } = "network";

    [JsonPropertyName("version")]
    public int Version { get; set; } = 3;

    [JsonPropertyName("manufacturer")]
    public string Manufacturer { get; set; } = "Zebra Technologies";

    public PrinterDevice() { }

    public PrinterDevice(string name, string? uid = null, string connection = "network",
        string deviceType = "printer", int version = 3,
        string provider = "com.zebra.ds.webdriver.desktop.provider.DefaultDeviceProvider",
        string manufacturer = "Zebra Technologies")
    {
        DeviceType = deviceType;
        Uid = uid ?? name;
        Provider = provider;
        Name = name;
        Connection = connection;
        Version = version;
        Manufacturer = manufacturer;
    }
}

// MARK: - Network Printer (internal tracking)

public class NetworkPrinter
{
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public ushort Port { get; set; } = 9100;

    public NetworkPrinter() { }

    public NetworkPrinter(string name, string host, ushort port = 9100)
    {
        Name = name;
        Host = host;
        Port = port;
    }

    public PrinterDevice ToDevice() => new(
        name: Name,
        uid: $"{Host}:{Port}",
        connection: "network"
    );

    public override bool Equals(object? obj) =>
        obj is NetworkPrinter other && Host == other.Host && Port == other.Port;

    public override int GetHashCode() => HashCode.Combine(Host, Port);
}

// MARK: - API Request/Response Models

public class WriteRequest
{
    [JsonPropertyName("device")]
    public PrinterDevice Device { get; set; } = new();

    [JsonPropertyName("data")]
    public string? Data { get; set; }

    [JsonPropertyName("url")]
    public string? Url { get; set; }
}

public class ReadRequest
{
    [JsonPropertyName("device")]
    public PrinterDevice Device { get; set; } = new();
}

public class AvailableResponse
{
    [JsonPropertyName("printer")]
    public List<PrinterDevice> Printer { get; set; } = [];
}

// MARK: - Application Config

public class ApplicationConfig
{
    [JsonPropertyName("application")]
    public ApplicationInfo Application { get; set; } = new();

    public class ApplicationInfo
    {
        [JsonPropertyName("supportedConversions")]
        public Dictionary<string, List<string>> SupportedConversions { get; set; } = new();

        [JsonPropertyName("version")]
        public string Version { get; set; } = "";

        [JsonPropertyName("apiLevel")]
        public int ApiLevel { get; set; }

        [JsonPropertyName("buildNumber")]
        public int BuildNumber { get; set; }

        [JsonPropertyName("platform")]
        public string Platform { get; set; } = "";
    }

    public static readonly ApplicationConfig Current = new()
    {
        Application = new ApplicationInfo
        {
            SupportedConversions = new Dictionary<string, List<string>>
            {
                ["jpg"] = ["cpcl", "zpl", "kpl"],
                ["tif"] = ["cpcl", "zpl", "kpl"],
                ["pdf"] = ["cpcl", "zpl", "kpl"],
                ["bmp"] = ["cpcl", "zpl", "kpl"],
                ["pcx"] = ["cpcl", "zpl", "kpl"],
                ["gif"] = ["cpcl", "zpl", "kpl"],
                ["png"] = ["cpcl", "zpl", "kpl"],
                ["jpeg"] = ["cpcl", "zpl", "kpl"],
            },
            Version = "1.3.2.489",
            ApiLevel = 5,
            BuildNumber = 489,
            Platform = "windows"
        }
    };
}

// MARK: - Persistence Models

public class SavedPrinter
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("host")]
    public string Host { get; set; } = "";

    [JsonPropertyName("port")]
    public ushort Port { get; set; } = 9100;
}
