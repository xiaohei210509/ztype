import AppKit
import ApplicationServices
import Testing
import ztypeCore
@testable import ztype

@MainActor
struct GlobalAcceptanceTests {
    private func state(_ before: String, location: Int) -> TextFieldSnapshot {
        let element = AXUIElementCreateApplication(12345)
        return TextFieldSnapshot(element: element, pid: 12345, range: CFRange(location: location, length: 0),
                                 context: CompletionContext(before: before), focus: element)
    }

    private func candidate(_ state: TextFieldSnapshot) -> FieldSnapshot {
        FieldSnapshot(textState: state, caret: CGRect(x: 100, y: 100, width: 0, height: 16),
                      visibleBounds: CGRect(x: 0, y: 0, width: 600, height: 400), font: .systemFont(ofSize: 13))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Acceptance did not finish within the test deadline")
    }

    @Test func chineseTabsKeepTheOriginalRemainderAndUTF16Receipts() async throws {
        var current = state("明天我们会", location: 5)
        var parts: [String] = []
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { text, expected in
                #expect(expected.matches(current))
                parts.append(text)
                current = state(current.context.before + text,
                                location: current.range.location + (text as NSString).length)
                return TextSubmission()
            }, captureField: { candidate(current) }))
        defer { model.shutdown() }
        model.globalEnabled = true
        let original = "制定解决方案，然后再讨论。"
        model.recordGlobalCandidate(original, field: candidate(current))
        for index in 1...40 {
            #expect(model.accept(full: false, global: true))
            try await waitUntil {
                model.accepted == index && ["已接受", "候选可用"].contains(model.status)
            }
            #expect(model.predictionScheduleCount == 0)
            if model.suggestion.isEmpty { break }
        }
        #expect(model.suggestion.isEmpty)
        #expect(parts.count > 2)
        #expect(parts.joined() == original)
        #expect(current.context.before == "明天我们会" + original)
    }

    @Test func aTapWithoutKeyboardEventsCannotPublishAGhostOrClaimAcceptance() {
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { nil }, submit: { _, _ in
                Issue.record("An unhealthy keyboard tap must not submit text")
                return TextSubmission()
            }, keyboardReady: { false }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(state("hello ", location: 6)))
        #expect(model.suggestion.isEmpty)
        #expect(!model.globalEnabled)
        #expect(!model.accept(full: false, global: true))
    }

    @Test func losingKeyboardAccessAfterPublicationCancelsTheCandidate() {
        var ready = true
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { nil }, submit: { _, _ in nil }, keyboardReady: { ready }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(state("hello ", location: 6)))
        ready = false
        #expect(!model.accept(full: false, global: true))
        #expect(model.suggestion.isEmpty)
        #expect(!model.globalEnabled)
    }

    @Test func losingKeyboardAccessWhileWaitingForTabReleaseCancelsTheQueuedWrite() async throws {
        var ready = true
        var released = false
        var writes = 0
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { nil }, submit: { _, _ in writes += 1; return TextSubmission() },
            keyReleased: { released }, keyboardReady: { ready }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(state("hello ", location: 6)))
        #expect(model.accept(full: false, global: true))
        ready = false
        released = true
        try await waitUntil { !model.globalEnabled }
        #expect(writes == 0)
        #expect(model.accepted == 0)
        #expect(model.suggestion.isEmpty)
    }

    @Test func reservationDoesNotReadAXOrWriteInsideTheKeyCallback() async throws {
        let prior = state("hello ", location: 6)
        var reads = 0
        var writes = 0
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 }, captureText: {
            reads += 1
            return state("hello world", location: 11)
        }, submit: { text, _ in writes += 1; #expect(text == "world"); return TextSubmission() }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(prior))
        #expect(model.accept(full: false, global: true))
        #expect(reads == 0)
        #expect(writes == 0)
        #expect(model.accepted == 0)
        try await waitUntil { model.accepted == 1 }
        #expect(writes == 1)
    }

    @Test func repeatedPressesDuringPendingInsertionDoNotSendAgain() async throws {
        let prior = state("hello ", location: 6)
        var writes = 0
        var reads = 0
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 }, captureText: {
            reads += 1
            return reads < 3 ? prior : state("hello world", location: 11)
        }, submit: { _, _ in writes += 1; return TextSubmission() }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(prior))
        #expect(model.accept(full: false, global: true))
        #expect(model.accept(full: false, global: true))
        #expect(model.accept(full: false, global: true))
        try await waitUntil { model.accepted == 1 }
        #expect(writes == 1)
    }

    @Test func inputInvalidationCancelsAQueuedWrite() async throws {
        var writes = 0
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
                                                            captureText: { nil },
                                                            submit: { _, _ in writes += 1; return TextSubmission() }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(state("hello ", location: 6)))
        #expect(model.accept(full: false, global: true))
        model.invalidate()
        try await Task.sleep(for: .milliseconds(30))
        #expect(writes == 0)
        #expect(model.accepted == 0)
    }

    @Test func rejectedWriteStillClaimsTheAcceptanceTabButIsNotCounted() async throws {
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
                                                            captureText: { nil }, submit: { _, _ in nil }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(state("hello ", location: 6)))
        #expect(model.accept(full: false, global: true))
        try await waitUntil { model.status.hasPrefix("未能完成") }
        #expect(model.accepted == 0)
        #expect(model.suggestion.isEmpty)
    }

    @Test func wrongForegroundAppDoesNotClaimTab() {
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 56789 },
                                                            captureText: { nil }, submit: { _, _ in
            Issue.record("Must not write into a background application")
            return TextSubmission()
        }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(state("hello ", location: 6)))
        #expect(!model.accept(full: false, global: true))
    }

    @Test func delayedAXEchoDoesNotEraseAnUnchangedCandidate() async throws {
        let prior = state("hello ", location: 6)
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
                                                            captureText: { prior }, submit: { _, _ in nil }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(prior))
        model.globalTextChanged()
        model.globalTextChanged()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.suggestion == "world")
        #expect(model.status == "候选可用")
    }

    @Test func realProgrammaticTextChangeInvalidatesCandidate() async throws {
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 }, captureText: {
            state("hello changed ", location: 14)
        }, submit: { _, _ in nil }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(state("hello ", location: 6)))
        model.globalTextChanged()
        try await waitUntil { model.suggestion.isEmpty }
        #expect(model.suggestion.isEmpty)
        #expect(model.accepted == 0)
    }

    @Test func insertionWaitsForTheAcceptanceKeyToBeReleased() async throws {
        var released = false
        var writes = 0
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 }, captureText: {
            state("hello world", location: 11)
        }, submit: { _, _ in writes += 1; return TextSubmission() }, keyReleased: { released }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(state("hello ", location: 6)))
        #expect(model.accept(full: false, global: true))
        try await Task.sleep(for: .milliseconds(40))
        #expect(writes == 0)
        released = true
        try await waitUntil { model.accepted == 1 }
        #expect(writes == 1)
    }

    @Test func rapidSeparateTabPressesAcceptSuccessiveWordsInsteadOfBeingLost() async throws {
        let draft = "Hi today is a very be"
        var current = state(draft, location: (draft as NSString).length)
        var parts: [String] = []
        var finished: [Bool] = []
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { text, expected in
                #expect(expected.matches(current))
                parts.append(text)
                current = state(current.context.before + text, location: current.range.location + (text as NSString).length)
                return TextSubmission { finished.append($0) }
            }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("autiful day.", field: candidate(current))
        #expect(model.accept(full: false, global: true))
        #expect(model.accept(full: false, global: true))
        try await waitUntil { model.accepted == 2 }
        #expect(parts == ["autiful", " day."])
        #expect(current.context.before == "Hi today is a very beautiful day.")
        #expect(finished == [true, true])
        #expect(!current.context.before.contains("\t"))
    }

    @Test func fullAcceptanceQueuedBehindAWordConsumesOnlyTheRemainder() async throws {
        var current = state("hello ", location: 6)
        var parts: [String] = []
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { text, _ in
                parts.append(text)
                current = state(current.context.before + text, location: current.range.location + (text as NSString).length)
                return TextSubmission()
            }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world and everyone.", field: candidate(current))
        #expect(model.accept(full: false, global: true))
        #expect(model.accept(full: true, global: true))
        try await waitUntil { model.accepted == 2 }
        #expect(parts == ["world", " and everyone."])
    }

    @Test func temporaryLayoutFailureDoesNotLoseTheRemainingCandidate() async throws {
        let prior = state("hello ", location: 6)
        let current = state("hello world", location: 11)
        var layoutReads = 0
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { _, _ in TextSubmission() }, captureField: {
                layoutReads += 1
                return layoutReads < 3 ? nil : candidate(current)
            }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world again", field: candidate(prior))
        #expect(model.accept(full: false, global: true))
        try await waitUntil { model.suggestion == " again" && model.status == "候选可用" }
        #expect(model.accepted == 1)
        #expect(layoutReads == 3)
    }

    @Test func missingRemainderLayoutStillAllowsTheNextTabToConsumeTheOriginalWords() async throws {
        var current = state("hello ", location: 6)
        var parts: [String] = []
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { text, expected in
                #expect(expected.matches(current))
                parts.append(text)
                current = state(current.context.before + text,
                                location: current.range.location + (text as NSString).length)
                return TextSubmission()
            }, captureField: { nil }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world and everyone.", field: candidate(current))
        #expect(model.accept(full: false, global: true))
        try await waitUntil { model.accepted == 1 }
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.suggestion == " and everyone.")
        #expect(model.accept(full: false, global: true))
        try await waitUntil { model.accepted == 2 }
        #expect(parts == ["world", " and"])
        #expect(current.context.before == "hello world and")
        #expect(model.predictionScheduleCount == 0)
    }

    @Test func anUnreadableDelayedAXEchoDoesNotReplaceTheRetainedCandidate() async throws {
        var current = state("hello ", location: 6)
        var readable = true
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { readable ? current : nil }, submit: { text, _ in
                current = state(current.context.before + text,
                                location: current.range.location + (text as NSString).length)
                return TextSubmission()
            }, captureField: { candidate(current) }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world and everyone.", field: candidate(current))
        #expect(model.accept(full: false, global: true))
        try await waitUntil { model.suggestion == " and everyone." && model.status == "候选可用" }
        readable = false
        model.globalTextChanged()
        try await Task.sleep(for: .milliseconds(350))
        #expect(model.suggestion == " and everyone.")
        readable = true
        #expect(model.accept(full: false, global: true))
        try await waitUntil { model.accepted == 2 }
        #expect(current.context.before == "hello world and")
        #expect(model.predictionScheduleCount == 0)
    }

    @Test func separateTabsConsumeOneFiveWordCandidateAndStopUntilTheUserEdits() async throws {
        var current = state("hello ", location: 6)
        var parts: [String] = []
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { text, expected in
                #expect(expected.matches(current))
                parts.append(text)
                current = state(current.context.before + text,
                                location: current.range.location + (text as NSString).length)
                return TextSubmission()
            }, captureField: { candidate(current) }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("one two three four five.", field: candidate(current))
        for (index, expected) in ["one", " two", " three", " four", " five."].enumerated() {
            #expect(model.accept(full: false, global: true))
            try await waitUntil {
                model.accepted == index + 1 && model.status == (index == 4 ? "已接受" : "候选可用")
            }
            #expect(parts.last == expected)
            #expect(model.predictionScheduleCount == 0)
        }
        #expect(current.context.before == "hello one two three four five.")
        #expect(model.suggestion.isEmpty)
        model.globalTextChanged()
        model.schedule(global: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.predictionScheduleCount == 0)
        current = state(current.context.before + " New", location: current.range.location + 4)
        model.globalTextChanged()
        try await waitUntil { model.predictionScheduleCount == 1 }
        #expect(model.suggestion.isEmpty)
    }

    @Test func layoutRecoveryRedisplaysTheCachedRemainderInsteadOfRequestingPrediction() async throws {
        var current = state("hello ", location: 6)
        var layoutAvailable = false
        var displayed: [String] = []
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { text, _ in
                current = state(current.context.before + text,
                                location: current.range.location + (text as NSString).length)
                return TextSubmission()
            }, captureField: { layoutAvailable ? candidate(current) : nil }, presentCandidate: { text, _ in
                displayed.append(text)
                return true
            }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world and everyone.", field: candidate(current))
        #expect(model.accept(full: false, global: true))
        try await waitUntil { model.status == "候选已保留 · 等待行内位置" }
        layoutAvailable = true
        model.globalTextChanged()
        try await waitUntil { !displayed.isEmpty }
        #expect(displayed == [" and everyone."])
        #expect(model.suggestion == " and everyone.")
        #expect(model.predictionScheduleCount == 0)
    }

    @Test func anEditorFocusEchoDuringPasteDoesNotCancelTheCompletionSession() async throws {
        var current = state("hello ", location: 6)
        weak var receiver: AppModel?
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { text, _ in
                current = state(current.context.before + text,
                                location: current.range.location + (text as NSString).length)
                receiver?.globalTextChanged()
                return TextSubmission()
            }, captureField: { candidate(current) }))
        receiver = model
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world and everyone.", field: candidate(current))
        #expect(model.accept(full: false, global: true))
        try await waitUntil { model.suggestion == " and everyone." && model.status == "候选可用" }
        #expect(model.accepted == 1)
        #expect(model.predictionScheduleCount == 0)
    }

    @Test func nativeTabIndentationDoesNotTriggerPredictionUntilANonTabEdit() async throws {
        var current = state("hello ", location: 6)
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { _, _ in nil }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.nativeTab()
        current = state("hello \t", location: 7)
        model.globalTextChanged()
        model.schedule(global: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.predictionScheduleCount == 0)
        model.invalidate()
        model.schedule(global: true)
        #expect(model.predictionScheduleCount == 1)
    }

    @Test func aRealFocusChangeDiscardsCachedWordsWithoutWritingIntoTheNewField() async throws {
        var current = state("hello ", location: 6)
        var writes = 0
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { _, _ in writes += 1; return TextSubmission() }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world and everyone.", field: candidate(current))
        let other = AXUIElementCreateApplication(54321)
        current = TextFieldSnapshot(element: other, pid: 12345, range: current.range,
                                    context: current.context, focus: other)
        model.globalTextChanged()
        try await waitUntil { model.suggestion.isEmpty }
        #expect(!model.accept(full: false, global: true))
        #expect(writes == 0)
        #expect(model.predictionScheduleCount == 0)
    }

    @Test func fullAcceptanceDoesNotGenerateAfterItsDelayedTextNotification() async throws {
        var current = state("hello ", location: 6)
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { text, _ in
                current = state(current.context.before + text,
                                location: current.range.location + (text as NSString).length)
                return TextSubmission()
            }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world and everyone.", field: candidate(current))
        #expect(model.accept(full: true, global: true))
        try await waitUntil { model.status == "已接受" }
        model.globalTextChanged()
        try await Task.sleep(for: .milliseconds(50))
        #expect(current.context.before == "hello world and everyone.")
        #expect(model.suggestion.isEmpty)
        #expect(model.predictionScheduleCount == 0)
    }

    @Test func cancelAfterSubmissionFinishesOnlyItsOwnReceipt() async throws {
        var sent = false
        var finished: [Bool] = []
        let prior = state("hello ", location: 6)
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { prior }, submit: { _, _ in
                sent = true
                return TextSubmission { finished.append($0) }
            }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world", field: candidate(prior))
        #expect(model.accept(full: false, global: true))
        try await waitUntil { sent }
        model.invalidate()
        try await waitUntil { finished.count == 1 }
        #expect(finished == [false])
        #expect(model.accepted == 0)
    }

    @Test func aPartialInsertionStopsTheQueuedWordsAndDoesNotResend() async throws {
        var current = state("hello ", location: 6)
        var writes = 0
        var finished: [Bool] = []
        let model = AppModel(acceptanceIO: GlobalAcceptanceIO(frontmostPID: { 12345 },
            captureText: { current }, submit: { _, _ in
                writes += 1
                current = state("hello w", location: 7)
                return TextSubmission { finished.append($0) }
            }))
        defer { model.shutdown() }
        model.globalEnabled = true
        model.recordGlobalCandidate("world again", field: candidate(current))
        #expect(model.accept(full: false, global: true))
        #expect(model.accept(full: false, global: true))
        try await waitUntil { !finished.isEmpty }
        #expect(writes == 1)
        #expect(finished == [false])
        #expect(model.accepted == 0)
        #expect(model.status == "文本已变化 · 不再重复插入")
    }
}
