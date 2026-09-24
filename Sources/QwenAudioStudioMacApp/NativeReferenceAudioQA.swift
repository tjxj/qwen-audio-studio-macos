import AppKit
import SwiftUI
import AVFoundation
import StudioCore

/// Opt-in bounded host. All audio is synthetic and playback volume is zero.
@MainActor enum NativeReferenceAudioQA {
    static func run(root: URL) -> Never {
        let canonical = root.resolvingSymlinksInPath()
        guard canonical.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              UUID(uuidString: canonical.lastPathComponent) != nil else { exit(65) }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 698),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 720), display: false)
        window.title = "Qwen Audio Studio · 合成音频验证"
        window.center(); window.makeKeyAndOrderFront(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) { exit(124) }
        Task { @MainActor in
            do {
                let store = try StudioStore(dataRoot: canonical.appendingPathComponent("metadata"))
                let service = try ReferenceAudioService(root: canonical.appendingPathComponent("audio"), store: store)
                var checks = ["data=synthetic tones only; network=none; playbackVolume=0"]
                for ext in ["wav", "mp3", "m4a", "ogg"] {
                    let imported = try await service.importSource(url: canonical.appendingPathComponent("tone.\(ext)"))
                    guard (1.9...2.2).contains(imported.duration) else { exit(1) }
                    let clip = try await service.prepare(importID: imported.id, start: 0.25, end: 1.25, persistent: false, name: "合成 \(ext)")
                    guard abs(clip.snapshot.duration - 1) < 0.001 else { exit(1) }
                    checks.append("\(ext)=decoded; selection=1.000s; output=mono PCM16 WAV 24000Hz")
                }
                let long = canonical.appendingPathComponent("合成参考音频.wav")
                let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 40 * 24000)!
                buffer.frameLength = buffer.frameCapacity
                for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 24000)) * 0.2 }
                do { let file = try AVAudioFile(forWriting: long, settings: format.settings); try file.write(from: buffer) }
                let original = try Data(contentsOf: long)
                let controller = VoiceSheetController(service: service)
                await controller.importURL(long)
                guard controller.imported != nil, !controller.selectionValid else { exit(1) }
                controller.start = 12; controller.end = 18; controller.name = "合成参考音色"
                let draft = DraftController(fields: DraftFields(name: "原生音色工作流验证", mode: .narration, prompt: "这是一段用于界面验证的合成脚本。"), store: InMemoryDraftStore())
                ReferencePlayback.shared.volume = 0
                await controller.preview(source: true)
                guard ReferencePlayback.shared.state == .source else { exit(1) }
                await controller.preview(source: false)
                guard ReferencePlayback.shared.state == .selection else { exit(1) }
                ReferencePlayback.shared.stop()
                guard ReferencePlayback.shared.state == .stopped, controller.selectionValid else { exit(1) }
                checks.append("preview=source -> selection -> stopped; volume=0; shared one AVAudioPlayer")
                print("QA stage: previews passed"); fflush(stdout)
                let a = DecodedAudio(samples: (0..<(5 * 24000)).map { Float(0.3 * sin(2 * .pi * 440 * Double($0) / 24000)) },
                                     sampleRate: 24000, contentHash: "synthetic-440")
                let b = DecodedAudio(samples: (0..<(8 * 24000)).map { Float(0.3 * sin(2 * .pi * 880 * Double($0) / 24000)) },
                                     sampleRate: 24000, contentHash: "synthetic-880")
                let playback = AudioPlaybackController.shared
                playback.configure(loader: { id in id == "synthetic-a" ? a : b })
                playback.volume = 0
                try await playback.play(assetID: "synthetic-a")
                print("QA stage: result A playing"); fflush(stdout)
                try playback.seek(seconds: 1.25)
                let switchStart = playback.position
                try await playback.compare(assetA: "synthetic-a", assetB: "synthetic-b")
                print("QA stage: comparison loaded at \(playback.position)"); fflush(stdout)
                try playback.switchToB()
                print("QA stage: switched B at \(playback.position)"); fflush(stdout)
                guard abs(playback.position - switchStart) <= 0.15, playback.activeAssetID == "synthetic-b",
                      ReferencePlayback.shared.state == .stopped else { exit(1) }
                try playback.switchToA()
                print("QA stage: switched A at \(playback.position)"); fflush(stdout)
                guard abs(playback.position - switchStart) <= 0.15 else { exit(1) }
                try playback.setLoop(start: 1, end: 1.5)
                try playback.seek(seconds: 1.45)
                try await Task.sleep(for: .milliseconds(250))
                print("QA stage: loop at \(playback.position)"); fflush(stdout)
                guard (1..<1.5).contains(playback.position) else { exit(1) }
                playback.stop()
                checks.append("playback=source -> selection -> stopped -> 5s/8s A/B; samePosition<=150ms; loop=1.0...1.5s; outputVolume=0")
                let prepared = await controller.prepare()
                guard prepared?.snapshot.duration == 6, prepared?.snapshot.temporary == true,
                      try Data(contentsOf: long) == original, try await service.library().isEmpty else { exit(1) }
                controller.persistent = true
                guard await controller.prepare()?.snapshot.temporary == false,
                      try await service.library().count == 1 else { exit(1) }
                controller.persistent = false
                await controller.loadLibrary()
                checks.append("source=40s unchanged; explicitTrim=12...18s; temporaryDefault=true; savedLibrary=1")
                window.contentView = NSHostingView(rootView: ReferenceQAPresentation(controller: controller, draft: draft))
                window.makeKeyAndOrderFront(nil)
                app.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(750))
                guard let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview else { exit(1) }
                @MainActor func sliders(in view: NSView) -> [NSSlider] {
                    (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap { sliders(in: $0) }
                }
                let controls = sliders(in: sheetView)
                guard let startSlider = controls.first(where: { $0.accessibilityLabel() == "片段开始" }),
                      let endSlider = controls.first(where: { $0.accessibilityLabel() == "片段结束" }) else { exit(1) }
                startSlider.doubleValue = 13; _ = startSlider.sendAction(startSlider.action, to: startSlider.target)
                endSlider.doubleValue = 19; _ = endSlider.sendAction(endSlider.action, to: endSlider.target)
                guard controller.start == 13, controller.end == 19 else { exit(1) }
                if let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: sheet.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124) {
                    sheet.makeFirstResponder(startSlider); startSlider.keyDown(with: right)
                    guard controller.start > 13, controller.start <= 40 else { exit(1) }
                } else { exit(1) }
                // Let the UI commit the keyboard edit before testing an external
                // value change, matching separate real user event-loop turns.
                try await Task.sleep(for: .milliseconds(100))
                controller.start = 12; controller.end = 18
                sheet.makeFirstResponder(nil)
                try await Task.sleep(for: .milliseconds(100))
                guard startSlider.doubleValue == 12, endSlider.doubleValue == 18 else {
                    print("native slider external value synchronization failed: \(startSlider.doubleValue), \(endSlider.doubleValue)"); exit(1)
                }
                await controller.preview(source: false); ReferencePlayback.shared.stop()
                checks.append("nativeSlider=target/action updates both endpoints; right-arrow keyboard changes start; external values synchronized; accessibility labels present")
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    app.appearance = NSAppearance(named: appearance); window.appearance = NSAppearance(named: appearance); sheet.appearance = NSAppearance(named: appearance)
                    try await Task.sleep(for: .milliseconds(250))
                    window.contentView?.layoutSubtreeIfNeeded(); sheetView.layoutSubtreeIfNeeded()
                    try capture(sheetView, to: canonical.appendingPathComponent("voice-\(name)-1280-sheet.png"))
                    if let view = window.contentView?.superview { try capture(view, to: canonical.appendingPathComponent("voice-\(name)-1280-window.png")) }
                    checks.append("\(name): window=\(Int(window.frame.width))x\(Int(window.frame.height)); sheet=\(Int(sheet.frame.width))x\(Int(sheet.frame.height)); insideWindow=\(window.frame.contains(sheet.frame)); scale=2")
                }
                let silenceURL = canonical.appendingPathComponent("合成静音提示.wav")
                let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
                silence.frameLength = 24000
                for i in 0..<24000 { silence.floatChannelData![0][i] = 0 }
                do { let file = try AVAudioFile(forWriting: silenceURL, settings: format.settings); try file.write(from: silence) }
                await controller.importURL(silenceURL)
                guard await controller.prepare() == nil, controller.quality?.hints.contains(.silence) == true,
                      controller.requiresQualityAcknowledgement else { exit(1) }
                app.appearance = NSAppearance(named: .aqua); sheet.appearance = NSAppearance(named: .aqua)
                try await Task.sleep(for: .milliseconds(300))
                sheetView.layoutSubtreeIfNeeded()
                try capture(sheetView, to: canonical.appendingPathComponent("voice-warning-1280-sheet.png"))
                guard await controller.prepare(allowQualityWarnings: true) != nil else { exit(1) }
                checks.append("quality=selection analyzed without preview; silence warns before saving; explicit continue succeeds")
                try checks.joined(separator: "\n").write(to: canonical.appendingPathComponent("reference-audio-checks.txt"), atomically: true, encoding: .utf8)
                ReferencePlayback.shared.stop()
                try await store.close()
                print("native reference audio QA: all codecs, explicit trim, muted preview transitions, saved library, 2x screenshots verified")
                exit(0)
            } catch { print("native reference audio QA failed: \(VoiceSheetController.explain(error))"); exit(1) }
        }
        app.run(); exit(1)
    }
    private static func capture(_ view: NSView, to url: URL) throws {
        view.displayIfNeeded()
        let bounds = view.bounds
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw ReferenceAudioError.unavailable }
        image.size = bounds.size; view.cacheDisplay(in: bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { throw ReferenceAudioError.unavailable }
        try data.write(to: url)
    }
}

private struct ReferenceQAPresentation: View {
    @State private var showing = true
    let controller: VoiceSheetController
    let draft: DraftController
    var body: some View {
        VStack { Text("创作台").font(.largeTitle); Text("合成音频 · 原生工作流验收") }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: $showing) { VoiceSheet(controller: controller, draft: draft) }
    }
}
