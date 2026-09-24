import Testing
import Foundation
import AVFoundation
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor struct VoiceSheetTests {
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
