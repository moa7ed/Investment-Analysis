//
//  ClaudeStreaming.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import Foundation

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
    /// Set by `message_stop`; a stream that ends without it was cut off
    private(set) var isComplete = false
    /// A stable ID per block index, for progress events
    private(set) var blockIDs: [Int: UUID] = [:]
    /// Tool input arrives as JSON fragments, parsed when the block stops
    private var partialJSON: [Int: String] = [:]

    /// Applies one event's JSON; returns the block it changed, if any.
    mutating func apply(_ event: [String: Any]) -> Change? {
        switch event["type"] as? String {
        case "message_start":
            content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
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
            return nil

        case "message_stop":
            isComplete = true
            return nil

        case "error":
            let error = event["error"] as? [String: Any]
            errorMessage = "\(error?["type"] as? String ?? "error"): \(error?["message"] as? String ?? "unknown")"
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
            return .failure(.failed)
        }

        var accumulator = MessageStreamAccumulator()
        do {
            let (lines, response) = try await http.lines(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return .failure(.failed) }
            guard httpResponse.statusCode == 200 else {
                var errorBody = ""
                for try await line in lines {
                    errorBody += line
                }
                print("[ClaudeAPI] Stream HTTP \(httpResponse.statusCode): \(errorBody)")
                return .failure(.failed)
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
            print("[ClaudeAPI] Stream error: \(error)")
            return .failure(.failed)
        }

        if let errorMessage = accumulator.errorMessage {
            print("[ClaudeAPI] Stream error event: \(errorMessage)")
            return .failure(.failed)
        }
        guard accumulator.isComplete, !Task.isCancelled else {
            print("[ClaudeAPI] Stream ended before the reply was complete")
            return .failure(.failed)
        }
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
            return .failure(.refused)
        case "max_tokens":
            print("[ClaudeAPI] Streamed response truncated at max_tokens (\(maxTokens))")
            return .failure(.failed)
        default:
            break
        }

        // The last text block is the answer (after a fallback, earlier blocks are the declined model's partial output)
        guard let text = message.content.last(where: { $0["type"] as? String == "text" })?["text"] as? String else {
            return .failure(.failed)
        }
        do {
            return .success(try JSONDecoder().decode(T.self, from: Data(text.utf8)))
        } catch {
            print("[ClaudeAPI] Decode error: \(error)\nRaw response: \(text)")
            return .failure(.failed)
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
