using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace StripedPrinter;

// MARK: - HTTP Types

internal sealed class HttpRequest
{
    public string Method { get; init; } = "";
    public string Path { get; init; } = "";
    public Dictionary<string, string> QueryParams { get; init; } = new();
    public Dictionary<string, string> Headers { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    public byte[] Body { get; init; } = [];
    public string? Origin => Headers.GetValueOrDefault("origin");

    public string PathOnly => Path.Split('?')[0];
}

internal sealed class HttpResponse
{
    public int Status { get; set; } = 200;
    public string StatusText { get; set; } = "OK";
    public Dictionary<string, string> Headers { get; set; } = new();
    public byte[] Body { get; set; } = [];

    public static HttpResponse Json<T>(T value, int status = 200)
    {
        byte[] data;
        try
        {
            data = JsonSerializer.SerializeToUtf8Bytes(value);
        }
        catch
        {
            data = "{}"u8.ToArray();
        }

        return new HttpResponse
        {
            Status = status,
            StatusText = status == 200 ? "OK" : "Error",
            Body = data,
            Headers = new Dictionary<string, string> { ["Content-Type"] = "application/json" }
        };
    }

    public static HttpResponse Text(string text, int status = 200) => new()
    {
        Status = status,
        StatusText = status == 200 ? "OK" : "Error",
        Body = Encoding.UTF8.GetBytes(text),
        Headers = new Dictionary<string, string> { ["Content-Type"] = "text/plain" }
    };

    public static HttpResponse Empty() => Json(new { });

    public static HttpResponse NotFound() => Text("Not Found", 404);

    public static HttpResponse Error(string message, int status = 500) => Text(message, status);
}

// MARK: - Route Handler

internal delegate Task<HttpResponse> RouteHandler(HttpRequest request);

// MARK: - HTTP Server

internal sealed class HttpServer : IDisposable
{
    private TcpListener? _listener;
    private readonly ushort _port;
    private readonly bool _useTls;
    private readonly X509Certificate2? _certificate;
    private readonly List<(string Method, string Path, RouteHandler Handler)> _routes = [];
    private CancellationTokenSource? _cts;

    private const int MaxRequestSize = 10_485_760; // 10 MB

    public HttpServer(ushort port, bool useTls = false, X509Certificate2? certificate = null)
    {
        _port = port;
        _useTls = useTls;
        _certificate = certificate;
    }

    public void Route(string method, string path, RouteHandler handler)
    {
        _routes.Add((method, path, handler));
    }

    public void Start()
    {
        _cts = new CancellationTokenSource();
        _listener = new TcpListener(IPAddress.Loopback, _port);

        try
        {
            _listener.Start();
        }
        catch (SocketException ex) when (ex.SocketErrorCode == SocketError.AddressAlreadyInUse)
        {
            var scheme = _useTls ? "https" : "http";
            Log($"Port {_port} already in use — {scheme} server not started");
            throw;
        }

        var scheme2 = _useTls ? "https" : "http";
        Log($"{scheme2}://127.0.0.1:{_port} ready ({_routes.Count} routes)");

        _ = AcceptLoopAsync(_cts.Token);
    }

    public void Stop()
    {
        _cts?.Cancel();
        _listener?.Stop();
        _listener = null;
    }

    public void Dispose()
    {
        Stop();
        _cts?.Dispose();
    }

