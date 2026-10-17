import AppKit
import ApplicationServices
import Testing
@testable import ztype

struct AccessibleTextReaderTests {
    private func rect(_ rect: CGRect) -> AXValue {
        var rect = rect
        return AXValueCreate(.cgRect, &rect)!
    }

    @Test func ordinaryRangesKeepTheFastPath() throws {
        var calls: [String] = []
        let reader = AccessibleTextReader(attribute: { key in
            key == kAXSelectedTextRangeAttribute ? AccessibleTextReader.value(CFRange(location: 5, length: 0)) : nil
        }, parameter: { key, _ in
            calls.append(key)
            return key == kAXStringForRangeParameterizedAttribute ? "hello" as CFString : nil
        })
        #expect(try #require(reader.selection()).range.location == 5)
        #expect(reader.text(CFRange(location: 0, length: 5)) == "hello")
        #expect(calls == [kAXStringForRangeParameterizedAttribute])
    }

    @Test func markerOnlyEditorsProvideSelectionTextCountAndBounds() throws {
        let reader = AccessibleTextReader(attribute: { key in
            switch key {
            case "AXSelectedTextMarkerRange": return "selection" as CFString
            case "AXEndTextMarker": return NSNumber(value: 5)
            default: return nil
            }
        }, parameter: { key, value in
            switch key {
            case "AXStartTextMarkerForTextMarkerRange", "AXEndTextMarkerForTextMarkerRange":
                return NSNumber(value: 5)
            case "AXIndexForTextMarker": return value
            case "AXTextMarkerForIndex": return value
            case "AXTextMarkerRangeForTextMarkers": return value
            case "AXStringForTextMarkerRange": return "hello" as CFString
            case "AXBoundsForTextMarkerRange": return rect(CGRect(x: 100, y: 200, width: 0, height: 16))
            default: return nil
            }
        })
        let selection = try #require(reader.selection())
        #expect(selection.range.location == 5)
        #expect(selection.range.length == 0)
        #expect(reader.characterCount() == 5)
        #expect(reader.text(CFRange(location: 0, length: 5)) == "hello")
        #expect(reader.bounds(CFRange(location: 5, length: 0))?.minX == 100)
    }

    @Test func attributedRangeCanSupplyPlainContext() {
        let reader = AccessibleTextReader(attribute: { _ in nil }, parameter: { key, _ in
            key == kAXAttributedStringForRangeParameterizedAttribute ? NSAttributedString(string: "hello") : nil
        })
        #expect(reader.text(CFRange(location: 0, length: 5)) == "hello")
    }

    @Test func wrongLengthContextIsNeverAccepted() {
        let reader = AccessibleTextReader(attribute: { _ in nil }, parameter: { key, _ in
            key == kAXStringForRangeParameterizedAttribute ? "entire unrelated document" as CFString : nil
        })
        #expect(reader.text(CFRange(location: 0, length: 5)) == nil)
    }

    @Test func smallValueFallbackIsBoundedAndChecksCounts() {
        let reader = AccessibleTextReader(attribute: { key in
            switch key {
            case kAXNumberOfCharactersAttribute: return NSNumber(value: 5)
            case kAXValueAttribute: return "hello" as CFString
            default: return nil
            }
        }, parameter: { _, _ in nil })
        #expect(reader.text(CFRange(location: 1, length: 3)) == "ell")
        #expect(reader.text(CFRange(location: 4, length: 2)) == nil)
    }

    @Test func largeDocumentsNeverPullEntireValue() {
        var pulledValue = false
        let reader = AccessibleTextReader(attribute: { key in
            if key == kAXValueAttribute { pulledValue = true }
            return key == kAXNumberOfCharactersAttribute ? NSNumber(value: 20_000) : nil
        }, parameter: { _, _ in nil })
        #expect(reader.text(CFRange(location: 100, length: 20)) == nil)
        #expect(!pulledValue)
    }

    @Test func missingZeroLengthBoundsRecoverUsingMarkerGlyphBounds() throws {
        let reader = AccessibleTextReader(attribute: { _ in nil }, parameter: { key, value in
            switch key {
            case "AXTextMarkerRangeForNSRange": return value
            case "AXBoundsForTextMarkerRange":
                guard let range = AccessibleTextReader.range(value), range.length == 1 else { return nil }
                return rect(CGRect(x: 130, y: 200, width: 7, height: 16))
            default: return nil
            }
        })
        let selection = AccessibleTextReader.Selection(range: CFRange(location: 5, length: 0), markerRange: nil)
        let caret = try #require(reader.caret(selection, before: "hello", start: 0, atEnd: true))
        #expect(caret == CGRect(x: 137, y: 200, width: 0, height: 16))
    }

    @Test func newlineDoesNotPlaceCaretOnPreviousLine() {
        let reader = AccessibleTextReader(attribute: { _ in nil }, parameter: { key, _ in
            key == kAXBoundsForRangeParameterizedAttribute ? rect(CGRect(x: 100, y: 200, width: 8, height: 16)) : nil
        })
        let selection = AccessibleTextReader.Selection(range: CFRange(location: 6, length: 0), markerRange: nil)
        #expect(reader.caret(selection, before: "hello\n", start: 0, atEnd: true)?.minX == 100)
    }

