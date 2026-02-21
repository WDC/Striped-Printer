using System;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace StripedPrinter;

internal static class Program
{
    private const string MutexName = "Global\\StripedPrinter";
    private const string PipeName = "StripedPrinterPipe";

    [STAThread]
    static void Main(string[] args)
    {
        // Single-instance check
        using var mutex = new Mutex(true, MutexName, out var isNewInstance);

        // Find .zpl file path in args (Windows shell passes: StripedPrinter.exe "path\to\file.zpl")
        var zplFile = args.FirstOrDefault(a =>
            a.EndsWith(".zpl", StringComparison.OrdinalIgnoreCase) && File.Exists(a));

        if (!isNewInstance)
        {
            // Another instance is running — send .zpl path via named pipe, then exit
            if (zplFile != null)
            {
                SendFileToRunningInstance(zplFile);
            }
            return;
        }

        ApplicationConfiguration.Initialize();

        var trayApp = new TrayApp();

        // Start named pipe server to receive .zpl paths from second instances
        var pipeCts = new CancellationTokenSource();
        _ = RunPipeServerAsync(trayApp, pipeCts.Token);

        // Handle .zpl file passed as argument to first instance
        if (zplFile != null)
        {
            trayApp.SendZplFile(zplFile);
        }

        Application.Run(trayApp);
        pipeCts.Cancel();
    }

    /// <summary>
    /// Named pipe server that receives .zpl file paths from second instances.
    /// </summary>
    private static async Task RunPipeServerAsync(TrayApp trayApp, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(
                    PipeName,
                    PipeDirection.In,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);

                await server.WaitForConnectionAsync(ct);

                using var reader = new StreamReader(server, Encoding.UTF8);
                var path = await reader.ReadToEndAsync(ct);

                if (!string.IsNullOrWhiteSpace(path) && File.Exists(path.Trim()))
                {
                    // Marshal to UI thread for dialog handling
                    if (Application.OpenForms.Count > 0)
                    {
                        Application.OpenForms[0]!.Invoke(() => trayApp.SendZplFile(path.Trim()));
                    }
                    else
                    {
                        trayApp.SendZplFile(path.Trim());
                    }
                }
            }
            catch (OperationCanceledException) { break; }
            catch { /* Pipe error, retry */ }
        }
    }

    /// <summary>
    /// Send a .zpl file path to the running instance via named pipe.
    /// </summary>
    private static void SendFileToRunningInstance(string filePath)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            client.Connect(3000); // 3s timeout

            using var writer = new StreamWriter(client, Encoding.UTF8);
            writer.Write(filePath);
            writer.Flush();
        }
        catch
        {
            // Running instance may not have pipe server ready yet — silently fail
        }
    }
}
