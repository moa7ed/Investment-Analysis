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
}

extension URLSession: HTTPClient {
    nonisolated func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}
