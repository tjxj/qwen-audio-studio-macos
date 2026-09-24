import Testing
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor struct VoiceSheetTests {
    @Test func removedVoiceTokenNeverBindsToNewAudio() {
        let fields = DraftFields(prompt: "旧台词 @voice1，新台词 @voice3", referenceBindings: [.init(referenceID: "existing", alias: "合成", slot: 3)])
        #expect(VoiceSheetController.nextSlot(fields: fields) == 2)
        let full = DraftFields(prompt: "@voice1 @voice2 @voice3")
        #expect(VoiceSheetController.nextSlot(fields: full) == nil)
    }
}
