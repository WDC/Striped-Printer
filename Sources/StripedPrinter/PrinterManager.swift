import Foundation
import Network
import os

private let logger = Logger(subsystem: "com.striped-printer", category: "PrinterManager")

// MARK: - Printer Manager

@MainActor
final class PrinterManager: ObservableObject {
    static let shared = PrinterManager()

    @Published private(set) var bonjourPrinters: [NetworkPrinter] = []
    @Published private(set) var scannedPrinters: [NetworkPrinter] = []
    @Published var manualPrinters: [NetworkPrinter] = []
    @Published var defaultPrinterUID: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.striped-printer.discovery")

    // All known printers (manual + scanned + bonjour, deduplicated)
    var allPrinters: [NetworkPrinter] {
        var combined = manualPrinters
        for printer in scannedPrinters + bonjourPrinters {
            if !combined.contains(where: { $0.host == printer.host && $0.port == printer.port }) {
                combined.append(printer)
            }
        }
        return combined
    }

    var allDevices: [PrinterDevice] {
        allPrinters.map(\.device)
    }

    var defaultDevice: PrinterDevice? {
        if let uid = defaultPrinterUID {
            return allDevices.first { $0.uid == uid }
        }
        return allDevices.first
    }

    // MARK: - Bonjour Discovery

