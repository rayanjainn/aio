// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cortex",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Cortex", path: "Sources/Cortex"),
    ]
)
