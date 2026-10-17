import AppKit
import Testing
import ztypeCore
@testable import ztype

@MainActor
struct LocalAcceptanceTests {
    private func snapshot(_ text: String, location: Int? = nil) -> LocalSnapshot {
        let entire = text as NSString
        let location = location ?? entire.length
        let start = max(0, location - 1800)
        return LocalSnapshot(
            context: CompletionContext(before: entire.substring(with: NSRange(location: start, length: location - start)),
                                       after: entire.substring(from: location), application: "trial"),
            range: NSRange(location: location, length: 0), caret: .zero
        )
    }

    @Test func chineseTabsConsumeTheOriginalCandidateWithoutRequestingPrediction() {
        var current = snapshot("明天我们会")
        let model = AppModel()
        defer { model.shutdown() }
        model.localCapture = { current }
        model.localInsert = { text, _ in current = snapshot(current.context.before + text); return true }
        let original = "制定解决方案，然后再讨论。"
        model.recordLocalCandidate(original, snapshot: current)
        var count = 0
        while !model.suggestion.isEmpty, count < 40 {
            #expect(model.accept(full: false, global: false))
            model.localChanged()
            count += 1
        }
        #expect(count > 2)
        #expect(current.context.before == "明天我们会" + original)
        #expect(model.predictionScheduleCount == 0)
    }

    @Test func displayedLatencyUsesTheWholePipelineAndOnlyTheLatestHundredSamples() {
        let model = AppModel()
        defer { model.shutdown() }
        model.recordDisplayLatency(9000, inference: 100)
        for sample in 1...100 { model.recordDisplayLatency(Double(sample), inference: 20) }
        #expect(model.latency == 100)
        #expect(model.inferenceLatency == 20)
        #expect(model.p95 == 95)
    }

    @Test func consecutiveLocalTabsKeepTheOriginalWordsAndDoNotSchedulePrediction() {
        var current = snapshot("hello ")
        let model = AppModel()
        defer { model.shutdown() }
        model.localCapture = { current }
        model.localInsert = { text, range in
            #expect(range == current.range)
            current = snapshot(current.context.before + text)
            return true
        }
        model.recordLocalCandidate("one two three four five.", snapshot: current)
        for expected in [" two three four five.", " three four five.", " four five.", " five.", ""] {
            #expect(model.accept(full: false, global: false))
            #expect(model.suggestion == expected)
            model.localChanged()
            model.localSelectionChanged()
            model.schedule(global: false)
            #expect(model.predictionScheduleCount == 0)
        }
        #expect(current.context.before == "hello one two three four five.")
        #expect(model.accepted == 5)
        current = snapshot(current.context.before + " New")
        model.localChanged()
        #expect(model.suggestion.isEmpty)
        #expect(model.predictionScheduleCount == 1)
    }

    @Test func aSlidingUTF16ContextWindowDoesNotReplaceTheLocalRemainder() {
        let document = String(repeating: "x", count: 1799) + " "
        var entire = document
        var current = snapshot(entire)
        let model = AppModel()
        defer { model.shutdown() }
        model.localCapture = { current }
        model.localInsert = { text, _ in
            entire += text
            current = snapshot(entire)
            return true
        }
        model.recordLocalCandidate("hello world.", snapshot: current)
        #expect(model.accept(full: false, global: false))
        #expect(model.suggestion == " world.")
        #expect(model.accept(full: false, global: false))
        #expect(entire == document + "hello world.")
        #expect(model.accepted == 2)
        #expect(model.predictionScheduleCount == 0)
    }

    @Test func appKitCompletionNotificationsAreNotTreatedAsManualEdits() async {
        let model = AppModel()
        defer { model.shutdown() }
        let editor = CompletionTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        let coordinator = TrialEditor.Coordinator(model: model)
        editor.isRichText = false
        editor.string = "hello "
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        coordinator.editor = editor
        editor.delegate = coordinator
        model.localCapture = { snapshot(editor.string, location: editor.selectedRange().location) }
        model.localInsert = { text, range in
            editor.insertCompletion(text, replacementRange: range)
            return true
        }
        model.recordLocalCandidate("one two three four five.", snapshot: model.localCapture!()!)
        for _ in 0..<5 {
            #expect(model.accept(full: false, global: false))
            await Task.yield()
            #expect(model.predictionScheduleCount == 0)
        }
        #expect(editor.string == "hello one two three four five.")
        editor.insertText(" New", replacementRange: editor.selectedRange())
        #expect(model.predictionScheduleCount == 1)
        #expect(model.suggestion.isEmpty)
    }

    @Test func manualCaretMovementCancelsThePinnedLocalCandidate() {
        var current = snapshot("hello ")
        let model = AppModel()
        defer { model.shutdown() }
        model.localCapture = { current }
        model.recordLocalCandidate("one two three.", snapshot: current)
        current = snapshot("hello ", location: 2)
        model.localSelectionChanged()
        #expect(model.suggestion.isEmpty)
        #expect(model.predictionScheduleCount == 0)
    }

    @Test func localNativeTabsDoNotStartPredictionButNewTypingDoes() {
        var current = snapshot("hello ")
        let model = AppModel()
        defer { model.shutdown() }
        model.localCapture = { current }
        model.nativeTab()
        current = snapshot("hello \t")
        model.localChanged()
        #expect(model.predictionScheduleCount == 0)
        model.invalidate()
        current = snapshot("hello \tnew")
        model.localChanged()
        #expect(model.predictionScheduleCount == 1)
    }
}
