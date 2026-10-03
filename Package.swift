// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Heron",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Heron", path: "Sources/Heron")
    ]
)
