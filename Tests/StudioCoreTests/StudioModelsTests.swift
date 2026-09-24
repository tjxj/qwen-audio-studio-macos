import Testing
@testable import StudioCore

struct StudioModelsTests {
    @Test func creationModesKeepStablePersistedIDs() {
        #expect(CreationMode.allCases.map(\.rawValue) == [
            "podcast", "advertisement", "audiobook", "drama",
            "game", "narration", "auto",
        ])
    }

    @Test func mainWindowSupportsOneScreenMinimum() {
        #expect(StudioLayout.minWidth == 1120)
        #expect(StudioLayout.minHeight == 720)
    }

    @Test func generationDefaultsMatchExistingWorkflow() {
        let params = GenerationParams()
        #expect(params.format == "wav")
        #expect(params.sampleRate == 48000)
        #expect(params.channels == 2)
        #expect(params.volume == 50)
        #expect(params.bitRate == 128)
        #expect(params.enableAIGCTag == false)
    }

}
