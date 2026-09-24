import Testing
import SwiftUI
import AppKit
import StudioCore
@testable import QwenAudioStudioMacApp

@MainActor @Suite(.serialized)
struct TemplateApplicationTests {
    @Test func editorRecreationKeepsNativeTextStorageAndEarlierUndoHistory() async throws {
        _ = NSApplication.shared
        let draft = DraftController(fields: .init(prompt: "开始"), store: InMemoryDraftStore())
        let application = TemplateApplicationController(draft: draft)
        let handle = PromptEditorHandle()
        let binding = Binding(get: { draft.fields.prompt }, set: { text in draft.change { $0.prompt = text } })
        let root = PromptEditor(text: binding, font: .systemFont(ofSize: 17), handle: handle, sharedUndoManager: application.undoManager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        let first = try #require(handle.textView)
        first.setSelectedRange(NSRange(location: 2, length: 0))
        handle.insert("一行")
        window.contentView = nil
        let preview = try TemplateEngine().preview(templateID: "rain-podcast", values: [:])
        application.apply(preview)
        window.contentView = NSHostingView(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(handle.textView === first)
        application.undoManager.undo()
        try await Task.sleep(for: .milliseconds(50))
        #expect(draft.fields.prompt == "开始一行")
        application.undoManager.undo()
        #expect(draft.fields.prompt == "开始")
    }

    @Test func templateThenNativeTypingUndoInOrderAcrossEditorRecreation() async throws {
        _ = NSApplication.shared
        let before = DraftFields(name: "原来的作品", mode: .game, prompt: "原稿🎵")
        let draft = DraftController(fields: before, store: InMemoryDraftStore())
        let application = TemplateApplicationController(draft: draft)
        let preview = try TemplateEngine().preview(templateID: "rain-podcast", values: [:])
        application.apply(preview)
        let handle = PromptEditorHandle()
        let binding = Binding(get: { draft.fields.prompt }, set: { text in draft.change { $0.prompt = text } })
        let root = PromptEditor(text: binding, font: .systemFont(ofSize: 17), handle: handle, sharedUndoManager: application.undoManager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        let editor = try #require(handle.textView)
        #expect(editor.undoManager === application.undoManager)
        let manager = application.undoManager
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        handle.insert("追加句。")
        #expect(draft.fields.prompt == preview.prompt + "追加句。")
        manager.undo()
        #expect(draft.fields.prompt == preview.prompt)
        manager.undo()
        try await Task.sleep(for: .milliseconds(50))
        #expect(draft.fields == before)
        manager.redo()
        try await Task.sleep(for: .milliseconds(50))
        #expect(draft.fields.prompt == preview.prompt)
    }
}
