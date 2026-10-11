import AppKit
import SwiftUI
import ztypeCore

struct TrialEditor: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let editor = CompletionTextView()
        editor.isRichText = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.font = .systemFont(ofSize: 17)
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 20, height: 22)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = "Please let me know if you have "
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.delegate = context.coordinator
        editor.onAccept = { [weak model] full in model?.accept(full: full, global: false) ?? false }
        editor.onNativeTab = { [weak model] in model?.nativeTab() }
        editor.onInvalidate = { [weak model] in model?.invalidate() }
        editor.onDismiss = { [weak model] in model?.dismiss() }
        context.coordinator.editor = editor
        scroll.documentView = editor
        model.localCapture = { [weak editor] in
            guard let editor, editor.window?.firstResponder === editor, !editor.hasMarkedText() else { return nil }
            let range = editor.selectedRange()
            let entire = editor.string as NSString
            guard range.length == 0, range.location <= entire.length else { return nil }
            let start = max(0, range.location - 1800)
            let before = entire.substring(with: NSRange(location: start, length: range.location - start))
            let after = entire.substring(with: NSRange(location: range.location,
                                                      length: min(320, entire.length - range.location)))
            let caret = editor.firstRect(forCharacterRange: range, actualRange: nil)
            return LocalSnapshot(context: CompletionContext(before: before, after: after, application: "trial",
                                                           inputLanguage: AccessibilityContext.inputLanguage),
                                 range: range, caret: caret)
        }
        model.localInsert = { [weak editor] text, range in
            guard let editor, !editor.hasMarkedText(), editor.selectedRange() == range else { return false }
            editor.insertCompletion(text, replacementRange: range)
            return true
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        (nsView.documentView as? CompletionTextView)?.ghost = model.localSuggestion
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: AppModel
        weak var editor: CompletionTextView?
        init(model: AppModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            if editor?.isInsertingCompletion != true { model.localChanged() }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if editor?.isInsertingCompletion != true { model.localSelectionChanged() }
        }
    }
}

final class CompletionTextView: NSTextView {
    var onAccept: ((Bool) -> Bool)?
    var onNativeTab: (() -> Void)?
    var onInvalidate: (() -> Void)?
    var onDismiss: (() -> Void)?
    var ghost = "" { didSet { needsDisplay = true } }
    private(set) var isInsertingCompletion = false

    func insertCompletion(_ text: String, replacementRange: NSRange) {
        isInsertingCompletion = true
        defer { isInsertingCompletion = false }
        insertText(text, replacementRange: replacementRange)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !ghost.isEmpty, !hasMarkedText(), let window,
              window.firstResponder === self, selectedRange().length == 0 else { return }
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let caret = convert(window.convertFromScreen(screenRect), from: nil)
        let available = bounds.maxX - textContainerInset.width - caret.maxX
        guard available > 24 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let suffixExists = selectedRange().location < (string as NSString).length
        let rect = NSRect(x: caret.maxX + 2, y: caret.minY + (suffixExists ? caret.height : 0),
                          width: available, height: caret.height + 3)
        (ghost as NSString).draw(in: rect, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !hasMarkedText(), event.keyCode == 48, flags.isEmpty || flags == .option {
            if onAccept?(flags == .option) == true { return }
            if flags.isEmpty {
                onNativeTab?()
                super.keyDown(with: event)
                return
            }
        }
        if event.keyCode == 53 { onDismiss?(); return }
        onInvalidate?()
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        onInvalidate?()
        return super.resignFirstResponder()
    }
}
