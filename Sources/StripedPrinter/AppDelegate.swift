import AppKit
import os

private let logger = Logger(subsystem: "com.striped-printer", category: "App")

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var httpServer: HTTPServer!
    private var httpsServer: HTTPServer!
    private var api: BrowserPrintAPI!
    private var rebuildTimer: Timer?
    private var printerManager: PrinterManager {
        MainActor.assumeIsolated { PrinterManager.shared }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusBar()

        Task { @MainActor in
            printerManager.loadManualPrinters()
            printerManager.startDiscovery()
            startServers()

            // Auto-scan local subnets for printers on port 9100
            let subnets = PrinterManager.getLocalNetworkInfo().subnets
            if !subnets.isEmpty {
                printerManager.scanSubnets(subnets)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    self?.scheduleMenuRebuild()
                }
            }
        }
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "Striped Printer")
        }

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Striped Printer", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(.separator())

        // Server status
        let httpStatus = NSMenuItem(title: "HTTP  :9100  ✓", action: nil, keyEquivalent: "")
        httpStatus.isEnabled = false
        menu.addItem(httpStatus)

        let httpsStatus = NSMenuItem(title: "HTTPS :9101  ✓", action: nil, keyEquivalent: "")
        httpsStatus.isEnabled = false
        menu.addItem(httpsStatus)

        menu.addItem(.separator())

        Task { @MainActor in
            let printers = printerManager.allPrinters
            let defaultUID = printerManager.defaultPrinterUID
            let manualHosts = Set(printerManager.manualPrinters.map(\.host))

            // Printers section
            let printersHeader = NSMenuItem(title: "Printers", action: nil, keyEquivalent: "")
            printersHeader.isEnabled = false
            menu.addItem(printersHeader)

            if printers.isEmpty {
                let noPrinters = NSMenuItem(title: "  No printers found", action: nil, keyEquivalent: "")
                noPrinters.isEnabled = false
                menu.addItem(noPrinters)

                let hint = NSMenuItem(title: "  Use Scan Network or Add Printer", action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            } else {
                for printer in printers {
                    let isManual = manualHosts.contains(printer.host)
                    let source = isManual ? "manual" : "discovered"

                    let item = NSMenuItem(
                        title: "  \(printer.name) — \(printer.host) [\(source)]",
                        action: #selector(selectDefaultPrinter(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = printer.device.uid
                    if printer.device.uid == defaultUID || (defaultUID == nil && printer == printers.first) {
                        item.state = .on
                    }
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())

            // Actions
            let addPrinter = NSMenuItem(title: "Add Printer...", action: #selector(addPrinterAction), keyEquivalent: "a")
            addPrinter.target = self
            menu.addItem(addPrinter)

            let scanNetwork = NSMenuItem(title: "Scan Network...", action: #selector(scanNetworkAction), keyEquivalent: "s")
            scanNetwork.target = self
            menu.addItem(scanNetwork)

            let refresh = NSMenuItem(title: "Refresh Bonjour", action: #selector(refreshDiscovery), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(refresh)

            if !printerManager.manualPrinters.isEmpty {
                menu.addItem(.separator())
                let removeHeader = NSMenuItem(title: "Remove Printer", action: nil, keyEquivalent: "")
                removeHeader.isEnabled = false
                menu.addItem(removeHeader)

                for printer in printerManager.manualPrinters {
                    let item = NSMenuItem(
                        title: "  ✕ \(printer.name) (\(printer.host))",
                        action: #selector(removeManualPrinter(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = printer.host
                    menu.addItem(item)
                }
            }

            menu.addItem(.separator())

            let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(quit)

            self.statusItem.menu = menu
        }
    }

    private func scheduleMenuRebuild() {
        rebuildTimer?.invalidate()
        rebuildTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    // MARK: - Menu Actions

    @objc private func selectDefaultPrinter(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        Task { @MainActor in
            printerManager.setDefaultPrinter(uid)
            scheduleMenuRebuild()
        }
    }

    @objc private func removeManualPrinter(_ sender: NSMenuItem) {
        guard let host = sender.representedObject as? String else { return }
        Task { @MainActor in
            if let printer = printerManager.manualPrinters.first(where: { $0.host == host }) {
                printerManager.removeManualPrinter(printer)
                scheduleMenuRebuild()
            }
        }
    }

    @objc private func addPrinterAction() {
        let alert = NSAlert()
        alert.messageText = "Add Printer"
        alert.informativeText = "Enter the Zebra printer's IP address:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        stackView.orientation = .vertical
        stackView.spacing = 8

        let nameField = NSTextField(frame: .zero)
        nameField.placeholderString = "Printer Name (e.g. 4x6, Shipping Label)"
        nameField.stringValue = ""

        let hostField = NSTextField(frame: .zero)
        hostField.placeholderString = "IP Address (e.g. 10.44.45.177)"

        let portField = NSTextField(frame: .zero)
        portField.placeholderString = "Port (default: 9100)"
        portField.stringValue = "9100"

        stackView.addArrangedSubview(nameField)
        stackView.addArrangedSubview(hostField)
        stackView.addArrangedSubview(portField)

        alert.accessoryView = stackView
        alert.window.initialFirstResponder = hostField

        if alert.runModal() == .alertFirstButtonReturn {
            let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
            let port = UInt16(portField.stringValue) ?? 9100
            let name = nameField.stringValue.isEmpty ? host : nameField.stringValue

            guard !host.isEmpty else { return }

            Task { @MainActor in
                printerManager.addManualPrinter(name: name, host: host, port: port)
                scheduleMenuRebuild()
                logger.info("Added manual printer: \(name) at \(host):\(port)")
            }
        }
    }

    @objc private func scanNetworkAction() {
        let subnets = PrinterManager.getLocalSubnets()

        let alert = NSAlert()
        alert.messageText = "Scan Network for Printers"
        alert.informativeText = "Scan these subnets for devices on port 9100?\nDetected subnets: \(subnets.joined(separator: ", "))\n\nYou can also add additional subnets (comma-separated)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Scan")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = subnets.joined(separator: ", ")
        field.placeholderString = "e.g. 10.44.45, 10.44.46, 10.175.176"
        alert.accessoryView = field

        if alert.runModal() == .alertFirstButtonReturn {
            let input = field.stringValue
            let scanSubnets = input
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard !scanSubnets.isEmpty else { return }

            // Show scanning indicator in menu bar
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Scanning...")
            }

            logger.info("Scanning subnets: \(scanSubnets.joined(separator: ", "))")

            Task { @MainActor in
                printerManager.scanSubnets(scanSubnets)

                // Restore icon and rebuild menu after scan (allow time for probes)
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self else { return }
                    if let button = self.statusItem.button {
                        button.image = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "Striped Printer")
                    }
                    self.scheduleMenuRebuild()
                }
            }
        }
    }

    @objc private func refreshDiscovery() {
        Task { @MainActor in
            printerManager.stopDiscovery()
            printerManager.startDiscovery()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.scheduleMenuRebuild()
            }
        }
    }

    // MARK: - Servers

    private func startServers() {
        api = BrowserPrintAPI(printerManager: printerManager)

        // Start HTTP immediately so the port is available
        httpServer = HTTPServer(port: 9100)
        api.registerRoutes(on: httpServer)

        do {
            try httpServer.start()
            logger.info("HTTP server started on port 9100")
        } catch {
            logger.error("Failed to start HTTP server: \(error.localizedDescription)")
        }

        // Load TLS cert and start HTTPS asynchronously (avoids blocking startup)
        Task.detached { [weak self] in
            let tlsManager = TLSManager()
            guard let identity = tlsManager.getIdentity() else {
                logger.warning("HTTPS server not started (no TLS certificate)")
                return
            }

            await MainActor.run {
                guard let self else { return }
                self.httpsServer = HTTPServer(port: 9101, useTLS: true, tlsIdentity: identity)
                self.api.registerRoutes(on: self.httpsServer)
                do {
                    try self.httpsServer.start()
                    logger.info("HTTPS server started on port 9101")
                } catch {
                    logger.error("Failed to start HTTPS server: \(error.localizedDescription)")
                }
            }
        }
    }
}
