import AppKit
import ApplicationServices
import ztypeCore

// Marker objects stay opaque; only attributes advertised by the editor are queried.
struct AccessibleTextReader {
    let attribute: (String) -> CFTypeRef?
    let parameter: (String, CFTypeRef) -> CFTypeRef?

    struct Selection {
        let range: CFRange
        let markerRange: CFTypeRef?
    }

    func selection() -> Selection? {
        if let range = Self.range(attribute(kAXSelectedTextRangeAttribute)) {
            return Selection(range: range, markerRange: attribute("AXSelectedTextMarkerRange"))
        }
        guard let markers = attribute("AXSelectedTextMarkerRange"),
              let start = parameter("AXStartTextMarkerForTextMarkerRange", markers),
              let end = parameter("AXEndTextMarkerForTextMarkerRange", markers),
              let first = index(start), let last = index(end), last >= first else { return nil }
        return Selection(range: CFRange(location: first, length: last - first), markerRange: markers)
    }

    func characterCount() -> Int? {
        if let count = attribute(kAXNumberOfCharactersAttribute) as? NSNumber, count.intValue >= 0 {
            return count.intValue
        }
        if let end = attribute("AXEndTextMarker"), let count = index(end) { return count }
        return nil
    }

    func text(_ range: CFRange) -> String? {
        guard let value = Self.value(range) else { return nil }
        if let plain = parameter(kAXStringForRangeParameterizedAttribute, value) as? String,
           (plain as NSString).length == range.length { return plain }
        if let rich = parameter(kAXAttributedStringForRangeParameterizedAttribute, value) as? NSAttributedString,
           rich.length == range.length { return rich.string }
        if let markers = markerRange(range),
           let plain = parameter("AXStringForTextMarkerRange", markers) as? String,
           (plain as NSString).length == range.length { return plain }
        guard let count = characterCount(), count <= 16_384,
              let entire = attribute(kAXValueAttribute) as? String,
              (entire as NSString).length == count,
              range.location <= count, range.length <= count - range.location else { return nil }
        return (entire as NSString).substring(with: NSRange(location: range.location, length: range.length))
    }

    func caret(_ selection: Selection, before: String, after: String = "", start: Int, atEnd: Bool) -> CGRect? {
        let range = selection.range
        let raw = bounds(range) ?? selection.markerRange.flatMap {
            Self.rect(parameter("AXBoundsForTextMarkerRange", $0))
        }
        let trailingLTR = !before.isEmpty && before.last?.isNewline == false &&
            !before.suffix(160).unicodeScalars.contains(where: { (0x0590...0x08ff).contains($0.value) })
        if trailingLTR, atEnd || raw == nil {
            let prefix = before as NSString
            let prior = prefix.rangeOfComposedCharacterSequence(at: prefix.length - 1)
            let previous = bounds(CFRange(location: start + prior.location, length: prior.length))
            if atEnd || (raw == nil && after.first?.isNewline == true) {
                // Rich text stores can retain an implicit final paragraph terminator.
                return InlineGeometry.documentEndCaret(raw: raw, previousCharacter: previous)
            }
            // Only use the previous glyph when it is on the same line as the next glyph.
            if let previous, let next = bounds(CFRange(location: range.location, length: 1)),
               abs(previous.minY - next.minY) < min(previous.height, next.height) * 0.3 {
                return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
            }
        }
        return raw
    }

    func bounds(_ range: CFRange) -> CGRect? {
        guard let value = Self.value(range) else { return nil }
        if let rect = Self.rect(parameter(kAXBoundsForRangeParameterizedAttribute, value)) { return rect }
        if let markers = markerRange(range) {
            return Self.rect(parameter("AXBoundsForTextMarkerRange", markers))
        }
        return nil
    }

    func attributedText(_ range: CFRange) -> NSAttributedString? {
        guard let value = Self.value(range) else { return nil }
        if let result = parameter(kAXAttributedStringForRangeParameterizedAttribute, value) as? NSAttributedString {
            return result
        }
        guard let markers = markerRange(range) else { return nil }
        return parameter("AXAttributedStringForTextMarkerRange", markers) as? NSAttributedString
    }

    private func index(_ marker: CFTypeRef) -> Int? {
        let value = parameter("AXIndexForTextMarker", marker) as? NSNumber
        guard let value, value.intValue >= 0, value.intValue < Int.max else { return nil }
        return value.intValue
    }

    private func markerRange(_ range: CFRange) -> CFTypeRef? {
        guard let value = Self.value(range) else { return nil }
        if let result = parameter("AXTextMarkerRangeForNSRange", value) { return result }
        guard range.location <= Int.max - range.length,
              let start = parameter("AXTextMarkerForIndex", NSNumber(value: range.location)),
              let end = parameter("AXTextMarkerForIndex", NSNumber(value: range.location + range.length)) else {
            return nil
        }
        return parameter("AXTextMarkerRangeForTextMarkers", [start, end] as CFArray)
    }

    static func value(_ range: CFRange) -> AXValue? {
        guard range.location >= 0, range.length >= 0, range.location <= Int.max - range.length else { return nil }
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    static func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetType(value as! AXValue) == .cfRange,
              AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return range
    }

    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect),
              InlineGeometry.valid(rect) else { return nil }
        return rect
    }
}
