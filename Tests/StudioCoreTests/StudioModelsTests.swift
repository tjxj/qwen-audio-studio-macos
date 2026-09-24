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

    @Test func sampleTemplateSelectionHasDistinctCompletePreviews() {
        let previews = ShellPreviewTemplate.samples
        #expect(previews.count == 3)
        #expect(Set(previews.map(\.id)).count == previews.count)
        #expect(Set(previews.map(\.title)).count == previews.count)
        #expect(Set(previews.map(\.subtitle)).count == previews.count)
        #expect(Set(previews.map(\.script)).count == previews.count)
        for preview in previews {
            #expect(!preview.subtitle.isEmpty)
            #expect(preview.script.contains("【"))
            #expect(preview.script.contains(preview.topic))
        }
    }

    @Test func sampleTemplateLookupReturnsMatchingTitleSubtitleAndScript() {
        let first = ShellPreviewTemplate.sample(id: 1)
        let second = ShellPreviewTemplate.sample(id: 2)
        #expect(first?.title == "雨夜陪伴")
        #expect(first?.subtitle.contains("雨声") == true)
        #expect(first?.script.contains("雨声") == true)
        #expect(second?.title == "双人科技访谈")
        #expect(second?.subtitle.contains("谈话") == true)
        #expect(second?.script.contains("科技") == true)
        #expect(ShellPreviewTemplate.sample(id: 99) == nil)
    }
}
