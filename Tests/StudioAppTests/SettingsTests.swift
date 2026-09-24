import Foundation
import Testing
@testable import QwenAudioStudioMacApp

@MainActor struct SettingsTests {
    @Test func generationDefaultsPersistWithoutChangingOtherPreferences() {
        let suite = "settings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = StudioPreferences(store: UserDefaultsPreferenceStore(defaults: defaults))
        first.defaultFormat = "mp3"
        first.defaultSampleRate = 24000
        first.defaultCandidates = 3
        first.defaultConcurrency = 2
        let second = StudioPreferences(store: UserDefaultsPreferenceStore(defaults: defaults))
        #expect(second.defaultFormat == "mp3")
        #expect(second.defaultSampleRate == 24000)
        #expect(second.defaultCandidates == 3)
        #expect(second.defaultConcurrency == 2)
        #expect(second.appearance == .system)
    }
}
