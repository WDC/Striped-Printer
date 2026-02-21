import Foundation

// MARK: - Device Model (matches Browser Print JSON format)

struct PrinterDevice: Codable, Identifiable, Hashable {
    var id: String { uid }

    let deviceType: String
    let uid: String
    let provider: String
    let name: String
    let connection: String
    let version: Int
    let manufacturer: String

    init(
        name: String,
        uid: String? = nil,
        connection: String = "network",
        deviceType: String = "printer",
        version: Int = 3,
        provider: String = "com.zebra.ds.webdriver.desktop.provider.DefaultDeviceProvider",
        manufacturer: String = "Zebra Technologies"
    ) {
        self.deviceType = deviceType
        self.uid = uid ?? name
        self.provider = provider
        self.name = name
        self.connection = connection
        self.version = version
        self.manufacturer = manufacturer
    }
}

// MARK: - Network Printer (internal tracking)

struct NetworkPrinter: Hashable {
    let name: String
    let host: String
    let port: UInt16

    var device: PrinterDevice {
        PrinterDevice(
            name: name,
            uid: "\(host):\(port)",
            connection: "network"
        )
    }
}

// MARK: - API Request/Response Models

struct WriteRequest: Codable {
    let device: PrinterDevice
    let data: String?
    let url: String?
}

struct ReadRequest: Codable {
    let device: PrinterDevice
}

struct AvailableResponse: Codable {
    let printer: [PrinterDevice]
}

struct ApplicationConfig: Codable {
    struct Application: Codable {
        let supportedConversions: [String: [String]]
        let version: String
        let apiLevel: Int
        let buildNumber: Int
        let platform: String
    }

    let application: Application

    static let current = ApplicationConfig(
        application: Application(
            supportedConversions: [
                "jpg": ["cpcl", "zpl", "kpl"],
                "tif": ["cpcl", "zpl", "kpl"],
                "pdf": ["cpcl", "zpl", "kpl"],
                "bmp": ["cpcl", "zpl", "kpl"],
                "pcx": ["cpcl", "zpl", "kpl"],
                "gif": ["cpcl", "zpl", "kpl"],
                "png": ["cpcl", "zpl", "kpl"],
                "jpeg": ["cpcl", "zpl", "kpl"],
            ],
            version: "1.3.2.489",
            apiLevel: 5,
            buildNumber: 489,
            platform: "macos"
        )
    )
}
