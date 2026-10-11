import AppKit
import Testing
@testable import ztype

struct TextInsertionTests {
    @Test func sentEventIsNotYetAConfirmedInsertion() {
        #expect(TextInsertion.confirm(before: "hello ", after: "", location: 6, text: "world",
                                      currentBefore: "hello ", currentAfter: "", currentLocation: 6,
                                      currentSelectionLength: 0) == .unchanged)
    }

    @Test func confirmationUsesUTF16AndPreservesSuffix() {
        #expect(TextInsertion.confirm(before: "hello ", after: ".", location: 6, text: "🙂",
                                      currentBefore: "hello 🙂", currentAfter: ".", currentLocation: 8,
                                      currentSelectionLength: 0) == .confirmed)
        #expect(TextInsertion.confirm(before: "hello ", after: ".", location: 6, text: "world",
                                      currentBefore: "hello world", currentAfter: "!", currentLocation: 11,
                                      currentSelectionLength: 0) == .diverged)
    }

    @Test func contextWindowSlidesAtItsUTF16Limit() {
        let before = String(repeating: "x", count: 1800)
        let expected = String(repeating: "x", count: 1795) + "world"
        #expect(TextInsertion.confirm(before: before, after: "", location: 3000, text: "world",
                                      currentBefore: expected, currentAfter: "", currentLocation: 3005,
                                      currentSelectionLength: 0) == .confirmed)
    }

    @Test func movedCursorOrSelectionDoesNotCountAsAccepted() {
        #expect(TextInsertion.confirm(before: "hello ", after: "", location: 6, text: "world",
                                      currentBefore: "hello world", currentAfter: "", currentLocation: 6,
                                      currentSelectionLength: 0) == .diverged)
        #expect(TextInsertion.confirm(before: "hello ", after: "", location: 6, text: "world",
                                      currentBefore: "hello world", currentAfter: "", currentLocation: 11,
                                      currentSelectionLength: 5) == .diverged)
    }
}
