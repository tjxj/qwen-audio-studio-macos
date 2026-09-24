import SwiftUI
import AppKit
import Observation

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

    init(store: any StudioPreferenceStore = UserDefaultsPreferenceStore(defaults: .standard)) {
        self.store = store
        appearance = StudioAppearance(rawValue: store.string(for: "studio.appearance") ?? "") ?? .system
        scriptFont = ScriptFont(rawValue: store.string(for: "studio.scriptFont") ?? "") ?? .sourceHanSerif
        scriptSize = min(26, max(14, Double(store.string(for: "studio.scriptSize") ?? "") ?? 17))
    }
}
