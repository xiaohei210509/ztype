import AppKit
import Testing
@testable import ztypeCore

struct NativeCaretTests {
    @Test @MainActor func appKitEndRangeKeepsSuggestionOnVisibleTextLine() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 650, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: 400))
        let text = NSTextView(frame: scroll.bounds)
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.string = "hi today is a "
        scroll.documentView = text
        window.contentView = scroll
        let length = (text.string as NSString).length
        let raw = text.accessibilityFrame(for: NSRange(location: length, length: 0))
        let glyph = text.accessibilityFrame(for: NSRange(location: length - 1, length: 1))
        let caret = try #require(InlineGeometry.documentEndCaret(raw: raw, previousCharacter: glyph))
        #expect(caret.minY == glyph.minY)
        #expect(caret.maxX == glyph.maxX)
        #expect(InlineGeometry.frame(
            caret: caret, visible: scroll.accessibilityFrame(), textWidth: 200
        ) != nil)
        #expect(text.string == "hi today is a ")
    }
}
