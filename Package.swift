// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Kukatko",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Kukatko",
            path: "Sources/Kukatko",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
