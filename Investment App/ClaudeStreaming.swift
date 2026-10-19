//
//  ClaudeStreaming.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import Foundation
import OSLog

/// Something Claude did mid-response, reported while a streamed request runs.
/// `id` identifies the content block, so later events for the same block update it.
enum ClaudeStreamEvent {
    /// A summary of Claude's reasoning so far
    case thinking(id: UUID, text: String)
    /// Text Claude has written so far in this block
    case text(id: UUID, text: String)
    /// A server tool call, once its input is complete (e.g. a web search and its query)
    case toolUse(id: UUID, name: String, input: [String: Any])
    /// What a web search returned: result pages, or an error code
    case searchResults(id: UUID, results: [AnalysisSource], errorCode: String?)
}

/// A complete reply rebuilt from a stream, in the same shape as a non-streaming response's `content`,
/// so it can be sent back unchanged (e.g. to resume a paused turn).
struct StreamedMessage {
    let content: [[String: Any]]
    let stopReason: String?
}

/// Rebuilds a Messages API reply from its server-sent events.
struct MessageStreamAccumulator {
    enum Change {
        case started(Int)
        case updated(Int)
        case stopped(Int)
    }

    private(set) var content: [[String: Any]] = []
    private(set) var stopReason: String?
    private(set) var errorMessage: String?
    /// e.g. "overloaded_error", from a mid-stream `error` event
    private(set) var errorType: String?
    /// Set by `message_stop`; a stream that ends without it was cut off
    private(set) var isComplete = false
    /// A stable ID per block index, for progress events
    private(set) var blockIDs: [Int: UUID] = [:]
    /// Tool input arrives as JSON fragments, parsed when the block stops
    private var partialJSON: [Int: String] = [:]
    /// Token and search counts: `message_start` has the input side, `message_delta` the final totals
    private(set) var usage: [String: Any] = [:]

