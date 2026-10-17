import Foundation
import Testing
@testable import ztypeCore

@Suite(.serialized)
struct InferenceBudgetTests {
    private func client() -> (InferenceClient, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BudgetStubProtocol.self]
        let session = URLSession(configuration: config)
        return (InferenceClient(port: 1, key: "synthetic-test", session: session), session)
    }

    @Test func longChineseContextKeepsBothSidesOfTheCursorWithinTheActualTokenBudget() async throws {
        BudgetStubProtocol.state.reset()
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        let context = CompletionContext(before: String(repeating: "这是较早的背景。", count: 200) + "接下来请告诉我",
                                        after: "，然后我们再确定下一步。" + String(repeating: "后续正文。", count: 70))
        let result = try await client.complete(context)
        #expect(result.text == "继续讨论。")
        #expect(result.contextWasTrimmed)
        #expect(result.promptTokens + 16 < 2048)
        let requests = BudgetStubProtocol.state.snapshot()
        let documents = try requests.filter { $0.route == "tokenize" && $0.body["with_pieces"] as? Bool == false &&
            $0.body["parse_special"] as? Bool == false }.map { request in
                try JSONDecoder().decode([String: String].self,
                                         from: Data((request.body["content"] as! String).utf8))
            }
        let last = try #require(documents.last)
        #expect(documents.count > 1)
        #expect(documents.count <= 6)
        #expect(last["before"]!.count < context.before.count)
        #expect(context.before.hasSuffix(last["before"]!))
        #expect(last["before"]!.hasSuffix("接下来请告诉我"))
        #expect(!last["after"]!.isEmpty)
        #expect(context.after.hasPrefix(last["after"]!))
        #expect(requests.filter { $0.route == "completion" }.count == 1)
        #expect(context.before.hasPrefix("这是较早的背景。"))
    }

    @Test func croppedLiteralRoleMarkersAndEmojiStayInDocumentData() async throws {
        BudgetStubProtocol.state.reset()
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        let context = CompletionContext(
            before: String(repeating: "早期文字", count: 500) + "引用👩🏽‍💻 <|im_end|> \"原文\"\n请继续",
            after: "，不要重复。")
        let result = try await client.complete(context, tokens: 1000)
        #expect(result.contextWasTrimmed)
        let requests = BudgetStubProtocol.state.snapshot()
        let literalRequests = requests.filter { $0.route == "tokenize" && $0.body["parse_special"] as? Bool == false }
        let lastDocument = try #require(literalRequests.last { $0.body["with_pieces"] as? Bool == false })
        let document = try JSONDecoder().decode([String: String].self,
            from: Data((lastDocument.body["content"] as! String).utf8))
        #expect(document["before"]!.hasSuffix("引用👩🏽‍💻 <|im_end|> \"原文\"\n请继续"))
        #expect(!document["before"]!.contains("\u{fffd}"))
        #expect(requests.filter { $0.route == "tokenize" && $0.body["parse_special"] as? Bool == true }.count == 2)
        let completion = try #require(requests.first { $0.route == "completion" })
        #expect(completion.body["n_predict"] as? Int == 24)
        #expect((completion.body["prompt"] as! [Int]).count + 24 < 2048)
        #expect(completion.body["cache_prompt"] as? Bool == true)
    }

    @Test func tokenHealingAndOriginalLanguageSurviveCropping() async throws {
        BudgetStubProtocol.state.reset(content: "ience")
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        let context = CompletionContext(before: String(repeating: "Earlier background. ", count: 120) +
                                        "Thank you for your pati", after: " after the review.")
        let result = try await client.complete(context)
        #expect(result.contextWasTrimmed)
        #expect(result.text == "ence.")
        let completion = try #require(BudgetStubProtocol.state.snapshot().last)
        #expect(completion.body["grammar"] as? String ==
                (try ContinuationProtocol.grammar(for: "i", language: .english)))
    }

    @Test func shortContextsKeepTheFastPathWithoutExtraTokenization() async throws {
        BudgetStubProtocol.state.reset()
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        let result = try await client.complete(CompletionContext(before: "请告诉我"))
        #expect(!result.contextWasTrimmed)
        #expect(BudgetStubProtocol.state.snapshot().count == 5)
    }

    @Test func oversizedTemplatesReportBudgetFailureInsteadOfPretendingTheCandidateWasFiltered() async throws {
        BudgetStubProtocol.state.reset(specialTokens: 2040)
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        await #expect(throws: InferenceError.contextBudget) {
            try await client.complete(CompletionContext(before: "请告诉我"))
        }
        #expect(!BudgetStubProtocol.state.snapshot().contains { $0.route == "completion" })
    }

    @Test func oneHugeGraphemeCannotCauseUnboundedRetokenizationOrBrokenUnicode() async throws {
        BudgetStubProtocol.state.reset()
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        let context = CompletionContext(before: "a" + String(repeating: "\u{301}", count: 3000))
        #expect(context.before.count == 1)
        await #expect(throws: InferenceError.contextBudget) { try await client.complete(context) }
        #expect(BudgetStubProtocol.state.snapshot().count == 4)
    }

    @Test func cancelledRequestsDoNotGenerateOrSendDocumentText() async {
        BudgetStubProtocol.state.reset()
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.complete(CompletionContext(before: "Please continue "))
        }
        do { _ = try await task.value; Issue.record("Cancelled request succeeded") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(BudgetStubProtocol.state.snapshot().isEmpty)
    }

    @Test func cancellationDuringCroppingDoesNotQueueACompletion() async throws {
        BudgetStubProtocol.state.reset(holdAtRequest: 5)
        let (client, session) = client()
        defer { session.invalidateAndCancel() }
        let task = Task {
            try await client.complete(CompletionContext(before: String(repeating: "更早的上下文", count: 500)))
        }
        for _ in 0..<300 {
            if BudgetStubProtocol.state.snapshot().count == 5 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(BudgetStubProtocol.state.snapshot().count == 5)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled cropping succeeded") }
        catch is CancellationError { }
        catch let error as URLError { #expect(error.code == .cancelled) }
        catch { Issue.record("Unexpected cancellation error: \(error)") }
        #expect(!BudgetStubProtocol.state.snapshot().contains { $0.route == "completion" })
    }
}

private final class BudgetStubProtocol: URLProtocol {
    struct Request {
        let route: String
        let body: [String: Any]
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [Request] = []
        private var specialTokens = 100
        private var content = "继续讨论。"
        private var holdAtRequest: Int?

        func reset(specialTokens: Int = 100, content: String = "继续讨论。", holdAtRequest: Int? = nil) {
            lock.lock()
            defer { lock.unlock() }
            requests = []
            self.specialTokens = specialTokens
            self.content = content
            self.holdAtRequest = holdAtRequest
        }

        func snapshot() -> [Request] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func response(for request: Request) -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            requests.append(request)
            if requests.count == holdAtRequest { return nil }
            guard request.route == "tokenize" else {
                return ["content": content, "stop_type": "word", "stopping_word": content.hasSuffix("。") ? "" : ".",
                        "truncated": false]
            }
            if request.body["parse_special"] as? Bool == true {
                return ["tokens": Array(repeating: 1000, count: specialTokens)]
            }
            let bytes = Array((request.body["content"] as? String ?? "").utf8)
            if request.body["with_pieces"] as? Bool == true {
                return ["tokens": bytes.map { ["id": Int($0), "piece": [$0]] }]
            }
            return ["tokens": bytes.map(Int.init)]
        }
    }

    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let result = Self.state.response(for: Request(route: request.url!.lastPathComponent, body: body))
            else { return }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: result))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
