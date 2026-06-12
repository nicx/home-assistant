// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HomeAssistant",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HomeAssistant",
            path: "Sources/HomeAssistant"
        )
    ],
    swiftLanguageModes: [.v5]
)
