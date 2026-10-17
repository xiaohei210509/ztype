import AppKit
import ApplicationServices
import Testing
@testable import ztype

@MainActor
struct LivePagesAccessibilityCaptureTests {
    private func fixture() throws -> (AccessibilityContext, AXUIElement) {
        let path = try #require(ProcessInfo.processInfo.environment["ZTYPE_LIVE_PAGES_FIXTURE"])
        let app = try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Pages").first ??
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iWork.Pages").first
        )
        let context = AccessibilityContext(isCompositionInputSource: { false }, frontmostApplication: { app })
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let focus = try #require(context.elementAttribute(application, kAXFocusedUIElementAttribute))
        let window = try #require(context.elementAttribute(focus, kAXWindowAttribute))
        let expectedTitle = URL(fileURLWithPath: path).lastPathComponent
        try #require(context.attribute(window, kAXTitleAttribute) as? String == expectedTitle,
                     "Only the explicitly named, independent Pages fixture may be inspected")
        return (context, focus)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZTYPE_LIVE_PAGES_FIXTURE"] != nil))
    func focusedFixtureHasReadableTextAndVisibleCaret() throws {
        let (context, _) = try fixture()
        let snapshot = try #require(context.capture(),
                                    "Capture failed: \(String(describing: context.failure))")
        #expect(snapshot.range.length == 0)
        #expect(snapshot.context.before.hasPrefix("ztype compatibility fixture"))
        #expect(snapshot.visibleBounds.contains(CGPoint(x: snapshot.caret.midX, y: snapshot.caret.midY)))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZTYPE_LIVE_PAGES_FIXTURE"] != nil))
    func pageAndDocumentFocusResolveTheActiveBody() throws {
        let (context, focus) = try fixture()
        try #require(context.attribute(focus, kAXRoleAttribute) as? String == kAXTextAreaRole)
        var ancestor = focus
        var testedRoles: Set<String> = []
        for _ in 0..<8 {
            guard let parent = context.elementAttribute(ancestor, kAXParentAttribute) else { break }
            ancestor = parent
            let role = context.attribute(parent, kAXRoleAttribute) as? String ?? ""
            if ["AXPage", "AXLayoutArea", kAXScrollAreaRole].contains(role) {
                testedRoles.insert(role)
                let resolved = try #require(context.resolveField(parent), "Cannot resolve focused \(role)")
                #expect(CFEqual(resolved, focus), "Resolved an unrelated header or footer")
            }
            if role == kAXWindowRole { break }
        }
        #expect(testedRoles == ["AXPage", "AXLayoutArea", kAXScrollAreaRole])
    }
}
