// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProcessesMenu",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ProcessesMenu")
    ]
)
