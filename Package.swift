// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacroClicker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacroClicker", path: "Sources/MacroClicker")
    ]
)
