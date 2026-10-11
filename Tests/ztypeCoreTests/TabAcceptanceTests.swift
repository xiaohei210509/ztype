import CoreGraphics
import Testing
@testable import ztype

struct TabAcceptanceTests {
    @Test func candidateClaimsBothDownAndUp() {
        var gate = TabAcceptanceGate()
        var attempts = 0
        let down = gate.consume(type: .keyDown, key: 48, modifiers: [], repeating: false, accept: {
            attempts += 1
            return true
        })
        let up = gate.consume(type: .keyUp, key: 48, modifiers: [], repeating: false, accept: { false })
        #expect(down && up)
        #expect(attempts == 1)
    }

    @Test func heldTabCannotInsertMultipleTimesOrLeakTabs() {
        var gate = TabAcceptanceGate()
        var attempts = 0
        let accept = { attempts += 1; return true }
        let down = gate.consume(type: .keyDown, key: 48, modifiers: [], repeating: false, accept: accept)
        #expect(down)
        for _ in 0..<5 {
            let repeated = gate.consume(type: .keyDown, key: 48, modifiers: [], repeating: true, accept: accept)
            #expect(repeated)
        }
        #expect(attempts == 1)
        let up = gate.consume(type: .keyUp, key: 48, modifiers: [], repeating: false, accept: { false })
        #expect(up)
    }

    @Test func noCandidatePreservesNativeTab() {
        var gate = TabAcceptanceGate()
        let down = gate.consume(type: .keyDown, key: 48, modifiers: [], repeating: false, accept: { false })
        let up = gate.consume(type: .keyUp, key: 48, modifiers: [], repeating: false, accept: { false })
        #expect(!down && !up)
    }

    @Test func fullAcceptanceUsesOptionButShiftTabIsNotClaimed() {
        var gate = TabAcceptanceGate()
        let shift = gate.consume(type: .keyDown, key: 48, modifiers: .maskShift, repeating: false, accept: {
            Issue.record("Shift+Tab must not attempt completion")
            return true
        })
        let option = gate.consume(type: .keyDown, key: 48, modifiers: .maskAlternate, repeating: false, accept: { true })
        let up = gate.consume(type: .keyUp, key: 48, modifiers: [], repeating: false, accept: { false })
        #expect(!shift && option && up)
    }

    @Test func repeatsCannotStartAcceptingANewCandidate() {
        var gate = TabAcceptanceGate()
        let repeated = gate.consume(type: .keyDown, key: 48, modifiers: [], repeating: true, accept: {
            Issue.record("A repeated native Tab must not start an acceptance")
            return true
        })
        #expect(!repeated)
    }
}
