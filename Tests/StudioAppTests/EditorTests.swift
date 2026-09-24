import Testing
import SwiftUI
import AppKit
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor @Suite(.serialized)
struct EditorTests {
    @Test func tagInsertionReplacesUTF16SelectionAndUndoRestoresBoundDraft() async throws {
        _ = NSApplication.shared
        let draft = DraftController(fields: DraftFields(prompt: "开场🎵与结尾"), store: InMemoryDraftStore())
        let handle = PromptEditorHandle()
        let binding = Binding(get: { draft.fields.prompt }, set: { text in draft.change { $0.prompt = text } })
        let root = PromptEditor(text: binding, font: .systemFont(ofSize: 17), handle: handle)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        let editor = try #require(handle.textView)
        editor.setSelectedRange(NSRange(location: 2, length: 2))
        let undo = try #require(editor.undoManager)
        undo.beginUndoGrouping()
        handle.insert("【音乐】")
        undo.endUndoGrouping()
        #expect(draft.fields.prompt == "开场【音乐】与结尾")
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
        #expect(window.firstResponder === editor)
        undo.undo()
        #expect(editor.string == "开场🎵与结尾")
        try await Task.sleep(for: .milliseconds(50))
        #expect(draft.fields.prompt == "开场🎵与结尾")
        undo.redo()
        #expect(draft.fields.prompt == "开场【音乐】与结尾")
    }

    @Test func preferencesSurviveRecreationOfAdapter() throws {
        let suite = "studio-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = StudioPreferences(store: UserDefaultsPreferenceStore(defaults: defaults))
        preferences.appearance = .dark
        preferences.scriptFont = .system
        preferences.scriptSize = 23
        let reloaded = StudioPreferences(store: UserDefaultsPreferenceStore(defaults: defaults))
        #expect(reloaded.appearance == .dark)
        #expect(reloaded.scriptFont == .system)
        #expect(reloaded.scriptSize == 23)
    }
}