    func startDiscovery() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_pdl-datastream._tcp", domain: nil)
        browser = NWBrowser(for: descriptor, using: .tcp)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }

        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.info("Bonjour discovery started")
            case .failed(let error):
                logger.error("Bonjour discovery failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        browser?.start(queue: queue)
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        var printers: [NetworkPrinter] = []
        let group = DispatchGroup()

        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }

            group.enter()

            // Resolve the Bonjour service to an IP address
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            let resolved = NSLock()
            var didLeave = false
            let safeLeave = {
                resolved.lock()
                defer { resolved.unlock() }
                guard !didLeave else { return }
                didLeave = true
                group.leave()
            }

            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    var resolvedHost: String?
                    var resolvedPort: UInt16 = 9100

                    // Walk resolved endpoint, prefer IPv4
                    if let path = connection.currentPath {
                        if case let .hostPort(host, port) = path.remoteEndpoint {
                            resolvedPort = port.rawValue
                            switch host {
                            case .ipv4(let addr):
                                resolvedHost = "\(addr)"
                            case .ipv6(let addr):
                                // Strip interface suffix (e.g. %en0) from IPv6
                                var v6 = "\(addr)"
                                if let pctIdx = v6.firstIndex(of: "%") {
                                    v6 = String(v6[v6.startIndex..<pctIdx])
                                }
                                if !v6.hasPrefix("fe80") {
                                    resolvedHost = v6
                                }
                            case .name(let n, _):
                                resolvedHost = n
                            @unknown default:
                                break
                            }
                        }
                    }

                    // If we only got IPv6 or nothing, try DNS for an IPv4 address
                    if resolvedHost == nil || resolvedHost?.contains(":") == true {
                        if let ipv4 = Self.resolveHostnameToIPv4(name + ".local") {
                            resolvedHost = ipv4
                        }
                    }

                    if let host = resolvedHost, !host.isEmpty {
                        let printer = NetworkPrinter(
                            name: name,
                            host: host,
                            port: resolvedPort
                        )
                        printers.append(printer)
                    }
                    connection.cancel()
                    safeLeave()
                } else if case .failed = state {
                    connection.cancel()
                    safeLeave()
                }
            }
            connection.start(queue: self.queue)

            self.queue.asyncAfter(deadline: .now() + 3) {
                if connection.state != .cancelled {
                    connection.cancel()
                    safeLeave()
                }
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            // Verify each Bonjour-discovered printer is ZPL-compatible via ~hi probe.
            // This filters out non-Zebra printers (Brother, HP, Canon, etc.) that also
            // advertise _pdl-datastream._tcp.
            let verified = printers.compactMap { printer -> NetworkPrinter? in
                PrinterManager.probePrinter(ip: printer.host, port: printer.port)
            }

            Task { @MainActor [weak self] in
                self?.bonjourPrinters = verified
                if !verified.isEmpty {
                    logger.info("Bonjour discovered \(verified.count) ZPL printer(s)")
                    for p in verified {
                        logger.info("  - \(p.name) at \(p.host):\(p.port)")
                    }
                }
            }
        }
    }

    // MARK: - Manual Printer Management

    func addManualPrinter(name: String, host: String, port: UInt16 = 9100) {
        let printer = NetworkPrinter(name: name, host: host, port: port)
        if !manualPrinters.contains(printer) {
            manualPrinters.append(printer)
            saveManualPrinters()
        }
    }

    func removeManualPrinter(_ printer: NetworkPrinter) {
        manualPrinters.removeAll { $0 == printer }
        saveManualPrinters()
    }

    // MARK: - Persistence

    private var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("StripedPrinter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func loadManualPrinters() {
        let url = configURL.appendingPathComponent("printers.json")
        guard let data = try? Data(contentsOf: url) else {
            // No printers.json yet — try legacy migration
            migrateLegacyConfig()
            return
        }

        struct SavedPrinter: Codable {
            let name: String
            let host: String
            let port: UInt16
        }

        if let saved = try? JSONDecoder().decode([SavedPrinter].self, from: data) {
            manualPrinters = saved.map { NetworkPrinter(name: $0.name, host: $0.host, port: $0.port) }
        }

        // Migrate legacy config if manualPrinters is still empty
        if manualPrinters.isEmpty {
            migrateLegacyConfig()
        }

        // Load default printer UID
        let defaultURL = configURL.appendingPathComponent("default.txt")
        defaultPrinterUID = try? String(contentsOf: defaultURL, encoding: .utf8)
    }

    /// Migrate printers from legacy iZPL ~/.zplprinters config file.
    private func migrateLegacyConfig() {
        let legacyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zplprinters")
        guard FileManager.default.fileExists(atPath: legacyPath.path) else { return }

        guard let contents = try? String(contentsOf: legacyPath, encoding: .utf8) else { return }

        let lines = contents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        for line in lines {
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 2,
                  let port = UInt16(parts[1]) else { continue }
            let host = parts[0]
            let name = parts.count >= 3 ? parts[2...].joined(separator: ":") : host
            addManualPrinter(name: name, host: host, port: port)
        }

        // Rename so migration only runs once
        let migratedPath = legacyPath.deletingLastPathComponent()
            .appendingPathComponent(".zplprinters.migrated")
        try? FileManager.default.moveItem(at: legacyPath, to: migratedPath)
        logger.info("Migrated \(lines.count) printer(s) from ~/.zplprinters")
    }

    private func saveManualPrinters() {
        struct SavedPrinter: Codable {
            let name: String
            let host: String
            let port: UInt16
        }

        let saved = manualPrinters.map { SavedPrinter(name: $0.name, host: $0.host, port: $0.port) }
        if let data = try? JSONEncoder().encode(saved) {
            let url = configURL.appendingPathComponent("printers.json")
            try? data.write(to: url)
        }
    }

    func setDefaultPrinter(_ uid: String?) {
        defaultPrinterUID = uid
        let url = configURL.appendingPathComponent("default.txt")
        if let uid {
            try? uid.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Find Printer by Device

    func findPrinter(for device: PrinterDevice) -> NetworkPrinter? {
        allPrinters.first { $0.device.uid == device.uid }
            ?? allPrinters.first { $0.device.name == device.name }
    }

    // MARK: - Subnet Scanner

    /// Scan one or more subnets for hosts listening on port 9100.
    /// Each host that responds is probed with `~hi\r\n` to identify Zebra printers.
    nonisolated func scanSubnets(_ subnets: [String], port: UInt16 = 9100) {
        NSLog("[StripedPrinter] Scanning %@ on port %d", subnets.joined(separator: ", "), port)

        let lock = NSLock()
        var found: [NetworkPrinter] = []

        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 30
        opQueue.qualityOfService = .userInitiated

        let localIPs = Set(Self.getLocalNetworkInfo().addresses)

        for subnet in subnets {
            for hostNum in 1...254 {
                let ip = "\(subnet).\(hostNum)"
                if localIPs.contains(ip) { continue }
                opQueue.addOperation {
                    if let result = Self.probePrinter(ip: ip, port: port) {
                        lock.lock()
                        found.append(result)
                        lock.unlock()
                        NSLog("[StripedPrinter] Found printer: %@ at %@", result.name, result.host)
                    }
                }
            }
        }

        DispatchQueue(label: "com.striped-printer.scan-wait").async {
            opQueue.waitUntilAllOperationsAreFinished()
            NSLog("[StripedPrinter] Scan complete: %d printer(s) found", found.count)
            Task { @MainActor [weak self] in
                guard let self else { return }
                for p in found {
                    if !self.scannedPrinters.contains(where: { $0.host == p.host && $0.port == p.port }) {
                        self.scannedPrinters.append(p)
                    }
                }
            }
        }
    }

    /// Check if a host has a Zebra discovery service on UDP 4201.
    /// Zebra printers listen on this port; non-Zebra printers (Brother, HP, etc.) do not.
    /// Must pass before sending ANY data to TCP 9100 to avoid triggering prints on non-Zebra devices.
    nonisolated private static func hasZebraDiscoveryPort(ip: String) -> Bool {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(4201).bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)

        // Send a discovery probe
        var probe: UInt8 = 0
        let sent = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                sendto(sock, &probe, 1, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else { return false }

        // Wait for response (1 second timeout)
        var pfd = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pfd, 1, 1000)
        return pollResult > 0 && (pfd.revents & Int16(POLLIN) != 0)
    }

    /// Probe a single IP:port for a Zebra/ZPL printer using POSIX sockets.
    /// First verifies UDP 4201 (Zebra discovery port) to avoid sending data to non-Zebra devices,
    /// then confirms with `~hi` on TCP 9100 for model identification.
    nonisolated private static func probePrinter(ip: String, port: UInt16) -> NetworkPrinter? {
        // Gate: verify Zebra discovery port before touching TCP 9100.
        // Non-Zebra printers (e.g. Brother MFCs) will print raw data sent to port 9100.
        guard hasZebraDiscoveryPort(ip: ip) else { return nil }

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        // Set non-blocking
        var flags = fcntl(sock, F_GETFL, 0)
        fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &addr.sin_addr)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult != 0 && errno != EINPROGRESS {
            return nil
        }

        // Wait for connection with timeout using poll()
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pfd, 1, 1000) // 1 second timeout
        guard pollResult > 0, pfd.revents & Int16(POLLOUT) != 0 else { return nil }

        // Check if connection succeeded
        var soError: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &soLen)
        guard soError == 0 else { return nil }

        // Port is open! Set back to blocking for send/recv
        flags = fcntl(sock, F_GETFL, 0)
        fcntl(sock, F_SETFL, flags & ~O_NONBLOCK)

        // Set read/write timeout
        var rwTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rwTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &rwTimeout, socklen_t(MemoryLayout<timeval>.size))

        // Send Zebra identification command
        let cmd = "~hi\r\n"
        _ = cmd.withCString { Darwin.send(sock, $0, cmd.utf8.count, 0) }

        // Read response
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(sock, &buffer, buffer.count, 0)

        // Require a valid Zebra ~hi response (comma-delimited model/firmware/serial info).
        // Non-Zebra printers (Brother, HP, etc.) won't respond meaningfully to ~hi.
        guard bytesRead > 0,
              let response = String(bytes: buffer[0..<bytesRead], encoding: .utf8) else { return nil }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{02}\u{03}"))

        // Zebra printers respond with comma-separated fields (model, firmware, serial, etc.)
        guard trimmed.contains(",") else { return nil }

        var name = ip
        if let firstLine = trimmed.components(separatedBy: "\r\n").first,
           !firstLine.isEmpty {
            let parts = firstLine.components(separatedBy: ",")
            let model = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                name = "\(model) (\(ip))"
            }
        }

        return NetworkPrinter(name: name, host: ip, port: port)
    }

    /// Get local IPv4 subnets and addresses in a single getifaddrs pass.
    nonisolated static func getLocalNetworkInfo() -> (subnets: [String], addresses: [String]) {
        var subnets: Set<String> = []
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return ([], []) }
        defer { freeifaddrs(ifaddr) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = current {
            if let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                addresses.append(ip)

                let name = String(cString: ifa.pointee.ifa_name)
                // Skip loopback and virtual interfaces for subnet detection
                if name != "lo0" && !name.hasPrefix("utun") && !name.hasPrefix("bridge") {
                    let octets = ip.split(separator: ".")
                    if octets.count == 4 {
                        let subnet = octets[0...2].joined(separator: ".")
                        // Skip link-local (169.254) and common VM ranges
                        if !subnet.hasPrefix("169.254") && subnet != "192.168.64" {
                            subnets.insert(subnet)
                        }
                    }
                }
            }
            current = ifa.pointee.ifa_next
        }
        return (Array(subnets), addresses)
    }

    /// Get the local machine's IPv4 subnets (convenience wrapper).
    nonisolated static func getLocalSubnets() -> [String] {
        getLocalNetworkInfo().subnets
    }

    // MARK: - DNS Resolution

    nonisolated static func resolveHostnameToIPv4(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET  // IPv4 only
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        defer { freeaddrinfo(result) }

        guard status == 0, let info = result else { return nil }

        var addr = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}

