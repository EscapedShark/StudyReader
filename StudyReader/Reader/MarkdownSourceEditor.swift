import SwiftUI

// Markdown needs literal punctuation: smart quotes/dashes would silently change code and LaTeX.
#if os(macOS)
struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 16, height: 16)
        editor.string = text
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Markdown 原文")
        editor.setAccessibilityIdentifier("markdown-source")
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        editor.isEditable = isEditable
        if editor.string != text { editor.string = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownSourceEditor
        init(_ parent: MarkdownSourceEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}
#else
struct MarkdownSourceEditor: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    func makeUIView(context: Context) -> UITextView {
        let editor = UITextView()
        editor.font = UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 16, weight: .regular))
        editor.adjustsFontForContentSizeCategory = true
        editor.textColor = .label
        editor.backgroundColor = .systemBackground
        editor.autocapitalizationType = .none
        editor.autocorrectionType = .no
        editor.spellCheckingType = .no
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.smartInsertDeleteType = .no
        editor.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        editor.text = text
        editor.delegate = context.coordinator
        editor.accessibilityLabel = "Markdown 原文"
        editor.accessibilityIdentifier = "markdown-source"
        return editor
    }
    func updateUIView(_ editor: UITextView, context: Context) {
        context.coordinator.parent = self
        editor.isEditable = isEditable
        if editor.text != text { editor.text = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownSourceEditor
        init(_ parent: MarkdownSourceEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
#endif
