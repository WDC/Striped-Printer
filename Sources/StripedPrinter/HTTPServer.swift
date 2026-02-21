import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.striped-printer", category: "HTTPServer")

// MARK: - HTTP Types

struct HTTPRequest {
    let method: String
    let path: String
    let queryParams: [String: String]
    let headers: [String: String]
    let body: Data
    let origin: String?

    var pathOnly: String {
        path.split(separator: "?").first.map(String.init) ?? path
    }
}

struct HTTPResponse {
    var status: Int
    var statusText: String
    var headers: [String: String]
    var body: Data

    init(status: Int = 200, statusText: String = "OK", headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.body = body
    }

    private static let encoder = JSONEncoder()

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        var response = HTTPResponse(status: status, statusText: status == 200 ? "OK" : "Error", body: data)
        response.headers["Content-Type"] = "application/json"
        return response
    }

    static func text(_ text: String, status: Int = 200) -> HTTPResponse {
        var response = HTTPResponse(status: status, statusText: status == 200 ? "OK" : "Error", body: Data(text.utf8))
        response.headers["Content-Type"] = "text/plain"
        return response
    }

    static func empty() -> HTTPResponse {
        json(EmptyJSON())
    }

    static func notFound() -> HTTPResponse {
        text("Not Found", status: 404)
    }

    static func error(_ message: String, status: Int = 500) -> HTTPResponse {
        text(message, status: status)
    }
}

private struct EmptyJSON: Encodable {}

// MARK: - Route Handler

typealias RouteHandler = (HTTPRequest) async -> HTTPResponse

// MARK: - HTTP Server

final class HTTPServer {
    private var listener: NWListener?
    private let port: UInt16
    private let useTLS: Bool
    private let tlsIdentity: SecIdentity?
    private var routes: [(method: String, path: String, handler: RouteHandler)] = []
    private let queue = DispatchQueue(label: "com.striped-printer.http", qos: .userInitiated)

    init(port: UInt16, useTLS: Bool = false, tlsIdentity: SecIdentity? = nil) {
        self.port = port
        self.useTLS = useTLS
        self.tlsIdentity = tlsIdentity
    }

    func route(_ method: String, _ path: String, handler: @escaping RouteHandler) {
        routes.append((method: method, path: path, handler: handler))
    }

    func start() throws {
        let params: NWParameters
        if useTLS, let identity = tlsIdentity {
            let tlsOptions = NWProtocolTLS.Options()
            let secIdentity = sec_identity_create(identity)!
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        } else {
            params = .tcp
        }

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let scheme = self.useTLS ? "https" : "http"
                NSLog("[StripedPrinter] %@://127.0.0.1:%d ready (%d routes)", scheme, self.port, self.routes.count)
            case .failed(let error):
                NSLog("[StripedPrinter] Port %d failed: %@", self.port, error.localizedDescription)
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(connection: connection, buffer: Data())
    }

    private static let maxRequestSize = 10_485_760 // 10 MB

    private func receiveHTTPRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                logger.error("Receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            var accumulated = buffer
            if let content {
                accumulated.append(content)
            }

            if accumulated.count > Self.maxRequestSize {
                logger.warning("Request exceeded \(Self.maxRequestSize) bytes, dropping connection")
                connection.cancel()
                return
            }

            // Try to parse a complete HTTP request
            if let request = self.parseHTTPRequest(from: accumulated) {
                Task {
                    let response = await self.handleRequest(request)
                    self.sendResponse(response, on: connection)
                }
            } else if isComplete {
                // Connection closed before full request
                connection.cancel()
            } else {
                // Need more data
                self.receiveHTTPRequest(connection: connection, buffer: accumulated)
            }
        }
    }

    // MARK: - HTTP Parsing

    private func parseHTTPRequest(from data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        guard let headerString = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let fullPath = String(parts[1])

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Check if we have the full body
        let bodyStart = headerEnd.upperBound
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0

        let availableBody = data.count - data.distance(from: data.startIndex, to: bodyStart)
        guard availableBody >= contentLength else {
            return nil // Need more data
        }

        let body = contentLength > 0
            ? data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)]
            : Data()

        // Parse query params
        var path = fullPath
        var queryParams: [String: String] = [:]
        if let qIndex = fullPath.firstIndex(of: "?") {
            path = String(fullPath[fullPath.startIndex..<qIndex])
            let queryString = String(fullPath[fullPath.index(after: qIndex)...])
            for param in queryString.split(separator: "&") {
                let kv = param.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    queryParams[key] = value
                } else if kv.count == 1 {
                    queryParams[String(kv[0])] = ""
                }
            }
        }

        return HTTPRequest(
            method: method,
            path: path,
            queryParams: queryParams,
            headers: headers,
            body: Data(body),
            origin: headers["origin"]
        )
    }

    // MARK: - Routing

    private func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
        logger.info("\(request.method) \(request.path)")

        // Handle CORS preflight
        if request.method == "OPTIONS" {
            return corsResponse(for: request, response: .text("null"))
        }

        // Find matching route
        for route in routes {
            if route.method == request.method && route.path == request.pathOnly {
                let response = await route.handler(request)
                return corsResponse(for: request, response: response)
            }
        }

        return corsResponse(for: request, response: .notFound())
    }

    private func corsResponse(for request: HTTPRequest, response: HTTPResponse) -> HTTPResponse {
        var r = response
        let origin = request.origin ?? "*"
        r.headers["Access-Control-Allow-Origin"] = origin
        r.headers["Access-Control-Allow-Private-Network"] = "true"
        r.headers["Access-Control-Allow-Methods"] = "POST, GET, OPTIONS, DELETE, PUT, HEAD"
        r.headers["Access-Control-Allow-Headers"] = "origin, content-type"
        return r
    }

    // MARK: - Response Serialization

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        var headerString = "HTTP/1.1 \(response.status) \(response.statusText)\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"

        for (key, value) in headers {
            headerString += "\(key): \(value)\r\n"
        }
        headerString += "\r\n"

        var data = Data(headerString.utf8)
        data.append(response.body)

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
