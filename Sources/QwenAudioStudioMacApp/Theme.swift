import SwiftUI
import AppKit
import Observation
import StudioCore

enum StudioAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

enum ScriptFont: String, CaseIterable, Identifiable {
    case sourceHanSerif, system
    var id: String { rawValue }
    var title: String { self == .sourceHanSerif ? "思源宋体" : "系统字体" }
    func font(size: CGFloat) -> NSFont {
        self == .sourceHanSerif
            ? NSFont(name: "QwenStudioSerif-Regular", size: size) ?? .systemFont(ofSize: size)
            : .systemFont(ofSize: size)
    }
    func swiftUIFont(size: CGFloat) -> Font {
        self == .sourceHanSerif
            ? .custom("QwenStudioSerif-Regular", size: size)
            : .system(size: size)
    }
}

/// Replace this adapter when settings move into the SQLite store.
@MainActor protocol StudioPreferenceStore {
    func string(for key: String) -> String?
    func set(_ value: String, for key: String)
}

struct UserDefaultsPreferenceStore: StudioPreferenceStore {
    let defaults: UserDefaults
    func string(for key: String) -> String? { defaults.string(forKey: key) }
    func set(_ value: String, for key: String) { defaults.set(value, forKey: key) }
}

@MainActor @Observable final class StudioPreferences {
    private let store: any StudioPreferenceStore
    var appearance: StudioAppearance { didSet { store.set(appearance.rawValue, for: "studio.appearance") } }
    var scriptFont: ScriptFont { didSet { store.set(scriptFont.rawValue, for: "studio.scriptFont") } }
    var scriptSize: Double { didSet { store.set(String(scriptSize), for: "studio.scriptSize") } }
    var defaultFormat: String { didSet { store.set(defaultFormat, for: "studio.defaultFormat") } }
    var defaultSampleRate: Int { didSet { store.set(String(defaultSampleRate), for: "studio.defaultSampleRate") } }
    var defaultCandidates: Int { didSet { store.set(String(defaultCandidates), for: "studio.defaultCandidates") } }
    var defaultConcurrency: Int { didSet { store.set(String(defaultConcurrency), for: "studio.defaultConcurrency") } }
    var defaultParams: GenerationParams { GenerationParams(format: defaultFormat, sampleRate: defaultSampleRate) }

    // OpenAI-compatible Chat Model Preferences for AI Scriptwriter
    var chatAPIBaseURL: String { didSet { store.set(chatAPIBaseURL, for: "studio.chatAPIBaseURL") } }
    var chatAPIKey: String { didSet { store.set(chatAPIKey, for: "studio.chatAPIKey") } }
    var chatModelName: String { didSet { store.set(chatModelName, for: "studio.chatModelName") } }

    init(store: any StudioPreferenceStore = UserDefaultsPreferenceStore(defaults: .standard)) {
        self.store = store
        appearance = StudioAppearance(rawValue: store.string(for: "studio.appearance") ?? "") ?? .system
        scriptFont = ScriptFont(rawValue: store.string(for: "studio.scriptFont") ?? "") ?? .sourceHanSerif
        scriptSize = min(28, max(12, Double(store.string(for: "studio.scriptSize") ?? "") ?? 14))
        let format = store.string(for: "studio.defaultFormat") ?? "wav"
        defaultFormat = ["wav", "mp3", "pcm"].contains(format) ? format : "wav"
        let rate = Int(store.string(for: "studio.defaultSampleRate") ?? "") ?? 48000
        defaultSampleRate = [8000, 16000, 24000, 44100, 48000].contains(rate) ? rate : 48000
        defaultCandidates = min(3, max(1, Int(store.string(for: "studio.defaultCandidates") ?? "") ?? 1))
        defaultConcurrency = min(3, max(1, Int(store.string(for: "studio.defaultConcurrency") ?? "") ?? 1))

        let url = store.string(for: "studio.chatAPIBaseURL") ?? "https://api.deepseek.com/v1"
        chatAPIBaseURL = url.isEmpty ? "https://api.deepseek.com/v1" : url
        chatAPIKey = store.string(for: "studio.chatAPIKey") ?? ""
        let model = store.string(for: "studio.chatModelName") ?? "deepseek-v4.1-flash"
        chatModelName = model.isEmpty ? "deepseek-v4.1-flash" : model
    }
}
