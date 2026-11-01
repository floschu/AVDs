// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AVDs",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "AVDs", path: "Sources/AVDs")]
)
