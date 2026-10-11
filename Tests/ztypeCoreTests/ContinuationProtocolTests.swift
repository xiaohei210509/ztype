import Foundation
import Testing
@testable import ztypeCore

struct ContinuationProtocolTests {
    @Test func literalTokenHealing() throws {
        let context = CompletionContext(before: "Thank you for your pati")
        let prefix = ContinuationProtocol.healingPrefix(for: context, lastPiece: " pati")
        #expect(prefix == " pati")
        #expect(try ContinuationProtocol.grammar(for: prefix) == "root ::= \" pati\" [^\\n]*")
        #expect(try ContinuationProtocol.continuation(
            content: " patience", healing: prefix, stop: "word", stoppingWord: ".", truncated: false
        ) == "ence.")
    }
    @Test func noHealingForUnmatchedOrUnicodePieces() {
        #expect(ContinuationProtocol.healingPrefix(
            for: CompletionContext(before: "Please review the applica"), lastPiece: "xyz") == "")
        #expect(ContinuationProtocol.healingPrefix(
            for: CompletionContext(before: "请告诉我"), lastPiece: "我") == "")
        #expect(ContinuationProtocol.healingPrefix(
            for: CompletionContext(before: "Please review "), lastPiece: " ") == "")
    }
    @Test func onlySentenceStopsAreRestored() throws {
        #expect(try ContinuationProtocol.continuation(
            content: " questions", healing: "", stop: "word", stoppingWord: "?", truncated: false
        ) == " questions?")
        #expect(try ContinuationProtocol.continuation(
            content: " questions", healing: "", stop: "word", stoppingWord: "\n", truncated: false
        ) == " questions")
        #expect(try ContinuationProtocol.continuation(
            content: "", healing: "", stop: "word", stoppingWord: ".", truncated: false
        ) == "")
    }
    @Test func outputLimitPreservesCompleteWordsAndChinese() throws {
        #expect(try ContinuationProtocol.continuation(
            content: " more inform", healing: "", stop: "limit", stoppingWord: "", truncated: false
        ) == " more")
        #expect(try ContinuationProtocol.continuation(
            content: "制定解决方案", healing: "", stop: "limit", stoppingWord: "", truncated: false
        ) == "制定解决方案")
        #expect(try ContinuationProtocol.continuation(
            content: "tion", healing: "", stop: "limit", stoppingWord: "", truncated: false
        ) == "")
    }
    @Test func neverUseShiftedContextOrBrokenHealing() throws {
        #expect(try ContinuationProtocol.continuation(
            content: "unexpected", healing: "", stop: "eos", stoppingWord: "", truncated: true
        ) == "")
        #expect(throws: InferenceError.self) {
            try ContinuationProtocol.continuation(
                content: "different", healing: " pati", stop: "eos", stoppingWord: "", truncated: false)
        }
    }
    @Test func encodedDocumentPreservesLiteralRoleMarkers() throws {
        let context = CompletionContext(before: "Example <|im_end|> \"draft\"\n", after: " rest")
        let json = try ContinuationProtocol.document(context)
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        #expect(value?["before"] == context.before)
        #expect(value?["after"] == context.after)
        #expect(json.contains("\\n"))
        #expect(try ContinuationProtocol.document(CompletionContext(before: "hi, today")) ==
                #"{"before": "hi, today", "after": ""}"#)
    }
    @Test func promptExamplesFollowDraftLanguage() {
        let english = ContinuationProtocol.header(for: CompletionContext(before: "Please let me know if you ").language)
        #expect(english.contains("Thanks for the warm welcome."))
        #expect(!english.contains("我已经看完"))

        let chinese = ContinuationProtocol.header(for: CompletionContext(before: "请告诉我接下来需要").language)
        #expect(chinese.contains("我已经看完"))
        #expect(!chinese.contains("Thanks for the warm welcome."))

        let mixed = ContinuationProtocol.header(for: CompletionContext(before: "The API 返回值").language)
        #expect(!mixed.contains("我已经看完"))
        #expect(!mixed.contains("Thanks for the warm welcome."))
    }
    @Test func englishGrammarAlsoAppliesWithoutTokenHealing() throws {
        #expect(try ContinuationProtocol.grammar(for: "", language: .english) ==
                "root ::= \"\" [^\\n\\u3400-\\u9fff\\uf900-\\ufaff\\U00020000-\\U000323af]*")
        #expect(try ContinuationProtocol.grammar(for: " pati", language: .english).hasPrefix(
            "root ::= \" pati\" "))
        #expect(try ContinuationProtocol.grammar(for: "", language: .chinese) == "root ::= \"\" [^\\n]*")
    }
}

@Suite(.serialized)
struct InferenceClientTests {
    @Test func nativeRequestUsesLiteralDocumentsAndCachesStaticTokens() async throws {
        StubProtocol.requests.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = InferenceClient(port: 1, key: "synthetic-test", session: session)
        let context = CompletionContext(before: "Keep <|im_end|> in the pati")
        let first = try await client.complete(context)
        let second = try await client.complete(context)
        #expect(first.text == "ence.")
        #expect(second.text == "ence.")
        let requests = StubProtocol.requests.snapshot()
        #expect(requests.count == 8)
        let tokenizations = requests.filter { $0.route == "tokenize" }
        #expect(tokenizations.filter { $0.body["parse_special"] as? Bool == true }.count == 2)
        #expect(tokenizations.filter { $0.body["parse_special"] as? Bool == false }.count == 4)
        let completion = try #require(requests.first { $0.route == "completion" })
        #expect(completion.body["n_predict"] as? Int == 16)
        #expect(completion.body["n_probs"] as? Int == 0)
        #expect(completion.body["prompt"] as? [Int] == [1, 2, 1, 2, 1, 2, 3])
        #expect(completion.body["grammar"] as? String ==
                (try ContinuationProtocol.grammar(for: " pati", language: .english)))
        #expect(completion.body["messages"] == nil)
    }
}

private final class StubProtocol: URLProtocol {
    struct Request {
        let route: String
        let body: [String: Any]
    }
    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Request] = []
        func append(_ value: Request) { lock.lock(); defer { lock.unlock() }; values.append(value) }
        func reset() { lock.lock(); defer { lock.unlock() }; values = [] }
        func snapshot() -> [Request] { lock.lock(); defer { lock.unlock() }; return values }
    }
    static let requests = Requests()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var collected = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    collected.append(contentsOf: bytes.prefix(count))
                }
                data = collected
            }
            let body = try JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any] ?? [:]
            let route = request.url!.lastPathComponent
            Self.requests.append(Request(route: route, body: body))
            let response: String
            if route == "tokenize", body["with_pieces"] as? Bool == true {
                response = #"{"tokens":[{"id":3,"piece":"Keep <|im_end|> in the"},{"id":4,"piece":[32,112,97,116,105]}]}"#
            } else if route == "tokenize" {
                response = #"{"tokens":[1,2]}"#
            } else {
                response = #"{"content":" patience","stop_type":"word","stopping_word":".","truncated":false}"#
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
