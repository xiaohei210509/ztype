import AppKit
import ApplicationServices

struct CompatibilityDiagnostics: Codable, Equatable {
    struct Element: Codable, Equatable {
        let role: String
        let subrole: String
        let editable: Bool?
        let valueSettable: Bool
        let hasSelectionRange: Bool
        let hasSelectionMarkers: Bool
        let hasCharacterCount: Bool
        let parameters: [String]

        init(attribute: (String) -> CFTypeRef?, parameters: [String], valueSettable: Bool) {
            role = Self.identifier(attribute(kAXRoleAttribute) as? String ?? "")
            subrole = Self.identifier(attribute(kAXSubroleAttribute) as? String ?? "")
            editable = attribute("AXEditable") as? Bool
            self.valueSettable = valueSettable
            hasSelectionRange = attribute(kAXSelectedTextRangeAttribute) != nil ||
                attribute(kAXSelectedTextRangesAttribute) != nil
            hasSelectionMarkers = attribute("AXSelectedTextMarkerRange") != nil
            hasCharacterCount = attribute(kAXNumberOfCharactersAttribute) != nil
            self.parameters = Array(Set(parameters.map(Self.identifier).filter { !$0.isEmpty })).sorted()
        }

        private static func identifier(_ value: String) -> String {
            guard value.hasPrefix("AX"), value.utf8.count <= 96,
                  value.unicodeScalars.allSatisfy({
                      (65...90).contains($0.value) || (97...122).contains($0.value) ||
                      (48...57).contains($0.value) || $0.value == 95
                  }) else { return "" }
            return value
        }
    }

    let application: String
    let reason: String
    let focus: Element?
    let editor: Element?

    func text(version: String, build: String, accessibility: Bool, inputMonitoring: Bool, tabStatus: String) -> String {
        struct Report: Encodable {
            let version: String
            let build: String
            let system: String
            let accessibility: Bool
            let inputMonitoring: Bool
            let tabStatus: String
            let capture: CompatibilityDiagnostics
        }
        let report = Report(version: version, build: build, system: ProcessInfo.processInfo.operatingSystemVersionString,
                            accessibility: accessibility, inputMonitoring: inputMonitoring,
                            tabStatus: tabStatus, capture: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