    /// One log-friendly line, e.g. "input 12034, cache write 0, cache read 48210, output 3120, searches 14".
    var usageSummary: String {
        func count(_ key: String) -> Int { usage[key] as? Int ?? 0 }
        let searches = (usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int ?? 0
        return "input \(count("input_tokens")), cache write \(count("cache_creation_input_tokens")), "
            + "cache read \(count("cache_read_input_tokens")), output \(count("output_tokens")), searches \(searches)"
    }

    /// Applies one event's JSON; returns the block it changed, if any.
    mutating func apply(_ event: [String: Any]) -> Change? {
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            content = message?["content"] as? [[String: Any]] ?? []
            usage = message?["usage"] as? [String: Any] ?? [:]
            return nil

        case "content_block_start":
            guard let index = event["index"] as? Int, let block = event["content_block"] as? [String: Any] else { return nil }
            if index < content.count {
                content[index] = block
            } else {
                content.append(block)
            }
            blockIDs[index] = UUID()
            return .started(index)

        case "content_block_delta":
            guard let index = event["index"] as? Int, content.indices.contains(index),
                  let delta = event["delta"] as? [String: Any]
            else { return nil }
            switch delta["type"] as? String {
            case "text_delta":
                content[index]["text"] = (content[index]["text"] as? String ?? "") + (delta["text"] as? String ?? "")
            case "thinking_delta":
                content[index]["thinking"] = (content[index]["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                content[index]["signature"] = delta["signature"]
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            case "citations_delta":
                if let citation = delta["citation"] {
                    content[index]["citations"] = (content[index]["citations"] as? [Any] ?? []) + [citation]
                }
            default:
                return nil
            }
            return .updated(index)

        case "content_block_stop":
            guard let index = event["index"] as? Int, content.indices.contains(index) else { return nil }
            if let json = partialJSON.removeValue(forKey: index), !json.isEmpty,
               let input = try? JSONSerialization.jsonObject(with: Data(json.utf8)) {
                content[index]["input"] = input
            }
            return .stopped(index)

        case "message_delta":
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String {
                stopReason = reason
            }
            // The final usage is cumulative; it replaces the counts from message_start
            if let finalUsage = event["usage"] as? [String: Any] {
                usage.merge(finalUsage) { _, new in new }
            }
            return nil

        case "message_stop":
            isComplete = true
            return nil

        case "error":
            let error = event["error"] as? [String: Any]
            errorType = error?["type"] as? String
            errorMessage = error?["message"] as? String ?? "unknown error"
            return nil

        default:
            // ping and anything newer
            return nil
        }
    }

    /// The progress event for a change, if it's worth showing.
    func event(for change: Change) -> ClaudeStreamEvent? {
        let index: Int
        let isStop: Bool
        switch change {
        case .started(let i), .updated(let i):
            index = i
            isStop = false
        case .stopped(let i):
            index = i
            isStop = true
        }
        guard content.indices.contains(index), let id = blockIDs[index] else { return nil }
        let block = content[index]

        switch block["type"] as? String {
        case "thinking":
            return isStop ? nil : .thinking(id: id, text: block["thinking"] as? String ?? "")
        case "text":
            return isStop ? nil : .text(id: id, text: block["text"] as? String ?? "")
        case "server_tool_use":
            guard isStop else { return nil }
            return .toolUse(id: id, name: block["name"] as? String ?? "", input: block["input"] as? [String: Any] ?? [:])
        case "web_search_tool_result":
            guard case .started = change else { return nil }
            // A list of results on success, a single error object otherwise
            if let results = block["content"] as? [[String: Any]] {
                let sources = results.compactMap { result -> AnalysisSource? in
                    guard let url = result["url"] as? String else { return nil }
                    return AnalysisSource(title: result["title"] as? String ?? url, url: url)
                }
                return .searchResults(id: id, results: sources, errorCode: nil)
            }
            let errorCode = (block["content"] as? [String: Any])?["error_code"] as? String ?? "unknown"
            return .searchResults(id: id, results: [], errorCode: errorCode)
        default:
            return nil
        }
    }
}

extension ClaudeAPI {
    /// Thinking stays on (as Claude Opus 5 defaults) with readable summaries, shown as progress.
    static let summarizedThinking: [String: Any] = ["type": "adaptive", "display": "summarized"]

    /// Sends a streamed request, reporting progress through `onEvent`, and returns the rebuilt reply.
    static func streamMessage(
        body: [String: Any],
        apiKey: String,
        timeout: TimeInterval,
        allowFallback: Bool,
        http: any HTTPClient,
        onEvent: (ClaudeStreamEvent) -> Void
    ) async -> Result<StreamedMessage, ClaudeFailure> {
        var body = body
        body["stream"] = true
        // For a stream the timeout is the longest wait between bytes, not for the whole reply
        guard let request = makeRequest(body: body, apiKey: apiKey, timeout: timeout, allowFallback: allowFallback) else {
            ClaudeLog.logger.error("Couldn't encode the request body")
            return .failure(.invalidResponse("The app couldn't build the request to Claude."))
        }

        var accumulator = MessageStreamAccumulator()
        do {
            let (lines, response) = try await http.lines(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.network("The server's response wasn't an HTTP response."))
            }
            guard httpResponse.statusCode == 200 else {
                var errorLines: [String] = []
                for try await line in lines {
                    errorLines.append(line)
                }
                let errorBody = errorLines.joined(separator: "\n")
                ClaudeLog.logger.error("HTTP \(httpResponse.statusCode, privacy: .public): \(errorBody, privacy: .public)")
                return .failure(ClaudeFailure.apiError(status: httpResponse.statusCode, body: Data(errorBody.utf8)))
            }

            for try await line in lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                if let change = accumulator.apply(event), let progress = accumulator.event(for: change) {
                    onEvent(progress)
                }
            }
        } catch {
            ClaudeLog.logger.error("Stream failed after \(accumulator.content.count, privacy: .public) blocks: \(String(describing: error), privacy: .public)")
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return .failure(.network("The request was cancelled before Claude finished."))
            }
            return .failure(.network(error.localizedDescription))
        }

