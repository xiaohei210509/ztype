import ApplicationServices
import Testing
@testable import ztype

struct AccessibleFieldResolverTests {
    private func resolver(kinds: [Int: AccessibleFieldResolver<Int>.Kind], children: [Int: [Int]] = [:],
                          parents: [Int: Int] = [:], focused: Set<Int> = []) -> AccessibleFieldResolver<Int> {
        AccessibleFieldResolver(
            equal: ==, kind: { kinds[$0] ?? .container }, focused: { focused.contains($0) },
            hasSelection: { _ in true }, parent: { parents[$0] }, children: { children[$0] ?? [] }
        )
    }

    @Test func layoutEditorNeedsActualTextAndSelectionCapabilities() {
        let editor = AccessibleFieldCapabilities(
            role: "AXLayoutArea", valueSettable: true, hasSelection: true, hasTextRanges: true
        )
        #expect(editor.isEditor)
        #expect(!AccessibleFieldCapabilities(role: "AXLayoutArea", valueSettable: true).isEditor)
        #expect(!AccessibleFieldCapabilities(
            role: "AXLayoutArea", editable: false, valueSettable: true, hasSelection: true, hasTextRanges: true
        ).isEditor)
    }

    @Test func textInsertionCapabilitySupportsNonstandardEditorsWithoutValueSetter() {
        #expect(AccessibleFieldCapabilities(
            role: "AXLayoutArea", hasSelection: true, hasTextRanges: true, hasInsertionLine: true
        ).isEditor)
        #expect(!AccessibleFieldCapabilities(
            role: "AXGroup", hasSelection: true, hasTextRanges: true
        ).isEditor)
        #expect(AccessibleFieldCapabilities(
            role: "AXGroup", editable: true, hasSelection: true, hasTextRanges: true
        ).isEditor)
    }

    @Test func staticTextAndReadOnlyWebAreasAreNotWritableEditors() {
        for role in [kAXStaticTextRole, "AXWebArea", kAXButtonRole, kAXWindowRole] {
            #expect(!AccessibleFieldCapabilities(
                role: role, valueSettable: true, hasSelection: true, hasTextRanges: true, hasInsertionLine: true
            ).isEditor)
        }
    }

    @Test func anExplicitlyEditableCustomRoleKeepsItsExistingSupport() {
        #expect(AccessibleFieldCapabilities(
            role: "AXCustomEditor", editable: true, hasSelection: true, hasTextRanges: true
        ).isEditor)
        #expect(!AccessibleFieldCapabilities(
            role: "AXCustomEditor", hasSelection: true, hasTextRanges: true
        ).isEditor)
    }

    @Test func focusedLeafResolvesItsEditorBeforeExploringChildren() {
        let tree = resolver(kinds: [1: .container, 2: .editor], children: [1: Array(3...100)], parents: [1: 2])
        #expect(tree.resolve(1) == 2)
    }

    @Test func deeplyNestedFocusedEditorCanBeResolved() {
        let tree = resolver(
            kinds: [7: .editor],
            children: [1: [2], 2: [3], 3: [4], 4: [5], 5: [6], 6: [7]], focused: [7]
        )
        #expect(tree.resolve(1) == 7)
    }

    @Test func uniqueDescendantNeedsACompleteSearch() {
        var tree = resolver(kinds: [2: .editor], children: [1: [2, 3], 3: [4]])
        #expect(tree.resolve(1) == 2)
        tree.maximumNodes = 2
        #expect(tree.resolve(1) == nil)
    }

    @Test func ambiguousEditorsAreNeverGuessed() {
        let tree = resolver(kinds: [2: .editor, 3: .editor], children: [1: [2, 3]])
        #expect(tree.resolve(1) == nil)
    }

    @Test func focusWinsOverUnrelatedSiblingEditors() {
        let tree = resolver(kinds: [2: .editor, 3: .editor], children: [1: [2, 3]], focused: [3])
        #expect(tree.resolve(1) == 3)
    }

    @Test func entireWindowsAndSecureSubtreesAreNeverSearchedForEditors() {
        #expect(resolver(kinds: [1: .boundary, 2: .editor], children: [1: [2]]).resolve(1) == nil)
        #expect(resolver(kinds: [2: .secure, 3: .editor], children: [1: [2, 3]]).resolve(1) == nil)
        #expect(resolver(kinds: [1: .secure]).resolve(1) == 1)
    }

    @Test func secureAndReadOnlyAncestorsBlockLeafResolution() {
        #expect(resolver(kinds: [2: .secure], parents: [1: 2]).resolve(1) == 2)
        #expect(resolver(kinds: [2: .blocked, 3: .editor], parents: [1: 2, 2: 3]).resolve(1) == nil)
    }

    @Test func cyclesAndDepthLimitsCannotEstablishUniqueness() {
        #expect(resolver(kinds: [:], children: [1: [1]], parents: [1: 1]).resolve(1) == nil)
        var tree = resolver(kinds: [2: .editor], children: [1: [2, 3], 3: [4], 4: [5]])
        tree.maximumDepth = 1
        #expect(tree.resolve(1) == nil)
    }

    @Test func expiredBudgetCannotPickTheOnlyEditorSeenSoFar() {
        var calls = 0
        var tree = resolver(kinds: [2: .editor], children: [1: [2, 3]])
        tree.withinBudget = { calls += 1; return calls < 4 }
        #expect(tree.resolve(1) == nil)
    }
}
