import AppKit
import ztypeCore

@MainActor
final class SuggestionPanel {
    private let panel: NSPanel
    private let text = InlineTextView()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = text
    }

    @discardableResult
    func show(_ suggestion: String, field: FieldSnapshot) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let caret = InlineGeometry.fromAccessibility(field.caret, primaryHeight: primaryHeight)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: caret.midX, y: caret.midY)) }),
              // Drawing over an existing suffix would conceal the user's text.
              field.context.after.prefix(while: { $0 != "\n" }).trimmingCharacters(in: .whitespaces).isEmpty else {
            hide()
            return false
        }
        let fieldBounds = InlineGeometry.fromAccessibility(field.visibleBounds, primaryHeight: primaryHeight)
        let visible = screen.visibleFrame.intersection(fieldBounds)
        let width = ceil((suggestion as NSString).size(withAttributes: [.font: field.font]).width) + 2
        guard let frame = InlineGeometry.frame(caret: caret, visible: visible, textWidth: width) else {
            hide()
            return false
        }
        text.font = field.font
        text.suggestion = suggestion
        panel.setFrame(frame, display: false)
        text.needsDisplay = true
        panel.orderFrontRegardless()
        return true
    }

    func hide() { panel.orderOut(nil) }
}

private final class InlineTextView: NSView {
    var font = NSFont.systemFont(ofSize: 14)
    var suggestion = ""
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (suggestion as NSString).draw(in: bounds, withAttributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
    }
}
