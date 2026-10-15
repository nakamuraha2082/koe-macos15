// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "Koe",
            path: "Sources/Koe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
