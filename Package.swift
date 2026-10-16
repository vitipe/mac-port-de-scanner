// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Scanner",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "ScannerCore"),
        .executableTarget(name: "Scanner", dependencies: ["ScannerCore"]),
        .testTarget(name: "ScannerCoreTests", dependencies: ["ScannerCore"]),
    ]
)