    @Test func implicitParagraphTerminatorAllowsLineEndRecovery() throws {
        let reader = AccessibleTextReader(attribute: { _ in nil }, parameter: { key, value in
            guard key == kAXBoundsForRangeParameterizedAttribute,
                  let range = AccessibleTextReader.range(value), range.length == 1 else { return nil }
            return rect(CGRect(x: 130, y: 200, width: 7, height: 16))
        })
        let selection = AccessibleTextReader.Selection(range: CFRange(location: 5, length: 0), markerRange: nil)
        let caret = try #require(reader.caret(selection, before: "hello", after: "\u{2029}",
                                            start: 0, atEnd: false))
        #expect(caret == CGRect(x: 137, y: 200, width: 0, height: 16))
    }

    @Test func malformedSelectionsAreRejected() {
        #expect(AccessibleTextReader.value(CFRange(location: -1, length: 0)) == nil)
        #expect(AccessibleTextReader.value(CFRange(location: Int.max, length: 1)) == nil)
        #expect(AccessibleTextReader.range("not a range" as CFString) == nil)
        #expect(AccessibleTextReader.rect(NSNumber(value: 0)) == nil)
    }

    @Test func onlyTransientLayoutFailuresAreRetried() {
        #expect(ContextCaptureFailure.noCaret.mayBeLayoutDelay)
        #expect(ContextCaptureFailure.noText.mayBeLayoutDelay)
        #expect(!ContextCaptureFailure.noPermission.mayBeLayoutDelay)
        #expect(!ContextCaptureFailure.secureField.mayBeLayoutDelay)
        #expect(!ContextCaptureFailure.selectedText.mayBeLayoutDelay)
        #expect(!ContextCaptureFailure.composition.mayBeLayoutDelay)
    }

    @Test func selectedTextRangesCanSupplyASingleCaret() throws {
        let reader = AccessibleTextReader(attribute: { key in
            key == kAXSelectedTextRangesAttribute
                ? [AccessibleTextReader.value(CFRange(location: 5, length: 0))!] as CFArray : nil
        }, parameter: { _, _ in nil })
        #expect(try #require(reader.selection()).range.location == 5)
    }

    @Test func multipleCaretsAreNotCollapsedIntoOneSelection() {
        let reader = AccessibleTextReader(attribute: { key in
            key == kAXSelectedTextRangesAttribute
                ? [AccessibleTextReader.value(CFRange(location: 5, length: 0))!,
                   AccessibleTextReader.value(CFRange(location: 8, length: 0))!] as CFArray : nil
        }, parameter: { _, _ in nil })
        #expect(reader.selection() == nil)
    }

    @Test func unorderedMarkerRangesCanProvideGlyphBounds() throws {
        let reader = AccessibleTextReader(attribute: { _ in nil }, parameter: { key, value in
            switch key {
            case "AXTextMarkerForIndex": return value
            case "AXTextMarkerRangeForUnorderedTextMarkers": return value
            case "AXBoundsForTextMarkerRange": return rect(CGRect(x: 130, y: 200, width: 7, height: 16))
            default: return nil
            }
        })
        #expect(try #require(reader.bounds(CFRange(location: 4, length: 1))).width == 7)
    }

    @Test func invalidOrdinaryCaretUsesTheSelectedMarkerRange() throws {
        let markers = "selection" as CFString
        let reader = AccessibleTextReader(attribute: { _ in nil }, parameter: { key, _ in
            switch key {
            case kAXBoundsForRangeParameterizedAttribute: return rect(.zero)
            case "AXBoundsForTextMarkerRange": return rect(CGRect(x: 130, y: 200, width: 0, height: 16))
            default: return nil
            }
        })
        let selection = AccessibleTextReader.Selection(range: CFRange(location: 5, length: 0), markerRange: markers)
        #expect(try #require(reader.caret(selection, before: "hello", start: 0, atEnd: true)).minX == 130)
    }

    @Test func childGlyphBoundsRecoverAnInvalidContainerRange() throws {
        var calls = 0
        let reader = AccessibleTextReader(attribute: { _ in nil }, parameter: { _, _ in nil },
                                          boundsFallback: { _ in
            calls += 1
            return CGRect(x: 130, y: 200, width: 7, height: 16)
        })
        let selection = AccessibleTextReader.Selection(range: CFRange(location: 5, length: 0), markerRange: nil)
        #expect(try #require(reader.caret(selection, before: "hello", start: 0, atEnd: true)).minX == 137)
        #expect(calls == 2)
    }

    @Test func validOrdinaryBoundsDoNotScanChildren() {
        let reader = AccessibleTextReader(attribute: { _ in nil }, parameter: { _, _ in
            rect(CGRect(x: 130, y: 200, width: 0, height: 16))
        }, boundsFallback: { _ in
            Issue.record("The ordinary fast path must not inspect child editors")
            return nil
        })
        #expect(reader.bounds(CFRange(location: 5, length: 0)) != nil)
    }

    @Test func childRangesUseValidatedLocalCursorOffsets() {
        let range = AccessibleTextReader.relativeRange(CFRange(location: 33, length: 1), cursor: 34, childCursor: 2)
        #expect(range?.location == 1)
        #expect(range?.length == 1)
        #expect(AccessibleTextReader.relativeRange(CFRange(location: 34, length: 0), cursor: 34, childCursor: 2)?.location == 2)
        #expect(AccessibleTextReader.relativeRange(CFRange(location: 1, length: 1), cursor: 34, childCursor: 2) == nil)
        #expect(AccessibleTextReader.relativeRange(CFRange(location: 34, length: 1), cursor: 34, childCursor: 2) == nil)
        #expect(AccessibleTextReader.relativeRange(CFRange(location: 34, length: 0), cursor: 34, childCursor: 0) == nil)
    }

    @Test func emptyContextDoesNotFetchTheEntireValue() {
        let reader = AccessibleTextReader(attribute: { _ in
            Issue.record("Empty text needs no accessibility value read")
            return nil
        }, parameter: { _, _ in
            Issue.record("Empty text needs no parameterized read")
            return nil
        })
        #expect(reader.text(CFRange(location: 0, length: 0)) == "")
    }
}