    // MARK: - Accept Loop

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var client = await _listener!.AcceptTcpClientAsync(ct);
                _ = HandleConnectionAsync(client);
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (Exception ex)
            {
                Log($"Accept error: {ex.Message}");
            }
        }
    }

    // MARK: - Connection Handling

    private async Task HandleConnectionAsync(TcpClient client)
    {
        try
        {
            using (client)
            {
                client.ReceiveTimeout = 30_000;
                client.SendTimeout = 30_000;

                Stream stream = client.GetStream();

                if (_useTls && _certificate != null)
                {
                    var sslStream = new SslStream(stream, false);
                    try
                    {
                        await sslStream.AuthenticateAsServerAsync(_certificate);
                        stream = sslStream;
                    }
                    catch
                    {
                        sslStream.Dispose();
                        return;
                    }
                }

                var request = await ReadHttpRequestAsync(stream);
                if (request == null) return;

                var response = await HandleRequest(request);
                await SendResponseAsync(response, stream);
            }
        }
        catch (Exception ex)
        {
            Log($"Connection error: {ex.Message}");
        }
    }

    // MARK: - HTTP Parsing

    private static async Task<HttpRequest?> ReadHttpRequestAsync(Stream stream)
    {
        var buffer = new byte[8192];
        using var ms = new MemoryStream();
        int headerEnd = -1;

        while (ms.Length < MaxRequestSize)
        {
            int bytesRead;
            try
            {
                bytesRead = await stream.ReadAsync(buffer);
            }
            catch { return null; }

            if (bytesRead == 0) return null;
            ms.Write(buffer, 0, bytesRead);

            // Look for \r\n\r\n
            var data = ms.GetBuffer();
            var len = (int)ms.Length;
            headerEnd = FindHeaderEnd(data, len);
            if (headerEnd >= 0)
            {
                // Check if we have the full body
                var headerBytes = Encoding.UTF8.GetString(data, 0, headerEnd);
                var contentLength = ParseContentLength(headerBytes);
                var bodyStart = headerEnd + 4; // past \r\n\r\n
                var bodyAvailable = len - bodyStart;

                if (bodyAvailable >= contentLength)
                {
                    return ParseRequest(data, len, headerEnd, bodyStart, contentLength);
                }

                // Need more body data
                while (len - bodyStart < contentLength && len < MaxRequestSize)
                {
                    try
                    {
                        bytesRead = await stream.ReadAsync(buffer);
                    }
                    catch { return null; }

                    if (bytesRead == 0) return null;
                    ms.Write(buffer, 0, bytesRead);
                    len = (int)ms.Length;
                    data = ms.GetBuffer();
                }

                if (len - bodyStart >= contentLength)
                {
                    return ParseRequest(data, len, headerEnd, bodyStart, contentLength);
                }

                return null; // Exceeded max size
            }
        }

        return null;
    }

    private static int FindHeaderEnd(byte[] data, int length)
    {
        // Search for \r\n\r\n
        for (int i = 0; i <= length - 4; i++)
        {
            if (data[i] == '\r' && data[i + 1] == '\n' &&
                data[i + 2] == '\r' && data[i + 3] == '\n')
                return i;
        }
        return -1;
    }

    private static int ParseContentLength(string headerString)
    {
        foreach (var line in headerString.Split("\r\n"))
        {
            var colonIdx = line.IndexOf(':');
            if (colonIdx <= 0) continue;
            var key = line[..colonIdx].Trim();
            if (key.Equals("Content-Length", StringComparison.OrdinalIgnoreCase))
            {
                if (int.TryParse(line[(colonIdx + 1)..].Trim(), out var cl))
                    return cl;
            }
        }
        return 0;
    }

    private static HttpRequest? ParseRequest(byte[] data, int dataLen, int headerEnd, int bodyStart, int contentLength)
    {
        var headerString = Encoding.UTF8.GetString(data, 0, headerEnd);
        var lines = headerString.Split("\r\n");
        if (lines.Length == 0) return null;

        var requestLine = lines[0];
        var parts = requestLine.Split(' ', 3);
        if (parts.Length < 2) return null;

        var method = parts[0];
        var fullPath = parts[1];

        // Parse headers
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 1; i < lines.Length; i++)
        {
            var colonIdx = lines[i].IndexOf(':');
            if (colonIdx > 0)
            {
                var key = lines[i][..colonIdx].Trim();
                var value = lines[i][(colonIdx + 1)..].Trim();
                headers[key] = value;
            }
        }

        // Parse body
        byte[] body;
        if (contentLength > 0 && bodyStart + contentLength <= dataLen)
        {
            body = new byte[contentLength];
            Array.Copy(data, bodyStart, body, 0, contentLength);
        }
        else
        {
            body = [];
        }

        // Parse query params
        var path = fullPath;
        var queryParams = new Dictionary<string, string>();
        var qIdx = fullPath.IndexOf('?');
        if (qIdx >= 0)
        {
            path = fullPath[..qIdx];
            var queryString = fullPath[(qIdx + 1)..];
            foreach (var param in queryString.Split('&'))
            {
                var eqIdx = param.IndexOf('=');
                if (eqIdx > 0)
                {
                    var key = Uri.UnescapeDataString(param[..eqIdx]);
                    var value = Uri.UnescapeDataString(param[(eqIdx + 1)..]);
                    queryParams[key] = value;
                }
                else if (param.Length > 0)
                {
                    queryParams[Uri.UnescapeDataString(param)] = "";
                }
            }
        }

        return new HttpRequest
        {
            Method = method,
            Path = path,
            QueryParams = queryParams,
            Headers = headers,
            Body = body,
        };
    }

    // MARK: - Routing

    private async Task<HttpResponse> HandleRequest(HttpRequest request)
    {
        Log($"{request.Method} {request.Path}");

        // Handle CORS preflight
        if (request.Method == "OPTIONS")
        {
            return CorsResponse(request, HttpResponse.Text("null"));
        }

        // Find matching route
        foreach (var (method, path, handler) in _routes)
        {
            if (method == request.Method && path == request.PathOnly)
            {
                var response = await handler(request);
                return CorsResponse(request, response);
            }
        }

        return CorsResponse(request, HttpResponse.NotFound());
    }

    private static HttpResponse CorsResponse(HttpRequest request, HttpResponse response)
    {
        var origin = request.Origin ?? "*";
        response.Headers["Access-Control-Allow-Origin"] = origin;
        response.Headers["Access-Control-Allow-Private-Network"] = "true";
        response.Headers["Access-Control-Allow-Methods"] = "POST, GET, OPTIONS, DELETE, PUT, HEAD";
        response.Headers["Access-Control-Allow-Headers"] = "origin, content-type";
        return response;
    }

    // MARK: - Response Serialization

    private static async Task SendResponseAsync(HttpResponse response, Stream stream)
    {
        var sb = new StringBuilder();
        sb.Append($"HTTP/1.1 {response.Status} {response.StatusText}\r\n");

        response.Headers["Content-Length"] = response.Body.Length.ToString();
        response.Headers["Connection"] = "close";

        foreach (var (key, value) in response.Headers)
        {
            sb.Append($"{key}: {value}\r\n");
        }
        sb.Append("\r\n");

        var headerBytes = Encoding.UTF8.GetBytes(sb.ToString());

        try
        {
            await stream.WriteAsync(headerBytes);
            if (response.Body.Length > 0)
                await stream.WriteAsync(response.Body);
            await stream.FlushAsync();
        }
        catch { /* Client disconnected */ }
    }

    private static void Log(string message)
    {
        Console.WriteLine($"[StripedPrinter:HTTP] {message}");
    }
}
