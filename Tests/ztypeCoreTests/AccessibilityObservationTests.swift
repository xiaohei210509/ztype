import ApplicationServices
import Testing
@testable import ztype

struct AccessibilityNotificationLedgerTests {
    @Test func transientErrorsRetryButSuccessfulRegistrationsDoNotDuplicate() {
        var ledger = AccessibilityNotificationLedger<Int>(equal: ==)
        var adds = 0
        #expect(ledger.register("value", on: 1) { adds += 1; return .cannotComplete } == .retry)
        #expect(ledger.register("value", on: 1) { adds += 1; return .success } == .registered)
        #expect(ledger.register("value", on: 1) { adds += 1; return .success } == .registered)
        #expect(adds == 2)
    }

    @Test func unsupportedNotificationsAreNotRetriedOrRemoved() {
        var ledger = AccessibilityNotificationLedger<Int>(equal: ==)
        var adds = 0
        for _ in 0..<10 {
            #expect(ledger.register("value", on: 1) {
                adds += 1
                return .notificationUnsupported
            } == .unsupported)
        }
        #expect(adds == 1)
        ledger.remove { _, _ in Issue.record("An unsupported notification was never registered") }
        #expect(ledger.register("value", on: 1) { .success } == .registered)
    }

    @Test func changingFieldsRemovesOnlyTheirOwnedNotifications() {
        var ledger = AccessibilityNotificationLedger<Int>(equal: ==)
        _ = ledger.register("focus", on: 1) { .success }
        _ = ledger.register("value", on: 2) { .notificationAlreadyRegistered }
        _ = ledger.register("selection", on: 2) { .success }
        var removed: [String] = []
        ledger.remove(from: 2) { element, name in
            #expect(element == 2)
            removed.append(name)
        }
        #expect(Set(removed) == ["value", "selection"])
        ledger.remove { element, name in
            #expect(element == 1)
            #expect(name == "focus")
        }
    }
}

@MainActor
struct AccessibilityObservationRecoveryTests {
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Observation recovery did not reach the expected state")
    }

    @Test func recoveryStopsAsSoonAsObservationIsReady() async throws {
        let recovery = AccessibilityObservationRecovery(delays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
        defer { recovery.cancel() }
        var attempts = 0
        recovery.request(isCurrent: { true }, repair: { attempts += 1; return attempts == 2 })
        try await waitUntil { attempts == 2 }
        try await settle()
        #expect(attempts == 2)
    }

    @Test func failedObservationDoesNotPollAfterItsBoundedWindow() async throws {
        let recovery = AccessibilityObservationRecovery(delays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
        defer { recovery.cancel() }
        var attempts = 0
        for _ in 0..<20 {
            recovery.request(isCurrent: { true }, repair: { attempts += 1; return false })
        }
        try await waitUntil { attempts == 3 }
        #expect(attempts == 3)
        try await settle()
        #expect(attempts == 3)
        recovery.request(isCurrent: { true }, repair: { attempts += 1; return true })
        try await waitUntil { attempts == 4 }
        #expect(attempts == 4)
    }

    @Test func applicationChangeOrShutdownCancelsRecovery() async throws {
        let recovery = AccessibilityObservationRecovery(delays: [.milliseconds(1)])
        var current = true
        var attempts = 0
        recovery.request(isCurrent: { current }, repair: { attempts += 1; return false })
        current = false
        try await settle()
        #expect(attempts == 0)
        recovery.request(isCurrent: { true }, repair: { attempts += 1; return false })
        recovery.cancel()
        try await settle()
        #expect(attempts == 0)
    }

    @Test func anOldCancelledTaskCannotClearTheReplacementTask() async throws {
        let recovery = AccessibilityObservationRecovery(delays: [.milliseconds(5)])
        defer { recovery.cancel() }
        var attempts = 0
        recovery.request(isCurrent: { true }, repair: { Issue.record("Cancelled repair ran"); return true })
        recovery.cancel()
        recovery.request(isCurrent: { true }, repair: { attempts += 1; return false })
        await Task.yield()
        recovery.request(isCurrent: { true }, repair: { Issue.record("Duplicate recovery ran"); return true })
        try await waitUntil { attempts == 1 }
        try await settle()
        #expect(attempts == 1)
    }
}
