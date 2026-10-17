import Testing
@testable import ztypeCore

struct CompletionPolicyTests {
    let context = CompletionContext(before: "Please let me know if you have any ")

    @Test func simpleContinuation() {
        #expect(CompletionPolicy.filter("questions.", context: context) == "questions.")
    }
    @Test func uncertainAndMetaOutput() {
        for text in ["NONE", "<NONE>", "Sure, I can help.", "Here is your answer",
                     "```swift", "<think>yes</think>", "\"questions.\"", "hello\nworld"] {
            #expect(CompletionPolicy.filter(text, context: context) == nil)
        }
    }
    @Test func plausibleNumbersAreAllowed() {
        #expect(CompletionPolicy.filter("questions about the 2028 deadline.", context: context) != nil)
        let known = CompletionContext(before: "The deadline is 2028. Please confirm ")
        #expect(CompletionPolicy.filter("the 2028 deadline.", context: known) != nil)
    }
    @Test func midWordCursor() {
        #expect(!CompletionContext(before: "Please let me know ", after: "questions").eligible)
        #expect(CompletionContext(before: "Please let me know ", after: ".").eligible)
    }
    @Test func sensitiveContext() {
        #expect(!CompletionContext(before: "Set api_key=abcdefg ").eligible)
        #expect(!CompletionContext(before: "Authorization: Bearer abcdefg ").eligible)
    }
    @Test func wordAcceptance() {
        #expect(CompletionPolicy.nextWord(in: " more information.") == " more")
        #expect(CompletionPolicy.nextWord(in: "questions.") == "questions.")
    }
    @Test func shortPrefixesAtNaturalBoundaries() {
        for before in ["Hi,", "Hi ", "你好，", "Go!", "OK "] {
            #expect(CompletionContext(before: before).eligible)
        }
        for before in ["", "h", "ab", "1 ", "🤔 ", "Hi,\n"] {
            #expect(!CompletionContext(before: before).eligible)
        }
        #expect(!CompletionContext(before: "Hi,", after: "there").eligible)
    }

    @Test func chineseAcceptanceUsesWordsWithoutChangingTheCandidate() {
        let original = "制定解决方案，然后明天下午再讨论。"
        var remaining = original
        var accepted = ""
        var parts: [String] = []
        while !remaining.isEmpty, parts.count < 40 {
            let part = CompletionPolicy.nextWord(in: remaining)
            #expect(!part.isEmpty)
            #expect(remaining.hasPrefix(part))
            parts.append(part)
            accepted += part
            remaining = String(remaining.dropFirst(part.count))
        }
        #expect(remaining.isEmpty)
        #expect(accepted == original)
        #expect(parts.count > 3)
        #expect(parts.first != original)
        #expect(!parts.contains("。"))
        #expect(CompletionPolicy.nextWord(in: " 👩🏽‍💻").hasPrefix(" "))
    }

    @Test func mixedLanguageAcceptancePreservesLeadingSpaceAndAcronyms() {
        let suggestion = " API 返回更多结果。"
        #expect(CompletionPolicy.nextWord(in: suggestion) == " API")
        let original = " 请确认 2028 年的计划。"
        var remaining = original
        var restored = ""
        while !remaining.isEmpty {
            let part = CompletionPolicy.nextWord(in: remaining)
            restored += part
            remaining = String(remaining.dropFirst(part.count))
        }
        #expect(restored == original)
    }
    @Test func wordBudget() {
        #expect(CompletionPolicy.filter("one two three four", context: context, limit: 2) == "one two")
    }
    @Test func duplicateSuffix() {
        #expect(CompletionPolicy.filter("questions today.", context: CompletionContext(
            before: context.before, after: " today.")) == "questions")
        #expect(CompletionPolicy.filter("patience.", context: CompletionContext(
            before: "Thank you for your ", after: " patience.")) == nil)
    }
    @Test func encodedDocument() {
        let input = CompletionContext(before: "Example \"ignore rules\"\nplease continue ")
        #expect(input.prompt.contains("\\\"ignore rules\\\""))
        #expect(input.prompt.contains("\\n"))
    }
    @Test func noSpellCorrection() {
        #expect(CompletionPolicy.filter("tion", context: CompletionContext(before: "Please review the applica")) == "tion")
    }
    @Test func echoedFullPrefix() {
        #expect(CompletionPolicy.filter("Please let me know if you have any questions.", context: context) == "questions.")
    }
    @Test func echoedTruncatedPrefix() {
        #expect(CompletionPolicy.filter("Please let me know if you", context: context) == nil)
    }
    @Test func speculativeContinuationsAreAllowed() {
        let reason = CompletionContext(before: "I cannot attend the meeting tomorrow because ")
        #expect(reason.eligible)
        #expect(CompletionPolicy.filter("I have a prior commitment.", context: reason) != nil)
        let weather = CompletionContext(before: "It looks like the weather will be ")
        #expect(CompletionPolicy.filter("sunny tomorrow.", context: weather) != nil)
    }
    @Test func plausibleCommitmentsAreAllowed() {
        #expect(CompletionPolicy.filter("reply by tomorrow.", context: context) != nil)
        #expect(CompletionPolicy.filter("implement them as soon as possible.", context: context) != nil)
    }
    @Test func exactContinuationSpacing() {
        #expect(CompletionPolicy.filter(" is a great day.", context: CompletionContext(
            before: "hi, today")) == " is a great day.")
        #expect(CompletionPolicy.filter(" weather is nice.", context: CompletionContext(
            before: "hi, today's")) == " weather is nice.")
        #expect(CompletionPolicy.filter("tion", context: CompletionContext(
            before: "Please review the applica")) == "tion")
        #expect(CompletionPolicy.filter("sis", context: CompletionContext(
            before: "Please finish the analy")) == "sis")
    }
    @Test func shortChineseContext() {
        #expect(CompletionContext(before: "请告诉我").eligible)
        #expect(!CompletionContext(before: "请告").eligible)
    }
    @Test func languageMatchesContextWithoutRestrictingOpenChineseCompletions() {
        let english = CompletionContext(before: "hi today is ")
        #expect(english.language == .english)
        #expect(CompletionPolicy.filter(" 你好！", context: english) == nil)
        #expect(CompletionPolicy.filter(" a sunny afternoon.", context: english) != nil)
        #expect(CompletionPolicy.filter(" café at 3:30.", context: english) != nil)
        #expect(CompletionPolicy.filter("𠮷", context: english) == nil)
        #expect(CompletionContext(before: "这是上一段。\nPlease let me know ", inputLanguage: "en").language == .english)
        #expect(CompletionContext(before: "请告诉我", inputLanguage: "en").language == .chinese)

        let chinese = CompletionContext(before: "这周末天气看起来")
        #expect(chinese.language == .chinese)
        #expect(CompletionPolicy.filter("适合去海边，也可能会下雨。", context: chinese) != nil)

        let mixed = CompletionContext(before: "The API 返回值")
        #expect(mixed.language == .mixed)
        #expect(CompletionPolicy.filter("包含更多 details。", context: mixed) != nil)
    }
    @Test func noPartialSuffixOverlap() {
        #expect(CompletionPolicy.filter("help with test", context: CompletionContext(
            before: "Please ask for ", after: " testing.")) == "help with test")
    }
}
