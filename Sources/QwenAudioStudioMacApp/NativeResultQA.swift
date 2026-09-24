import AppKit
import SwiftUI
import CoreText
import StudioCore

/// Isolated, bounded native capture. The only media is deterministic synthetic tones.
@MainActor enum NativeResultQA {
    static func run(root: URL) -> Never {
        let canonical = root.resolvingSymlinksInPath()
        guard canonical.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              UUID(uuidString: canonical.lastPathComponent) != nil else { exit(65) }
        let app = NSApplication.shared
        if let fontURL = Bundle.main.url(forResource: "QwenStudioSerif-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 698),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 720), display: false)
        window.title = "Qwen Audio Studio · 合成结果页"
        window.center(); window.makeKeyAndOrderFront(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exit(124) }
        Task { @MainActor in
            do {
                let a = try AudioDecoder.decode(data: tone(seconds: 5, hertz: 440))
                let b = try AudioDecoder.decode(data: tone(seconds: 8, hertz: 880))
                let controller = ResultScreenController(candidates: [
                    ResultCandidate(id: "synthetic-a", number: 1, state: .success, assetID: "synthetic-audio-a", isFinal: true),
                    ResultCandidate(id: "synthetic-b", number: 2, state: .success, assetID: "synthetic-audio-b"),
                    ResultCandidate(id: "synthetic-missing", number: 3, state: .success, assetID: "synthetic-missing"),
                ], loader: { id in
                    switch id { case "synthetic-audio-a": a; case "synthetic-audio-b": b; default: throw AudioPlaybackError.missingAsset }
                })
                await controller.validate()
                guard controller.rows.map(\.playable) == [true, true, false] else { exit(1) }
                window.contentView = NSHostingView(rootView: ResultScreen(controller: controller))
                app.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(500))
                var checks = ["data=synthetic 440Hz 5s and 880Hz 8s; network=none; credentials=none",
                              "versions=3; playable=2; missing=1; actualPCMDecode=true"]
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    app.appearance = NSAppearance(named: appearance)
                    window.appearance = NSAppearance(named: appearance)
                    try await Task.sleep(for: .milliseconds(250))
                    guard let view = window.contentView?.superview else { exit(1) }
                    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                    let bounds = view.bounds
                    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    image.size = bounds.size
                    view.cacheDisplay(in: bounds, to: image)
                    try image.representation(using: .png, properties: [:])!.write(to: canonical.appendingPathComponent("result-\(name)-1280.png"))
                    checks.append("\(name): pixels=\(image.pixelsWide)x\(image.pixelsHigh); scale=2")
                }
                try checks.joined(separator: "\n").write(to: canonical.appendingPathComponent("result-checks.txt"), atomically: true, encoding: .utf8)
                print("native result QA: 3 versions, 2 decoded, 1 missing, light/dark Retina screenshots")
                exit(0)
            } catch { print("native result QA failed: \(error.localizedDescription)"); exit(1) }
        }
        app.run(); exit(1)
    }
    private static func tone(seconds: Int, hertz: Double) throws -> Data {
        var data = Data()
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let frames = seconds * 24_000
        data.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + frames * 2)); data.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16)
        data.append(contentsOf: "data".utf8); u32(UInt32(frames * 2))
        for i in 0..<frames { u16(UInt16(bitPattern: Int16(0.5 * 32767 * sin(2 * .pi * hertz * Double(i) / 24_000)))) }
        return data
    }
}