// MARK: - TCP Printer Connection

final class PrinterConnection {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.striped-printer.tcp")

    // Connection pool: keyed by "host:port"
    private static let poolLock = NSLock()
    private static var pool: [String: NWConnection] = [:]
    private static var poolTimers: [String: DispatchWorkItem] = [:]
    private static let idleTimeout: TimeInterval = 30

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    private var poolKey: String { "\(host):\(port)" }

    private func getCachedConnection() -> NWConnection? {
        Self.poolLock.lock()
        defer { Self.poolLock.unlock() }
        if let conn = Self.pool[poolKey], conn.state == .ready {
            // Reset idle timer
            Self.poolTimers[poolKey]?.cancel()
            scheduleIdleCleanup()
            return conn
        }
        // Remove stale entry
        Self.pool.removeValue(forKey: poolKey)
        Self.poolTimers[poolKey]?.cancel()
        Self.poolTimers.removeValue(forKey: poolKey)
        return nil
    }

    private func cacheConnection(_ connection: NWConnection) {
        Self.poolLock.lock()
        defer { Self.poolLock.unlock() }
        Self.pool[poolKey] = connection
        scheduleIdleCleanup()
    }

    /// Must be called with poolLock held.
    private func scheduleIdleCleanup() {
        let key = poolKey
        let work = DispatchWorkItem {
            Self.poolLock.lock()
            if let conn = Self.pool.removeValue(forKey: key) {
                conn.cancel()
            }
            Self.poolTimers.removeValue(forKey: key)
            Self.poolLock.unlock()
        }
        Self.poolTimers[key] = work
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.idleTimeout, execute: work)
    }

    private func makeConnection() -> NWConnection {
        NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func send(data: Data, timeout: TimeInterval = 10) async throws {
        // Try cached connection first
        if let cached = getCachedConnection() {
            do {
                try await sendOnReady(connection: cached, data: data, timeout: timeout)
                cacheConnection(cached)
                return
            } catch {
                // Cached connection failed, fall through to new one
                cached.cancel()
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = makeConnection()
            var completed = false

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    connection.send(content: data, completion: .contentProcessed { error in
                        guard !completed else { return }
                        completed = true
                        if let error {
                            connection.cancel()
                            continuation.resume(throwing: error)
                        } else {
                            self?.cacheConnection(connection)
                            connection.stateUpdateHandler = nil
                            continuation.resume()
                        }
                    })
                case .failed(let error):
                    guard !completed else { return }
                    completed = true
                    connection.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                guard !completed else { return }
                completed = true
                connection.cancel()
                continuation.resume(throwing: PrinterError.timeout)
            }
        }
    }

    /// Send data on an already-ready connection.
    private func sendOnReady(connection: NWConnection, data: Data, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false

            connection.send(content: data, completion: .contentProcessed { error in
                guard !completed else { return }
                completed = true
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })

            queue.asyncAfter(deadline: .now() + timeout) {
                guard !completed else { return }
                completed = true
                continuation.resume(throwing: PrinterError.timeout)
            }
        }
    }

    func sendAndReceive(data: Data?, timeout: TimeInterval = 5) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let connection = makeConnection()

            var completed = false

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let doRead = {
                        // Small delay to allow printer to process
                        self.queue.asyncAfter(deadline: .now() + 0.5) {
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, _, error in
                                guard !completed else { return }
                                completed = true
                                connection.cancel()
                                if let error {
                                    continuation.resume(throwing: error)
                                } else {
                                    continuation.resume(returning: content ?? Data())
                                }
                            }
                        }
                    }

                    if let data {
                        connection.send(content: data, completion: .contentProcessed { error in
                            if let error {
                                guard !completed else { return }
                                completed = true
                                connection.cancel()
                                continuation.resume(throwing: error)
                            } else {
                                doRead()
                            }
                        })
                    } else {
                        doRead()
                    }
                case .failed(let error):
                    guard !completed else { return }
                    completed = true
                    connection.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                guard !completed else { return }
                completed = true
                connection.cancel()
                continuation.resume(returning: Data())
            }
        }
    }
}

enum PrinterError: LocalizedError {
    case timeout
    case printerNotFound
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "Printer connection timed out"
        case .printerNotFound: return "Printer not found"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        }
    }
}
