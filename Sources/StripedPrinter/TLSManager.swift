import Foundation
import Security
import os

private let logger = Logger(subsystem: "com.striped-printer", category: "TLS")

// MARK: - TLS Certificate Manager

final class TLSManager {
    private let appSupportDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDir = appSupport.appendingPathComponent("StripedPrinter")
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    private var certPath: String { appSupportDir.appendingPathComponent("server.cert").path }
    private var keyPath: String { appSupportDir.appendingPathComponent("server.key").path }
    private var p12Path: String { appSupportDir.appendingPathComponent("server.p12").path }

    /// Get or create a SecIdentity for TLS
    func getIdentity() -> SecIdentity? {
        // Check if we already have a PKCS12 file
        if FileManager.default.fileExists(atPath: p12Path) {
            if let identity = loadIdentityFromP12() {
                logger.info("Loaded existing TLS certificate")
                ensureCertTrusted()
                return identity
            }
        }

        // Generate new certificate
        if generateCertificate() {
            if let identity = loadIdentityFromP12() {
                logger.info("Generated new TLS certificate")
                ensureCertTrusted()
                return identity
            }
        }

        logger.error("Failed to set up TLS certificate")
        return nil
    }

    private func generateCertificate() -> Bool {
        logger.info("Generating self-signed certificate...")

        // Use openssl to generate cert + key, then convert to PKCS12
        let genProcess = Process()
        genProcess.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        genProcess.arguments = [
            "req", "-x509", "-nodes", "-newkey", "rsa:2048",
            "-keyout", keyPath,
            "-out", certPath,
            "-days", "730",
            "-subj", "/CN=127.0.0.1/O=StripedPrinter",
            "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost"
        ]

        let p12Process = Process()
        p12Process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p12Process.arguments = [
            "pkcs12", "-export",
            "-in", certPath,
            "-inkey", keyPath,
            "-out", p12Path,
            "-passout", "pass:stripedprinter"
        ]

        do {
            try genProcess.run()
            genProcess.waitUntilExit()
            guard genProcess.terminationStatus == 0 else {
                logger.error("openssl req failed with status \(genProcess.terminationStatus)")
                return false
            }

            try p12Process.run()
            p12Process.waitUntilExit()
            guard p12Process.terminationStatus == 0 else {
                logger.error("openssl pkcs12 failed with status \(p12Process.terminationStatus)")
                return false
            }

            return true
        } catch {
            logger.error("Failed to run openssl: \(error.localizedDescription)")
            return false
        }
    }

    /// Ensure the self-signed cert is trusted for SSL in the login keychain
    private func ensureCertTrusted() {
        // Check if already trusted
        let checkProcess = Process()
        checkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        checkProcess.arguments = ["dump-trust-settings"]
        let pipe = Pipe()
        checkProcess.standardOutput = pipe
        checkProcess.standardError = FileHandle.nullDevice

        do {
            try checkProcess.run()
            checkProcess.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if output.contains("127.0.0.1") {
                return // Already trusted
            }
        } catch {
            // Fall through to add trust
        }

        logger.info("Adding TLS certificate to login keychain trust...")
        let trustProcess = Process()
        trustProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        trustProcess.arguments = [
            "add-trusted-cert", "-r", "trustRoot", "-p", "ssl",
            "-k", NSHomeDirectory() + "/Library/Keychains/login.keychain-db",
            certPath
        ]

        do {
            try trustProcess.run()
            trustProcess.waitUntilExit()
            if trustProcess.terminationStatus == 0 {
                logger.info("Certificate trusted successfully")
            } else {
                logger.warning("Could not auto-trust certificate (status \(trustProcess.terminationStatus)). You may need to manually trust it.")
            }
        } catch {
            logger.warning("Could not auto-trust certificate: \(error.localizedDescription)")
        }
    }

    private func loadIdentityFromP12() -> SecIdentity? {
        guard let p12Data = try? Data(contentsOf: URL(fileURLWithPath: p12Path)) else {
            return nil
        }

        let options: [String: Any] = [kSecImportExportPassphrase as String: "stripedprinter"]
        var items: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &items)

        guard status == errSecSuccess,
              let itemArray = items as? [[String: Any]],
              let firstItem = itemArray.first,
              let identityRef = firstItem[kSecImportItemIdentity as String] else {
            logger.error("Failed to import PKCS12: \(status)")
            return nil
        }

        // SecIdentity is a CF type bridged through Any
        let identity = identityRef as! SecIdentity
        return identity
    }
}
