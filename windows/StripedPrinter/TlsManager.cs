using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace StripedPrinter;

/// <summary>
/// Manages self-signed TLS certificate for HTTPS on port 9101.
/// Uses X509Certificate2.CreateSelfSigned (pure .NET, no openssl dependency).
/// Certificate is stored as PFX in %APPDATA%\StripedPrinter\.
/// Trust is added to CurrentUser\Root (no admin needed, one-time Windows dialog).
/// </summary>
internal sealed class TlsManager
{
    private readonly string _configDir;
    private string PfxPath => Path.Combine(_configDir, "server.pfx");
    private string TrustedSentinel => Path.Combine(_configDir, ".trusted");

    private const string PfxPassword = "stripedprinter";
    private const int ValidityDays = 730;
    private const int MinRemainingDays = 30;

    public TlsManager()
    {
        _configDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "StripedPrinter");
        Directory.CreateDirectory(_configDir);
    }

    /// <summary>
    /// Get or create the TLS certificate. Returns null on failure.
    /// </summary>
    public X509Certificate2? GetCertificate()
    {
        // Try loading existing cert
        if (File.Exists(PfxPath))
        {
            var cert = LoadCertificate();
            if (cert != null && cert.NotAfter > DateTime.UtcNow.AddDays(MinRemainingDays))
            {
                Log("Loaded existing TLS certificate");
                EnsureTrusted(cert);
                return cert;
            }
            cert?.Dispose();
        }

        // Generate new
        var newCert = GenerateCertificate();
        if (newCert != null)
        {
            Log("Generated new TLS certificate");
            EnsureTrusted(newCert);
            return newCert;
        }

        Log("Failed to set up TLS certificate");
        return null;
    }

    private X509Certificate2? GenerateCertificate()
    {
        try
        {
            // Invalidate trust sentinel
            if (File.Exists(TrustedSentinel))
                File.Delete(TrustedSentinel);

            using var rsa = RSA.Create(2048);

            var request = new CertificateRequest(
                "CN=127.0.0.1, O=StripedPrinter",
                rsa,
                HashAlgorithmName.SHA256,
                RSASignaturePadding.Pkcs1);

            // Subject Alternative Names: IP 127.0.0.1 + DNS localhost
            var sanBuilder = new SubjectAlternativeNameBuilder();
            sanBuilder.AddIpAddress(IPAddress.Loopback);
            sanBuilder.AddDnsName("localhost");
            request.CertificateExtensions.Add(sanBuilder.Build());

            // Basic constraints (CA:false)
            request.CertificateExtensions.Add(
                new X509BasicConstraintsExtension(false, false, 0, false));

            // Key usage: digital signature + key encipherment
            request.CertificateExtensions.Add(
                new X509KeyUsageExtension(
                    X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment,
                    false));

            // Enhanced key usage: server authentication
            request.CertificateExtensions.Add(
                new X509EnhancedKeyUsageExtension(
                    new OidCollection { new("1.3.6.1.5.5.7.3.1") }, // serverAuth
                    false));

            var cert = request.CreateSelfSigned(
                DateTimeOffset.UtcNow.AddDays(-1),
                DateTimeOffset.UtcNow.AddDays(ValidityDays));

            // Export to PFX and reimport (required for SslStream to access private key)
            var pfxBytes = cert.Export(X509ContentType.Pfx, PfxPassword);
            File.WriteAllBytes(PfxPath, pfxBytes);

            return new X509Certificate2(pfxBytes, PfxPassword,
                X509KeyStorageFlags.MachineKeySet | X509KeyStorageFlags.PersistKeySet);
        }
        catch (Exception ex)
        {
            Log($"Certificate generation failed: {ex.Message}");
            return null;
        }
    }

    private X509Certificate2? LoadCertificate()
    {
        try
        {
            return new X509Certificate2(PfxPath, PfxPassword,
                X509KeyStorageFlags.MachineKeySet | X509KeyStorageFlags.PersistKeySet);
        }
        catch (Exception ex)
        {
            Log($"Failed to load certificate: {ex.Message}");
            return null;
        }
    }

    private void EnsureTrusted(X509Certificate2 cert)
    {
        // Fast path: sentinel means already trusted
        if (File.Exists(TrustedSentinel))
            return;

        try
        {
            using var store = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
            store.Open(OpenFlags.ReadWrite);

            // Check if already in store
            var existing = store.Certificates.Find(
                X509FindType.FindByThumbprint, cert.Thumbprint, false);
            if (existing.Count > 0)
            {
                File.WriteAllText(TrustedSentinel, "");
                return;
            }

            // Add to store (Windows shows a one-time confirmation dialog)
            Log("Adding TLS certificate to Windows certificate store...");
            store.Add(cert);
            File.WriteAllText(TrustedSentinel, "");
            Log("Certificate trusted successfully");
        }
        catch (Exception ex)
        {
            Log($"Could not auto-trust certificate: {ex.Message}");
        }
    }

    private static void Log(string message)
    {
        Console.WriteLine($"[StripedPrinter:TLS] {message}");
    }
}
