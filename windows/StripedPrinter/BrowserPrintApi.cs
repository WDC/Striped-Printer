using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace StripedPrinter;

/// <summary>
/// Browser Print API endpoint handlers.
/// Port of BrowserPrintAPI.swift (141 lines) — all 6 endpoints.
/// Every response matches the official Zebra Browser Print SDK format exactly.
/// </summary>
internal sealed class BrowserPrintApi
{
    private readonly PrinterManager _printerManager;
    private static readonly HttpClient HttpClient = new();

    public BrowserPrintApi(PrinterManager printerManager)
    {
        _printerManager = printerManager;
    }

    public void RegisterRoutes(HttpServer server)
    {
        server.Route("GET", "/default", HandleDefault);
        server.Route("GET", "/available", HandleAvailable);
        server.Route("GET", "/config", HandleConfig);
        server.Route("POST", "/write", HandleWrite);
        server.Route("POST", "/read", HandleRead);
        server.Route("POST", "/convert", HandleConvert);
    }

    // MARK: - GET /default

    private Task<HttpResponse> HandleDefault(HttpRequest request)
    {
        var type = request.QueryParams.GetValueOrDefault("type", "printer");

        if (type == "printer")
        {
            var device = _printerManager.DefaultDevice;
            if (device != null)
                return Task.FromResult(HttpResponse.Json(device));
        }

        // Return empty string if no default (matches Browser Print behavior)
        return Task.FromResult(HttpResponse.Text(""));
    }

    // MARK: - GET /available

    private Task<HttpResponse> HandleAvailable(HttpRequest request)
    {
        var devices = _printerManager.AllDevices;
        var response = new AvailableResponse { Printer = devices };
        return Task.FromResult(HttpResponse.Json(response));
    }

    // MARK: - GET /config

    private Task<HttpResponse> HandleConfig(HttpRequest request)
    {
        return Task.FromResult(HttpResponse.Json(ApplicationConfig.Current));
    }

    // MARK: - POST /write

    private async Task<HttpResponse> HandleWrite(HttpRequest request)
    {
        WriteRequest? writeRequest;
        try
        {
            writeRequest = JsonSerializer.Deserialize<WriteRequest>(request.Body);
        }
        catch
        {
            writeRequest = null;
        }

        if (writeRequest?.Device == null)
        {
            Log("Invalid write request body");
            return HttpResponse.Error("Invalid request body", 400);
        }

        var printer = _printerManager.FindPrinter(writeRequest.Device);
        if (printer == null)
        {
            Log($"Printer not found: {writeRequest.Device.Uid}");
            return HttpResponse.Error("Printer not found", 404);
        }

        // Get data to send
        byte[] zplData;
        if (writeRequest.Data != null)
        {
            zplData = Encoding.UTF8.GetBytes(writeRequest.Data);
        }
        else if (writeRequest.Url != null)
        {
            // Fetch data from URL
            try
            {
                zplData = await HttpClient.GetByteArrayAsync(writeRequest.Url);
            }
            catch (Exception ex)
            {
                return HttpResponse.Error($"Failed to fetch URL: {ex.Message}", 500);
            }
        }
        else
        {
            return HttpResponse.Error("No data or url provided", 400);
        }

        // Send to printer
        var conn = new PrinterConnection(printer.Host, printer.Port);
        try
        {
            await conn.SendAsync(zplData);
            Log($"Sent {zplData.Length} bytes to {printer.Host}:{printer.Port}");
            return HttpResponse.Empty();
        }
        catch (Exception ex)
        {
            Log($"Write failed: {ex.Message}");
            return HttpResponse.Error($"Write failed: {ex.Message}", 500);
        }
    }

    // MARK: - POST /read

    private async Task<HttpResponse> HandleRead(HttpRequest request)
    {
        ReadRequest? readRequest;
        try
        {
            readRequest = JsonSerializer.Deserialize<ReadRequest>(request.Body);
        }
        catch
        {
            readRequest = null;
        }

        if (readRequest?.Device == null)
            return HttpResponse.Error("Invalid request body", 400);

        var printer = _printerManager.FindPrinter(readRequest.Device);
        if (printer == null)
            return HttpResponse.Error("Printer not found", 404);

        // Read from the printer's TCP connection
        var conn = new PrinterConnection(printer.Host, printer.Port);
        try
        {
            var data = await conn.SendAndReceiveAsync(null, 3000);
            var text = Encoding.UTF8.GetString(data);
            return HttpResponse.Text(text);
        }
        catch
        {
            return HttpResponse.Text("");
        }
    }

    // MARK: - POST /convert

    private Task<HttpResponse> HandleConvert(HttpRequest request)
    {
        return Task.FromResult(
            HttpResponse.Error("Conversion not supported. Send raw ZPL directly.", 501));
    }

    private static void Log(string message)
    {
        Console.WriteLine($"[StripedPrinter:API] {message}");
    }
}
