import Foundation

public struct InferenceResult: Sendable {
    public let text: String
    public let milliseconds: Double
    public let promptTokens: Int
    public let contextWasTrimmed: Bool
    public let stopReason: String
}

public enum InferenceError: LocalizedError, Equatable {
    case invalidResponse
    case server(Int)
    case contextBudget
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Local engine returned an invalid response."
        case .server(let status): return "Local engine HTTP \(status)."
        case .contextBudget: return "上下文无法安全缩减至模型预算 · 已跳过"
        }
    }
}

public actor InferenceClient {
    private let session: URLSession
    private let baseURL: URL
    private let key: String
    private var headers: [CompletionLanguage: [Int]] = [:]
    private var boundary: [Int]?

    public init(port: Int, key: String, session: URLSession? = nil) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.key = key
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        config.httpMaximumConnectionsPerHost = 1
        config.connectionProxyDictionary = [:]
        self.session = session ?? URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func complete(_ context: CompletionContext, tokens: Int = 16) async throws -> InferenceResult {
        let start = ContinuousClock.now
        let language = context.language
        if headers[language] == nil {
            headers[language] = try await tokenize(
                ContinuationProtocol.header(for: context.language), special: true
            ).map(\.id)
        }
        if boundary == nil {
            boundary = try await tokenize(ContinuationProtocol.boundary, special: true).map(\.id)
        }
        let budget = max(1, min(tokens, 24))
        let header = headers[language] ?? []
        let separator = boundary ?? []
        let available = 2048 - header.count - separator.count - budget - 1
        guard available > 0 else { throw InferenceError.contextBudget }
        var window = context
        // Only the inference window changes; AX validation keeps the original snapshot.
        for _ in 0..<6 {
            try Task.checkCancellation()
            let document = try await tokenize(ContinuationProtocol.document(window), special: false).map(\.id)
            let pieces = try await tokenize(window.before, special: false, withPieces: true)
            var draft = pieces.map(\.id)
            let healing = ContinuationProtocol.healingPrefix(for: window, lastPiece: pieces.last?.piece ?? "")
            if !healing.isEmpty { draft.removeLast() }
            let variableCount = document.count + draft.count
            if variableCount <= available {
                let prompt = header + document + separator + draft
                let body = Request(prompt: prompt, n_predict: budget,
                                   grammar: healing.isEmpty && language != .english ? nil :
                                    try ContinuationProtocol.grammar(for: healing, language: language))
                let result: Response = try await send("completion", body: body)
                let text = try ContinuationProtocol.continuation(
                    content: result.content, healing: healing, stop: result.stop_type,
                    stoppingWord: result.stopping_word, truncated: result.truncated
                )
                return InferenceResult(text: text, milliseconds: Self.milliseconds(since: start),
                                       promptTokens: prompt.count, contextWasTrimmed: window != context,
                                       stopReason: result.truncated ? "context-shift" : result.stop_type)
            }
            let ratio = min(0.8, Double(available) / Double(variableCount) * 0.9)
            let beforeCount = max(1, Int(Double(window.before.count) * ratio))
            let afterCount = min(64, Int(Double(window.after.count) * ratio))
            let smaller = CompletionContext(
                before: String(window.before.suffix(beforeCount)), after: String(window.after.prefix(afterCount)),
                application: context.application, inputLanguage: context.inputLanguage
            )
            guard smaller != window else { throw InferenceError.contextBudget }
            window = smaller
        }
        throw InferenceError.contextBudget
    }

    private func tokenize(_ content: String, special: Bool, withPieces: Bool = false) async throws -> [Piece] {
        let response: TokenResponse = try await send(
            "tokenize", body: TokenRequest(content: content, parse_special: special, with_pieces: withPieces)
        )
        return response.tokens
    }

    private func send<Body: Encodable, Result: Decodable>(_ route: String, body: Body) async throws -> Result {
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw InferenceError.invalidResponse }
        guard http.statusCode == 200 else { throw InferenceError.server(http.statusCode) }
        return try JSONDecoder().decode(Result.self, from: data)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    public func healthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private struct Request: Encodable {
        let prompt: [Int]
        let n_predict: Int
        let grammar: String?
        let temperature = -1.0
        let stream = false
        let cache_prompt = true
        let n_probs = 0
        let stop = ["\n"] + ContinuationProtocol.sentenceStops
    }
    private struct TokenRequest: Encodable {
        let content: String
        let parse_special: Bool
        let with_pieces: Bool
    }
    private struct TokenResponse: Decodable {
        let tokens: [Piece]
    }
    private struct Piece: Decodable {
        let id: Int
        let piece: String

        init(from decoder: Decoder) throws {
            if let id = try? decoder.singleValueContainer().decode(Int.self) {
                self.id = id
                piece = ""
                return
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(Int.self, forKey: .id)
            if let text = try? values.decode(String.self, forKey: .piece) {
                piece = text
            } else {
                let bytes = try values.decode([UInt8].self, forKey: .piece)
                piece = String(bytes: bytes, encoding: .utf8) ?? ""
            }
        }

        private enum CodingKeys: CodingKey { case id, piece }
    }
    private struct Response: Decodable {
        let content: String
        let stop_type: String
        let stopping_word: String
        let truncated: Bool
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
