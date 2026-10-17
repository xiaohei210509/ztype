import AppKit
import ApplicationServices
import Testing
@testable import ztype

struct LiveAccessibilityCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZTYPE_LIVE_AX_FIXTURE"] != nil))
    @MainActor func focusedChromeFixtureHasReadableTextAndVisibleCaret() throws {
        // Read-only fixture capture must not change the user's active input method.
        let expectedID = try #require(ProcessInfo.processInfo.environment["ZTYPE_LIVE_AX_FIXTURE"])
        let app = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first)
        let context = AccessibilityContext(isCompositionInputSource: { false }, frontmostApplication: { app })
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let focus = try #require(context.elementAttribute(application, kAXFocusedUIElementAttribute))
        try #require(context.attribute(focus, "AXDOMIdentifier") as? String == expectedID,
                     "The dedicated fixture must be focused; do not inspect another editor")
        let snapshot = context.capture()
        #expect(snapshot != nil, "Capture failed: \(String(describing: context.failure))")
        if let snapshot {
            #expect(snapshot.range.length == 0)
            #expect(snapshot.visibleBounds.contains(CGPoint(x: snapshot.caret.midX, y: snapshot.caret.midY)))
            if expectedID == "rich" {
                let reader = context.textReader(snapshot.element)
                var usedChildFallback = false
                let rangeReader = AccessibleTextReader(
                    attribute: reader.attribute,
                    parameter: { key, value in
                        guard !key.contains("TextMarker") else { return nil }
                        return reader.parameter(key, value)
                    },
                    boundsFallback: { range in
                        usedChildFallback = true
                        return reader.boundsFallback?(range)
                    }
                )
                let selection = AccessibleTextReader.Selection(range: snapshot.range, markerRange: nil)
                let recovered = try #require(rangeReader.caret(
                    selection, before: snapshot.context.before, after: snapshot.context.after,
                    start: max(0, snapshot.range.location - 1800),
                    atEnd: snapshot.range.location == reader.characterCount()
                ))
                #expect(usedChildFallback)
                #expect(recovered.minX == snapshot.caret.minX)
                #expect(recovered.minY == snapshot.caret.minY)
            }
        }
    }
}
