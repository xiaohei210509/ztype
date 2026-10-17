import ApplicationServices
import Testing
@testable import ztype

struct CompatibilityDiagnosticsTests {
    @Test func reportsNeverReadDocumentContentOrIdentifiers() {
        var queried: Set<String> = []
        let element = CompatibilityDiagnostics.Element(attribute: { key in
            queried.insert(key)
            switch key {
            case kAXRoleAttribute: return "AXLayoutArea" as CFString
            case kAXSubroleAttribute: return "AXDocument" as CFString
            default: return nil
            }
        }, parameters: ["AXStringForRange", "AXStringForRange", "https://private.example/document"],
        valueSettable: true)
        #expect(element.role == "AXLayoutArea")
        #expect(element.parameters == ["AXStringForRange"])
        #expect(queried.isDisjoint(with: [
            kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXSelectedTextAttribute,
            "AXURL", "AXDocument", "AXDOMIdentifier"
        ]))
        let report = CompatibilityDiagnostics(application: "app.fixture", reason: "noCaret", focus: element, editor: nil)
        let text = report.text(version: "0.1.1", build: "2", accessibility: true,
                               inputMonitoring: true, tabStatus: "ready")
        #expect(text.contains("0.1.1"))
        #expect(text.contains("AXLayoutArea"))
        #expect(!text.contains("private.example"))
        #expect(!text.contains("AXValue"))
    }

    @Test func arbitraryRolePayloadsAreNotIncluded() {
        let element = CompatibilityDiagnostics.Element(attribute: { key in
            key == kAXRoleAttribute ? "AXRole with private document contents" as CFString : nil
        }, parameters: [], valueSettable: false)
        #expect(element.role.isEmpty)
    }
}
