//
//  StubHTTPClient.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//

#if DEBUG
import Foundation

/// An offline `HTTPClient` that answers Yahoo and Claude requests from canned responses.
/// Used by unit tests and the UI-test launch mode. Unmatched requests fail like an offline network,
/// so nothing ever reaches the internet.
nonisolated final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    /// What Claude should answer for a request whose prompt text is passed in.
    enum ClaudeReply: Sendable {
        /// A successful reply whose text is this JSON (what structured outputs would return)
        case json(String)
        /// `stop_reason: "refusal"`
        case refusal
        /// `stop_reason: "max_tokens"` — the JSON was cut off
        case truncated
        /// A non-200 HTTP status
        case httpError(Int)
    }

    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)?

    private let lock = NSLock()
    private var handlers: [Handler] = []
    private var recorded: [URLRequest] = []

    /// Every request sent, in order — lets tests assert e.g. that Claude was called exactly once.
    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    /// Requests sent to the Claude API.
    var claudeRequests: [URLRequest] {
        requests.filter { $0.url?.host == "api.anthropic.com" }
    }

    init() {}

    /// Adds a handler; the first handler returning a response wins (handlers added later are checked first,
    /// so a test can override a default).
    func on(_ handler: @escaping Handler) {
        lock.withLock { handlers.insert(handler, at: 0) }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let handlers = lock.withLock {
            recorded.append(request)
            return self.handlers
        }
        for handler in handlers {
            if let (status, body) = handler(request), let url = request.url {
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (body, response)
            }
        }
        throw URLError(.notConnectedToInternet)
    }

    /// Streams the same canned responses as `send`. A stubbed Claude message is replayed as server-sent events
    /// (each block arriving whole in its `content_block_start`); any other body is returned line by line, so a
    /// handler can also return raw SSE text.
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let lines = Self.eventLines(fromMessage: data, status: status)
            ?? String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let stream = AsyncThrowingStream<String, Error> { continuation in
            lines.forEach { continuation.yield($0) }
            continuation.finish()
        }
        return (stream, response)
    }

    /// SSE `data:` lines equivalent to a non-streaming Messages API reply, or nil if the body isn't one.
    private static func eventLines(fromMessage data: Data, status: Int) -> [String]? {
        guard status == 200,
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return nil }

        var events: [[String: Any]] = [["type": "message_start", "message": ["content": []]]]
        for (index, block) in content.enumerated() {
            events.append(["type": "content_block_start", "index": index, "content_block": block])
            events.append(["type": "content_block_stop", "index": index])
        }
        events.append(["type": "message_delta", "delta": ["stop_reason": message["stop_reason"] ?? NSNull()]])
        events.append(["type": "message_stop"])
        return events.map { "data: \(jsonString($0))" }
    }

    // MARK: - Yahoo

    /// Answers Yahoo's chart API for an exact symbol.
    func yahooQuote(_ symbol: String, price: Double, currency: String, type: String? = "EQUITY", name: String? = nil) {
        var meta: [String: Any] = ["regularMarketPrice": price, "currency": currency, "longName": name ?? symbol]
        if let type {
            meta["instrumentType"] = type
        }
        let body = Self.json(["chart": ["result": [["meta": meta]]]])
        on { request in
            guard let url = request.url, url.path.hasSuffix("/v8/finance/chart/\(symbol)") else { return nil }
            return (200, body)
        }
    }

    /// Answers the forex pair used to convert `currency` to GBP (e.g. "USDGBP=X").
    func fxRate(_ currency: String, toGBP rate: Double) {
        yahooQuote("\(currency)GBP=X", price: rate, currency: "GBP", type: "CURRENCY")
    }

    /// Answers Yahoo's symbol search for a query (case-insensitive).
    func yahooSearch(_ query: String, results: [(symbol: String, type: String, name: String)]) {
        let body = Self.json([
            "quotes": results.map { ["symbol": $0.symbol, "quoteType": $0.type, "shortname": $0.name, "exchange": "TEST"] }
        ])
        on { request in
            guard let url = request.url, url.path.hasSuffix("/v1/finance/search"),
                  let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value,
                  q.lowercased() == query.lowercased()
            else { return nil }
            return (200, body)
        }
    }

    // MARK: - Claude

    /// Answers Claude requests. The closure receives the prompt text and returns a reply, or nil to not handle it.
    func claude(_ respond: @escaping @Sendable (_ prompt: String) -> ClaudeReply?) {
        on { request in
            guard request.url?.host == "api.anthropic.com" else { return nil }
            guard let reply = respond(Self.promptText(of: request)) else { return nil }
            switch reply {
            case .json(let text):
                return (200, Self.claudeMessage(text: text, stopReason: "end_turn"))
            case .refusal:
                return (200, Self.claudeMessage(text: "", stopReason: "refusal"))
            case .truncated:
                return (200, Self.claudeMessage(text: "{\"entries\": [", stopReason: "max_tokens"))
            case .httpError(let status):
                return (status, Data("{\"error\":\"stub\"}".utf8))
            }
        }
    }

    /// The concatenated text blocks of a Claude request's user message.
    static func promptText(of request: URLRequest) -> String {
        guard let body = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]],
              let content = messages.first?["content"] as? [[String: Any]]
        else { return "" }
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Encodes a value as a JSON string, for building `ClaudeReply.json` payloads.
    static func jsonString(_ object: Any) -> String {
        String(decoding: json(object), as: UTF8.self)
    }

    private static func claudeMessage(text: String, stopReason: String) -> Data {
        json([
            "content": [["type": "text", "text": text]],
            "stop_reason": stopReason
        ])
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
#endif
