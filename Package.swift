// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StripedPrinter",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "StripedPrinter",
            path: "Sources/StripedPrinter",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
