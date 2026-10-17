import Foundation
import ztypeCore

@main
struct ztypeBench {
    static func main() async throws {
        let args = CommandLine.arguments
        guard (3...4).contains(args.count), let port = Int(args[1]) else {
            print("Usage: ztypeBench <port> <key> [output.json]")
            return
        }
        let client = InferenceClient(port: port, key: args[2])
        let longDraft = String((1...30).map {
            "第\($0)轮测试检查异步通知、AXTextMarker、UTF-16 光标、Qwen token 预算和剪贴板恢复。"
        }.joined().suffix(1700)) + "我们需要先确认问题的原因，然后再"
        let cases: [CompletionContext] = [
            .init(before: "Hi,"),
            .init(before: "你好，"),
            .init(before: "hi, today"),
            .init(before: "hi, today's"),
            .init(before: "hi today"),
            .init(before: "hi today is "),
            .init(before: "hi today is a v"),
            .init(before: "I think it's"),
            .init(before: "Hello, how are"),
            .init(before: "Please review the applica"),
            .init(before: "Thank you for your pati"),
            .init(before: "Thank you for your feedback. I will review the changes and "),
            .init(before: "The project is delayed because the tests are failing. We need to "),
            .init(before: "Please let me know if you have any "),
            .init(before: "The meeting has been cancelled. Please do not "),
            .init(before: "Solar panels generate electricity by converting sunlight into "),
            .init(before: "I cannot attend the meeting tomorrow because "),
            .init(before: "I look forward to hearing"),
            .init(before: "The tests fail only when the cache is enabled. We should "),
            .init(before: "The result is still being measured. The latency is "),
            .init(before: "Please let me know if you have any ", after: " about the draft."),
            .init(before: "Thank you for your ", after: " patience."),
            .init(before: "请告诉我"),
            .init(before: "我们需要先确认问题的原因，然后再"),
            .init(before: "这次先不要发布，等测试"),
            .init(before: "这个 API 的返回值是"),
            .init(before: String(repeating: "这份报告讨论的是本地输入补全的速度与可靠性。", count: 75) +
                  "我们需要先确认问题的原因，然后再", after: "，不要直接发布。"),
            .init(before: longDraft, after: "，不要直接发布。")
        ]
        var times: [Double] = []
        var displayed = 0
        var evidence: [Evidence] = []
        for context in cases {
            let result = try await client.complete(context)
            times.append(result.milliseconds)
            let filtered = CompletionPolicy.filter(result.text, context: context)
            if filtered != nil { displayed += 1 }
            evidence.append(Evidence(before: context.before, after: context.after, raw: result.text,
                                     displayed: filtered, milliseconds: result.milliseconds,
                                     promptTokens: result.promptTokens, contextWasTrimmed: result.contextWasTrimmed,
                                     stopReason: result.stopReason))
            print(String(format: "%.0f ms | %d tokens%@ [%@] | %@ | %@", result.milliseconds,
                         result.promptTokens, result.contextWasTrimmed ? " (trimmed)" : "",
                         result.stopReason,
                         String(context.before.suffix(100)), filtered ?? "[filtered: \(result.text)]"))
        }
        let sorted = times.sorted()
        print(String(format: "p50=%.0f ms p95=%.0f ms candidates=%d/%d",
                     sorted[sorted.count / 2], sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
                     displayed, cases.count))
        if args.count == 4 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(evidence).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
        }
    }

    private struct Evidence: Encodable {
        let before: String
        let after: String
        let raw: String
        let displayed: String?
        let milliseconds: Double
        let promptTokens: Int
        let contextWasTrimmed: Bool
        let stopReason: String
    }
}
