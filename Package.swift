// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QwenAudioStudioMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StudioCore", targets: ["StudioCore"]),
        .executable(name: "QwenAudioStudioMacApp", targets: ["QwenAudioStudioMacApp"]),
    ],
    targets: [
        .target(name: "StudioCore", resources: [.process("Resources")]),
        .executableTarget(name: "QwenAudioStudioMacApp", dependencies: ["StudioCore"]),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"]),
        .testTarget(name: "StudioAppTests", dependencies: ["QwenAudioStudioMacApp", "StudioCore"]),
    ]
)
