import AppKit
import Testing
@testable import ztype

struct KeyboardEventRouterTests {
    private final class Actions: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [KeyboardEventRouter.Action] = []
        func append(_ action: KeyboardEventRouter.Action) {
            lock.lock()
            values.append(action)
            lock.unlock()
        }
        var snapshot: [KeyboardEventRouter.Action] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    @Test func claimsCandidateBeforeAnyMainActorWorkRuns() {
        let actions = Actions()
        let router = KeyboardEventRouter(ownPID: 999) { actions.append($0) }
        router.arm(pid: 123)
        #expect(router.handle(type: .keyDown, key: 48, modifiers: [], repeating: false, eventPID: 123))
        #expect(!router.acceptanceKeyReleased)
        #expect(router.handle(type: .keyDown, key: 48, modifiers: [], repeating: true, eventPID: 123))
        #expect(router.handle(type: .keyUp, key: 48, modifiers: [], repeating: false, eventPID: 123))
        #expect(router.acceptanceKeyReleased)
        #expect(actions.snapshot.count == 1)
        if case .accept(full: false, epoch: _) = actions.snapshot.first {} else { Issue.record("Expected one word acceptance") }
    }

    @Test func fullAcceptanceWaitsForOptionReleaseAsWellAsTabRelease() {
        let router = KeyboardEventRouter(ownPID: 999) { _ in }
        router.arm(pid: 123)
        #expect(router.handle(type: .keyDown, key: 48, modifiers: .maskAlternate, repeating: false, eventPID: 123))
        #expect(router.handle(type: .keyUp, key: 48, modifiers: .maskAlternate, repeating: false, eventPID: 123))
        #expect(!router.acceptanceKeyReleased)
        #expect(!router.handle(type: .flagsChanged, key: 58, modifiers: [], repeating: false, eventPID: 123))
        #expect(router.acceptanceKeyReleased)
    }

    @Test func anotherProcessAndNoCandidateKeepNativeTab() {
        let router = KeyboardEventRouter(ownPID: 999) { _ in }
        #expect(!router.handle(type: .keyDown, key: 48, modifiers: [], repeating: false, eventPID: 123))
        router.arm(pid: 123)
        #expect(!router.handle(type: .keyDown, key: 48, modifiers: [], repeating: false, eventPID: 456))
        router.arm(pid: 123)
        #expect(!router.handle(type: .keyDown, key: 48, modifiers: [], repeating: false, eventPID: 999))
    }

    @Test func aRealKeystrokeImmediatelyDisarmsTheOldCandidate() {
        let router = KeyboardEventRouter(ownPID: 999) { _ in }
        router.arm(pid: 123)
        #expect(!router.handle(type: .keyDown, key: 0, modifiers: [], repeating: false, eventPID: 123))
        #expect(!router.handle(type: .keyDown, key: 48, modifiers: [], repeating: false, eventPID: 123))
    }

    @Test func delayedMainActorAcceptanceIsRejectedAfterSubsequentInput() throws {
        let actions = Actions()
        let router = KeyboardEventRouter(ownPID: 999) { actions.append($0) }
        router.arm(pid: 123)
        #expect(router.handle(type: .keyDown, key: 48, modifiers: [], repeating: false, eventPID: 123))
        guard case .accept(_, let epoch) = try #require(actions.snapshot.first) else {
            Issue.record("Missing acceptance request")
            return
        }
        #expect(router.isCurrent(epoch))
        #expect(!router.handle(type: .keyDown, key: 0, modifiers: [], repeating: false, eventPID: 123))
        #expect(!router.isCurrent(epoch))
        router.arm(pid: 123)
        #expect(!router.isCurrent(epoch))
    }

    @Test @MainActor func eventRoutingDoesNotWaitForABusyMainActor() {
        var delivered = false
        let router = KeyboardEventRouter(ownPID: 999) { _ in
            DispatchQueue.main.async { delivered = true }
        }
        router.arm(pid: 123)
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            if router.handle(type: .keyDown, key: 48, modifiers: [], repeating: false, eventPID: 123) {
                completed.signal()
            }
        }
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(!delivered)
    }
}
