import Testing
@testable import ztype

struct AccessibleFocusResolverTests {
    @Test func ordinaryEditorsNeverRequestEnhancedAccessibility() throws {
        let resolver = AccessibleFocusResolver(
            readFocus: { 1 }, resolveEditor: { $0 },
            enableEnhancedAccessibility: { _ in
                Issue.record("An ordinary editor needs no application-wide accessibility request")
                return false
            }
        )
        let resolved = try #require(resolver.resolve())
        #expect(resolved.focus == 1)
        #expect(resolved.editor == 1)
    }

    @Test func coarseContainerRefreshesFocusAfterEnhancement() throws {
        var enhanced = false
        var reads = 0
        let resolver = AccessibleFocusResolver(
            readFocus: { reads += 1; return enhanced ? 2 : 1 },
            resolveEditor: { $0 == 2 ? 3 : nil },
            enableEnhancedAccessibility: { focus in
                #expect(focus == 1)
                enhanced = true
                return true
            }
        )
        let resolved = try #require(resolver.resolve())
        #expect(resolved.focus == 2)
        #expect(resolved.editor == 3)
        #expect(reads == 2)
    }

    @Test func failedOrUnsupportedEnhancementDoesNotPollOrSelectAnotherField() {
        for requestSucceeds in [false, true] {
            var reads = 0
            var requests = 0
            let resolver = AccessibleFocusResolver<Int>(
                readFocus: { reads += 1; return 1 }, resolveEditor: { _ in nil },
                enableEnhancedAccessibility: { _ in requests += 1; return requestSucceeds }
            )
            #expect(resolver.resolve() == nil)
            #expect(requests == 1)
            #expect(reads == (requestSucceeds ? 2 : 1))
        }
    }

    @Test func existingOrUnknownApplicationSettingsAreNeverOverwritten() {
        for value: Bool? in [true, nil] {
            #expect(!AccessibleFocusResolver<Int>.requestEnhancement(
                current: { value },
                isSettable: { Issue.record("No setter query is needed"); return true },
                enable: { Issue.record("An existing or unknown value must not be changed"); return true }
            ))
        }
    }

    @Test func onlyAnExplicitlySupportedDisabledAttributeMayBeEnabled() {
        var writes = 0
        #expect(!AccessibleFocusResolver<Int>.requestEnhancement(
            current: { false }, isSettable: { false }, enable: { writes += 1; return true }
        ))
        #expect(writes == 0)
        #expect(AccessibleFocusResolver<Int>.requestEnhancement(
            current: { false }, isSettable: { true }, enable: { writes += 1; return true }
        ))
        #expect(writes == 1)
        #expect(!AccessibleFocusResolver<Int>.requestEnhancement(
            current: { false }, isSettable: { true }, enable: { false }
        ))
    }

    @Test func missingFocusDoesNotEnableOrSearchOtherControls() {
        let resolver = AccessibleFocusResolver<Int>(
            readFocus: { nil },
            resolveEditor: { _ in Issue.record("No control was focused"); return nil },
            enableEnhancedAccessibility: { _ in Issue.record("No control was focused"); return true }
        )
        #expect(resolver.resolve() == nil)
    }

    @Test func lostFocusAfterEnhancementNeverReturnsTheOldContainer() {
        var reads = 0
        let resolver = AccessibleFocusResolver<Int>(
            readFocus: { reads += 1; return reads == 1 ? 1 : nil },
            resolveEditor: { _ in nil },
            enableEnhancedAccessibility: { _ in true }
        )
        #expect(resolver.resolve() == nil)
        #expect(reads == 2)
    }
}
