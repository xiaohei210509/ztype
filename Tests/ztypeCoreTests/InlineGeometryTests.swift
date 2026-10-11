import Foundation
import CoreGraphics
import Testing
@testable import ztypeCore

struct InlineGeometryTests {
    @Test func nativeDocumentEndRangeAboveFirstLineUsesPreviousGlyph() throws {
        let visible = CGRect(x: 100, y: 200, width: 650, height: 400)
        let raw = CGRect(x: 217, y: 184, width: 0, height: 16)
        let previous = CGRect(x: 209, y: 200, width: 8, height: 16)
        #expect(!visible.contains(CGPoint(x: raw.midX, y: raw.midY)))
        let caret = try #require(InlineGeometry.documentEndCaret(raw: raw, previousCharacter: previous))
        #expect(caret == CGRect(x: 217, y: 200, width: 0, height: 16))
        #expect(InlineGeometry.frame(caret: caret, visible: visible, textWidth: 200) != nil)
    }

    @Test func documentEndCanRecoverMissingZeroLengthBounds() {
        let glyph = CGRect(x: 140, y: 200, width: 12, height: 18)
        #expect(InlineGeometry.documentEndCaret(raw: nil, previousCharacter: glyph) ==
                CGRect(x: 152, y: 200, width: 0, height: 18))
        #expect(InlineGeometry.documentEndCaret(raw: nil, previousCharacter: .zero) == nil)
    }

    @Test func offscreenLastGlyphDoesNotBypassClipping() throws {
        let caret = try #require(InlineGeometry.documentEndCaret(
            raw: nil, previousCharacter: CGRect(x: 200, y: 900, width: 10, height: 18)
        ))
        #expect(InlineGeometry.frame(
            caret: caret, visible: CGRect(x: 100, y: 200, width: 650, height: 400), textWidth: 200
        ) == nil)
    }

    @Test func accessibilityCoordinatesIncludeDisplaysAboveAndLeftOfPrimary() {
        #expect(InlineGeometry.fromAccessibility(
            CGRect(x: -1200, y: -200, width: 0, height: 20), primaryHeight: 900
        ) == CGRect(x: -1200, y: 1080, width: 0, height: 20))
    }

    @Test func truncatesAtFieldEdgeWithoutMovingCaretAnchor() throws {
        let caret = CGRect(x: 280, y: 100, width: 1, height: 18)
        let frame = try #require(InlineGeometry.frame(
            caret: caret, visible: CGRect(x: 100, y: 50, width: 250, height: 150), textWidth: 200
        ))
        #expect(frame == CGRect(x: 282, y: 100, width: 68, height: 18))
    }

    @Test func hiddenAndOffscreenCaretsDoNotFloatElsewhere() {
        let visible = CGRect(x: 100, y: 50, width: 250, height: 150)
        for caret in [CGRect(x: 350, y: 100, width: 0, height: 18),
                      CGRect(x: 50, y: 100, width: 0, height: 18),
                      CGRect(x: 200, y: 190, width: 0, height: 18)] {
            #expect(InlineGeometry.frame(caret: caret, visible: visible, textWidth: 200) == nil)
        }
    }
}
