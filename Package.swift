// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VibeStickKeys",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "vibe-keys", targets: ["vibe-keys"]),
        .executable(name: "vibe-keys-ui", targets: ["vibe-keys-ui"]),
    ],
    targets: [
        .target(name: "StudioProtocol"),
        .target(name: "StickModel", dependencies: ["StudioProtocol"]),
        .target(name: "StudioBle", dependencies: ["StudioProtocol"]),
        .executableTarget(name: "vibe-keys", dependencies: ["StudioProtocol", "StudioBle"]),
        .executableTarget(name: "vibe-keys-ui", dependencies: ["StickModel", "StudioBle", "StudioProtocol"]),
        .testTarget(name: "StudioProtocolTests", dependencies: ["StudioProtocol"]),
        .testTarget(name: "StickModelTests", dependencies: ["StickModel", "StudioProtocol"]),
    ],
    swiftLanguageModes: [.v5]
)
