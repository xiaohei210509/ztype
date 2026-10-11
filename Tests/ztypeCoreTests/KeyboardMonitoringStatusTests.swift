import CoreGraphics
import Testing
@testable import ztype

struct KeyboardMonitoringStatusTests {
    private func tap(mask: CGEventMask, pid: pid_t = 123, enabled: Bool = true,
                     options: CGEventTapOptions = .defaultTap) -> CGEventTapInformation {
        var result = CGEventTapInformation()
        result.tappingProcess = pid
        result.tapPoint = .cgSessionEventTap
        result.options = options
        result.eventsOfInterest = mask
        result.enabled = enabled
        return result
    }

    @Test func rejectsTheActualPermissionStrippedMaskEvenWhenTapIsEnabled() {
        #expect(KeyboardMonitoringStatus.requiredMask == 4_201_482)
        #expect(KeyboardMonitoringStatus.evaluate([tap(mask: 4_198_410)], pid: 123) == .incomplete)
    }

    @Test func requiresBothKeyboardPhasesAndModifierRelease() {
        for event in [CGEventType.keyDown, .keyUp, .flagsChanged] {
            let mask = KeyboardMonitoringStatus.requiredMask & ~(CGEventMask(1) << event.rawValue)
            #expect(KeyboardMonitoringStatus.evaluate([tap(mask: mask)], pid: 123) == .incomplete)
        }
    }

    @Test func aDisabledTapIsNotReady() {
        #expect(KeyboardMonitoringStatus.evaluate(
            [tap(mask: KeyboardMonitoringStatus.requiredMask, enabled: false)], pid: 123) == .unavailable)
    }

    @Test func anotherProcessOrListenOnlyTapCannotProveTabSuppression() {
        let mask = KeyboardMonitoringStatus.requiredMask
        #expect(KeyboardMonitoringStatus.evaluate([tap(mask: mask, pid: 456)], pid: 123) == .inactive)
        #expect(KeyboardMonitoringStatus.evaluate([tap(mask: mask, options: .listenOnly)], pid: 123) == .inactive)
    }

    @Test func aCompleteActiveOwnedTapIsReady() {
        #expect(KeyboardMonitoringStatus.evaluate(
            [tap(mask: KeyboardMonitoringStatus.requiredMask)], pid: 123) == .ready)
    }
}
