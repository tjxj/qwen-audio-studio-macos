import Testing
import Foundation
import AVFoundation
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor struct VoiceSheetTests {
    @Test func reverseCompletedPreviewsAndStopNeverResurrectStaleAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.2 }
        try autoreleasepool { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        let store = try StudioStore(dataRoot: root.appendingPathComponent("metadata"))
        let service = try ReferenceAudioService(root: root.appendingPathComponent("audio"), store: store)
        let transport = AudioPlaybackController(loader: { _ in throw AudioPlaybackError.missingAsset })
        transport.volume = 0
        defer { transport.stop() }
        let playback = ReferencePlayback(transport: transport)
        let gate = OrderedVoicePreviewGate()
        let controller = VoiceSheetController(service: service, playback: playback,
            previewLoader: { _, isSource, _, _ in await gate.load(source: isSource) })
        await controller.importURL(source)
        controller.start = 0; controller.end = 1
        let oldSource = Task { await controller.preview(source: true) }
        await gate.untilWaiting(source: true)
        let newerSelection = Task { await controller.preview(source: false) }
        await gate.untilWaiting(source: false)
        let bytes = try Data(contentsOf: source)
        gate.release(source: false, payload: (bytes, nil))
        await newerSelection.value
        #expect(playback.state == .selection)
        gate.release(source: true, payload: (bytes, nil))
        await oldSource.value
        #expect(playback.state == .selection)

        let stoppedLate = Task { await controller.preview(source: true) }
        await gate.untilWaiting(source: true)
        #expect(controller.previewPending)
        controller.cancelPreview()
        #expect(!controller.previewPending)
        #expect(playback.state == .stopped)
        gate.release(source: true, payload: (bytes, nil))
        await stoppedLate.value
        #expect(playback.state == .stopped)
    }
    @Test func delayedPreviewCannotStealResultsAfterTrimChangeOrDismissal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.2 }
        try autoreleasepool { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        let store = try StudioStore(dataRoot: root.appendingPathComponent("metadata"))
        let service = try ReferenceAudioService(root: root.appendingPathComponent("audio"), store: store)
        let result = DecodedAudio(samples: Array(repeating: 0.2, count: 48_000), sampleRate: 24_000, contentHash: "result")
        let transport = AudioPlaybackController(loader: { _ in result })
        transport.volume = 0
        defer { transport.stop() }
        let preview = ReferencePlayback(transport: transport)
        let gate = VoicePreviewGate()
        let controller = VoiceSheetController(service: service, playback: preview,
            previewLoader: { _, _, _, _ in await gate.load() })
        await controller.importURL(source)
        controller.start = 0; controller.end = 1
        try await transport.play(assetID: "result")
        let first = Task { await controller.preview(source: false) }
        await gate.untilWaiting()
        controller.start = 0.5
        gate.release((try Data(contentsOf: source), nil))
        await first.value
        #expect(transport.activeAssetID == "result")
        #expect(preview.state == .stopped)
        let second = Task { await controller.preview(source: false) }
        await gate.untilWaiting()
        controller.cancelPreview()
        gate.release((try Data(contentsOf: source), nil))
        await second.value
        #expect(transport.activeAssetID == "result")
        #expect(preview.state == .stopped)
    }
    @Test(arguments: [Float(0), Float(1), Float(0.25)])
    func savingAnalyzesCurrentSelectionAndWarnsBeforeSilenceOrClipping(amplitude: Float) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for i in 0..<48000 { buffer.floatChannelData![0][i] = i < 24000 ? amplitude : 0.25 }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        let store = try StudioStore(dataRoot: root.appendingPathComponent("metadata"))
        let service = try ReferenceAudioService(root: root.appendingPathComponent("audio"), store: store)
        let controller = VoiceSheetController(service: service)
        await controller.importURL(source)
        controller.start = 0; controller.end = 1
        controller.quality = nil // Reproduce a changed trim without an optional preview.
        let saved = await controller.prepare()
        if amplitude == 0 || amplitude == 1 {
            #expect(saved == nil)
            #expect(controller.quality?.hints.contains(amplitude == 0 ? .silence : .clipping) == true)
            #expect(controller.message != nil)
            #expect(try await store.listReferences().isEmpty)
            #expect(await controller.prepare(allowQualityWarnings: true) != nil)
        } else { #expect(saved != nil) }
        controller.start = 1; controller.end = 2
        await controller.analyzeSelection()
        #expect(controller.quality?.hints.isEmpty == true)
        #expect(await controller.prepare() != nil)
    }
    @Test func removedVoiceTokenNeverBindsToNewAudio() {
        let fields = DraftFields(prompt: "旧台词 @voice1，新台词 @voice3", referenceBindings: [.init(referenceID: "existing", alias: "合成", slot: 3)])
        #expect(VoiceSheetController.nextSlot(fields: fields) == 2)
        let full = DraftFields(prompt: "@voice1 @voice2 @voice3")
        #expect(VoiceSheetController.nextSlot(fields: full) == nil)
    }
}

@MainActor private final class OrderedVoicePreviewGate {
    private var waiting: [Bool: CheckedContinuation<(Data, AudioSignalQuality?), Never>] = [:]
    private var arrivals: [Bool: CheckedContinuation<Void, Never>] = [:]
    func load(source: Bool) async -> (Data, AudioSignalQuality?) {
        await withCheckedContinuation { continuation in
            waiting[source] = continuation
            arrivals.removeValue(forKey: source)?.resume()
        }
    }
    func untilWaiting(source: Bool) async {
        if waiting[source] != nil { return }
        await withCheckedContinuation { arrivals[source] = $0 }
    }
    func release(source: Bool, payload: (Data, AudioSignalQuality?)) {
        waiting.removeValue(forKey: source)?.resume(returning: payload)
    }
}

@MainActor private final class VoicePreviewGate {
    private var waiting: CheckedContinuation<(Data, AudioSignalQuality?), Never>?
    func load() async -> (Data, AudioSignalQuality?) { await withCheckedContinuation { waiting = $0 } }
    func untilWaiting() async {
        for _ in 0..<100 where waiting == nil { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func release(_ payload: (Data, AudioSignalQuality?)) { waiting?.resume(returning: payload); waiting = nil }
}
