import Foundation
import CoreGraphics

public enum InlineGeometry {
    public static func documentEndCaret(raw: CGRect?, previousCharacter: CGRect?) -> CGRect? {
        // AppKit can report a zero-length end range one line above its glyphs.
        if let previousCharacter, valid(previousCharacter), previousCharacter.width > 0 {
            return CGRect(x: previousCharacter.maxX, y: previousCharacter.minY,
                          width: 0, height: previousCharacter.height)
        }
        return raw.flatMap { valid($0) ? $0 : nil }
    }

    public static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.width.isFinite && rect.height.isFinite && rect.width >= 0 && rect.height > 0
    }

    public static func fromAccessibility(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func frame(caret: CGRect, visible: CGRect, textWidth: CGFloat) -> CGRect? {
        guard !caret.isNull, !visible.isNull, caret.height > 0,
              caret.minX.isFinite, caret.minY.isFinite, textWidth.isFinite,
              caret.minY >= visible.minY, caret.maxY <= visible.maxY else { return nil }
        let x = caret.maxX + 1
        let width = min(textWidth, visible.maxX - x)
        guard x >= visible.minX, width > 12 else { return nil }
        return CGRect(x: x, y: caret.minY, width: width, height: caret.height)
    }
}
