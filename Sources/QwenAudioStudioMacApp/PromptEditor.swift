import SwiftUI
import AppKit

@MainActor final class PromptEditorHandle {
    weak var textView: NSTextView?

    func insert(_ text: String) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}

struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let handle: PromptEditorHandle

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let editor = NSTextView()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.drawsBackground = false
        editor.setAccessibilityIdentifier("draft-prompt-editor")
        editor.setAccessibilityLabel("创作脚本")
        editor.delegate = context.coordinator
        context.coordinator.editor = editor
        scroll.documentView = editor
        editor.string = text
        handle.textView = editor
        applyStyle(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text && !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            editor.undoManager?.removeAllActions()
        }
        applyStyle(editor)
    }

    private func applyStyle(_ editor: NSTextView) {
        editor.font = font
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        editor.textStorage?.addAttributes([.paragraphStyle: paragraph], range: NSRange(location: 0, length: (editor.string as NSString).length))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        weak var editor: NSTextView?
        init(_ parent: PromptEditor) {
            self.parent = parent
            super.init()
            // AppKit undo can update storage without a textDidChange callback.
            NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedo(_:)),
                name: .NSUndoManagerDidUndoChange, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(undoOrRedo(_:)),
                name: .NSUndoManagerDidRedoChange, object: nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func undoOrRedo(_ notification: Notification) {
            guard let editor, let manager = notification.object as? UndoManager,
                  manager === editor.undoManager else { return }
            parent.text = editor.string
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
