import SwiftUI
import AppKit

@MainActor final class PromptEditorHandle {
    weak var textView: NSTextView?
    // Keep native text storage alive when the user visits another page; undo targets it.
    var retainedScrollView: NSScrollView?

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
    var sharedUndoManager: UndoManager? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        if let scroll = handle.retainedScrollView, let editor = scroll.documentView as? StudioTextView {
            editor.delegate = context.coordinator
            context.coordinator.editor = editor
            context.coordinator.lastSynchronizedText = text
            editor.sharedUndoManager = sharedUndoManager
            if editor.string != text { editor.breakUndoCoalescing(); editor.string = text }
            handle.textView = editor
            applyStyle(editor)
            return scroll
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let editor = StudioTextView()
        editor.sharedUndoManager = sharedUndoManager
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
        editor.textContainerInset = NSSize(width: 18, height: 16)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.drawsBackground = false
        editor.setAccessibilityIdentifier("draft-prompt-editor")
        editor.setAccessibilityLabel("创作脚本")
        editor.delegate = context.coordinator
        context.coordinator.editor = editor
        scroll.documentView = editor
        editor.string = text
        context.coordinator.lastSynchronizedText = text
        handle.textView = editor
        if sharedUndoManager != nil { handle.retainedScrollView = scroll }
        applyStyle(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        if editor.string != text && !editor.hasMarkedText() {
            editor.breakUndoCoalescing()
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            if sharedUndoManager == nil { editor.undoManager?.removeAllActions() }
        }
        context.coordinator.lastSynchronizedText = text
        applyStyle(editor)
    }

    private func applyStyle(_ editor: NSTextView) {
        editor.font = font
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(6, font.pointSize * 0.35)
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        editor.textStorage?.addAttributes([.paragraphStyle: paragraph], range: NSRange(location: 0, length: (editor.string as NSString).length))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        weak var editor: NSTextView?
        var lastSynchronizedText = ""
        private var openedTextGroup = false
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
            guard let editor, editor.delegate === self, let manager = notification.object as? UndoManager,
                  manager === editor.undoManager else { return }
            if parent.text != lastSynchronizedText {
                // A template undo restores the model before AppKit posts this notification.
                editor.breakUndoCoalescing()
                editor.string = parent.text
            } else {
                parent.text = editor.string
            }
            lastSynchronizedText = parent.text
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            lastSynchronizedText = editor.string
            if openedTextGroup {
                openedTextGroup = false
                parent.sharedUndoManager?.endUndoGrouping()
            }
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            if let manager = parent.sharedUndoManager, !manager.isUndoing, !manager.isRedoing, !openedTextGroup {
                manager.beginUndoGrouping()
                openedTextGroup = true
            }
            return true
        }
    }
}

private final class StudioTextView: NSTextView {
    var sharedUndoManager: UndoManager?
    override var undoManager: UndoManager? { sharedUndoManager ?? super.undoManager }
}
