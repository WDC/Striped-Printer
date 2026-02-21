import Foundation
import os

private let logger = Logger(subsystem: "com.striped-printer", category: "API")

// MARK: - Browser Print API Handler

final class BrowserPrintAPI {
    private let printerManager: PrinterManager

    // Buffer for read responses (keyed by device UID)
    private var readBuffers: [String: Data] = [:]
    private let bufferLock = NSLock()

    init(printerManager: PrinterManager) {
        self.printerManager = printerManager
    }

    func registerRoutes(on server: HTTPServer) {
        server.route("GET", "/default", handler: handleDefault)
        server.route("GET", "/available", handler: handleAvailable)
        server.route("GET", "/config", handler: handleConfig)
        server.route("POST", "/write", handler: handleWrite)
        server.route("POST", "/read", handler: handleRead)
        server.route("POST", "/convert", handler: handleConvert)
    }

    // MARK: - GET /default

    private func handleDefault(_ request: HTTPRequest) async -> HTTPResponse {
        let defaultDevice = await MainActor.run { printerManager.defaultDevice }

        let type = request.queryParams["type"] ?? "printer"

        if type == "printer", let device = defaultDevice {
            return .json(device)
        }

        // Return empty string if no default (matches Browser Print behavior)
        return .text("")
    }

    // MARK: - GET /available

    private func handleAvailable(_ request: HTTPRequest) async -> HTTPResponse {
        let devices = await MainActor.run { printerManager.allDevices }
        let response = AvailableResponse(printer: devices)
        return .json(response)
    }

    // MARK: - GET /config

    private func handleConfig(_ request: HTTPRequest) async -> HTTPResponse {
        .json(ApplicationConfig.current)
    }

    // MARK: - POST /write

    private func handleWrite(_ request: HTTPRequest) async -> HTTPResponse {
        guard let writeRequest = try? JSONDecoder().decode(WriteRequest.self, from: request.body) else {
            logger.error("Invalid write request body")
            return .error("Invalid request body", status: 400)
        }

        guard let printer = await MainActor.run(body: { printerManager.findPrinter(for: writeRequest.device) }) else {
            logger.error("Printer not found: \(writeRequest.device.uid)")
            return .error("Printer not found", status: 404)
        }

        // Get data to send
        var zplData: Data
        if let data = writeRequest.data {
            zplData = Data(data.utf8)
        } else if let url = writeRequest.url {
            // Fetch data from URL
            guard let fetchURL = URL(string: url) else {
                return .error("Invalid URL", status: 400)
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: fetchURL)
                zplData = data
            } catch {
                return .error("Failed to fetch URL: \(error.localizedDescription)", status: 500)
            }
        } else {
            return .error("No data or url provided", status: 400)
        }

        // Send to printer
        let conn = PrinterConnection(host: printer.host, port: printer.port)
        do {
            try await conn.send(data: zplData)
            logger.info("Sent \(zplData.count) bytes to \(printer.host):\(printer.port)")
            return .empty()
        } catch {
            logger.error("Write failed: \(error.localizedDescription)")
            return .error("Write failed: \(error.localizedDescription)", status: 500)
        }
    }

    // MARK: - POST /read

    private func handleRead(_ request: HTTPRequest) async -> HTTPResponse {
        guard let readRequest = try? JSONDecoder().decode(ReadRequest.self, from: request.body) else {
            return .error("Invalid request body", status: 400)
        }

        guard let printer = await MainActor.run(body: { printerManager.findPrinter(for: readRequest.device) }) else {
            return .error("Printer not found", status: 404)
        }

        // Read from the printer's TCP connection
        let conn = PrinterConnection(host: printer.host, port: printer.port)
        do {
            let data = try await conn.sendAndReceive(data: nil, timeout: 3)
            if let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
            return .text("")
        } catch {
            return .text("")
        }
    }

    // MARK: - POST /convert

    private func handleConvert(_ request: HTTPRequest) async -> HTTPResponse {
        // Image/PDF conversion is not supported in this lightweight replacement.
        // Browser Print uses a Java-based converter internally.
        .error("Conversion not supported. Send raw ZPL directly.", status: 501)
    }
}