        if let errorMessage = accumulator.errorMessage {
            ClaudeLog.logger.error("Stream error event \(accumulator.errorType ?? "unknown", privacy: .public): \(errorMessage, privacy: .public)")
            // Errors after the stream opened arrive as events; map their type to the matching HTTP status
            let status = switch accumulator.errorType {
            case "overloaded_error": 529
            case "rate_limit_error": 429
            case "invalid_request_error": 400
            default: 500
            }
            return .failure(.api(status: status, message: errorMessage))
        }
        guard !Task.isCancelled else {
            ClaudeLog.logger.notice("Stream cancelled")
            return .failure(.network("The request was cancelled before Claude finished."))
        }
        guard accumulator.isComplete else {
            ClaudeLog.logger.error("Stream closed before message_stop, after \(accumulator.content.count, privacy: .public) blocks")
            return .failure(.network("The connection closed before Claude finished replying."))
        }
        ClaudeLog.logger.info("Usage: \(accumulator.usageSummary, privacy: .public), stop_reason=\(accumulator.stopReason ?? "none", privacy: .public)")
        return .success(StreamedMessage(content: accumulator.content, stopReason: accumulator.stopReason))
    }

    /// `askJSON`, streamed: same structured-output request, with progress reported while Claude works.
    static func streamJSON<T: Decodable>(
        _ contentBlocks: [[String: Any]],
        schema: [String: Any],
        as type: T.Type,
        maxTokens: Int,
        http: any HTTPClient,
        apiKey: String?,
        onEvent: (ClaudeStreamEvent) -> Void
    ) async -> Result<T, ClaudeFailure> {
        guard let apiKey else { return .failure(.missingKey) }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "thinking": summarizedThinking,
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": contentBlocks]]
        ]
        let message: StreamedMessage
        switch await streamMessage(body: body, apiKey: apiKey, timeout: 300, allowFallback: true, http: http, onEvent: onEvent) {
        case .success(let value): message = value
        case .failure(let failure): return .failure(failure)
        }

        switch message.stopReason {
        case "refusal":
            ClaudeLog.logger.error("Structured reply refused")
            return .failure(.refused)
        case "max_tokens":
            ClaudeLog.logger.error("Structured reply cut off at max_tokens (\(maxTokens, privacy: .public))")
            return .failure(.invalidResponse(
                "Claude's reply was cut off because it reached the length limit (\(maxTokens.formatted()) tokens)."
            ))
        default:
            break
        }

        // The last text block is the answer (after a fallback, earlier blocks are the declined model's partial output)
        guard let text = message.content.last(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            let types = message.content.compactMap { $0["type"] as? String }.joined(separator: ", ")
            ClaudeLog.logger.error("Structured reply had no text block; blocks: [\(types, privacy: .public)], stop_reason=\(message.stopReason ?? "none", privacy: .public)")
            return .failure(.invalidResponse("Claude's reply contained no answer text."))
        }
        do {
            return .success(try JSONDecoder().decode(T.self, from: Data(text.utf8)))
        } catch {
            ClaudeLog.logger.error("Structured reply didn't decode: \(String(describing: error), privacy: .public)\nRaw reply: \(text, privacy: .public)")
            return .failure(.invalidResponse("Claude's reply wasn't in the expected format (\(describe(error)))."))
        }
    }

    /// A short, readable reason for a JSON decoding failure, e.g. "missing field 'reason' in recommendations[3]".
    private static func describe(_ error: Error) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.map { key in key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)" }
                .joined()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        switch error as? DecodingError {
        case .keyNotFound(let key, let context)?:
            let location = path(context.codingPath)
            return "missing field '\(key.stringValue)'" + (location.isEmpty ? "" : " in \(location)")
        case .typeMismatch(_, let context)?, .valueNotFound(_, let context)?:
            return "unexpected value at \(path(context.codingPath))"
        case .dataCorrupted(let context)?:
            let location = path(context.codingPath)
            return location.isEmpty ? "not valid JSON" : "invalid value at \(location)"
        default:
            return error.localizedDescription
        }
    }

    /// The assistant content to send back when resuming a paused turn. Before a fallback boundary, only text
    /// and paired server-tool blocks can be echoed; the declined model's thinking and unfinished calls are dropped.
    static func echoableContent(_ content: [[String: Any]]) -> [[String: Any]] {
        guard let boundary = content.lastIndex(where: { $0["type"] as? String == "fallback" }) else { return content }
        let resultIDs = Set(content.compactMap { $0["tool_use_id"] as? String })
        let before = content[..<boundary].filter { block in
            switch block["type"] as? String {
            case "text": true
            case "server_tool_use": resultIDs.contains(block["id"] as? String ?? "")
            case let type?: type.hasSuffix("_tool_result")
            default: false
            }
        }
        return Array(before) + content[boundary...]
    }
}
