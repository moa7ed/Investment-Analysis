//
//  HTTPClient.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//

import Foundation

/// The network seam for Yahoo Finance and Claude requests. The app uses `URLSession`;
/// tests (and the UI-test mode) inject a stub so nothing touches the internet.
nonisolated protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
    /// Sends a request and returns the response body line by line as it arrives (for server-sent events).
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse)
}

extension URLSession: HTTPClient {
    nonisolated func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }

    nonisolated func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        let (bytes, response) = try await bytes(for: request)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let reader = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Stops reading (and closes the connection) when the consumer stops or is cancelled
            continuation.onTermination = { _ in reader.cancel() }
        }
        return (lines, response)
    }
}
