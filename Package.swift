// swift-tools-version: 6.0
import PackageDescription
import Foundation

let codecs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build/native-codecs")

let package = Package(
    name: "QwenAudioStudioMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StudioCore", targets: ["StudioCore"]),
        .executable(name: "QwenAudioStudioMacApp", targets: ["QwenAudioStudioMacApp"]),
    ],
    targets: [
        .target(name: "COpusBridge", cSettings: [.unsafeFlags(["-I" + codecs.appendingPathComponent("include/opus").path, "-I" + codecs.appendingPathComponent("include").path])],
                linkerSettings: [.unsafeFlags([codecs.appendingPathComponent("lib/libopusfile.a").path, codecs.appendingPathComponent("lib/libopus.a").path, codecs.appendingPathComponent("lib/libogg.a").path])]),
        .target(name: "StudioCore", dependencies: ["COpusBridge"], resources: [.process("Resources")]),
        .executableTarget(name: "QwenAudioStudioMacApp", dependencies: ["StudioCore"]),
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"], exclude: ["Fixtures"]),
        .testTarget(name: "StudioAppTests", dependencies: ["QwenAudioStudioMacApp", "StudioCore"]),
    ]
)
