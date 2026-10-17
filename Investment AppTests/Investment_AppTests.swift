//
//  Investment_AppTests.swift
//  Investment AppTests
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//

import Foundation
import Testing
@testable import Investment_App

// Shared helpers for unit and functional tests. Everything runs offline: the store gets an isolated
// UserDefaults suite and a StubHTTPClient, so no test touches real data or the internet.

/// A fresh store with its own empty storage and stubbed network.
@MainActor
func makeStore(
    http: StubHTTPClient = StubHTTPClient(),
    apiKey: String? = "test-key",
    defaults: UserDefaults = makeDefaults()
) -> PortfolioStore {
    PortfolioStore(defaults: defaults, http: http, apiKeyProvider: { apiKey })
}

/// An empty, uniquely named UserDefaults suite.
func makeDefaults() -> UserDefaults {
    let name = "InvestmentAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// A statement entry as Claude returns it.
func entry(
    _ name: String,
    symbol: String? = nil,
    shares: Double = 1,
    value: Double? = nil,
    price: Double? = nil,
    currency: String? = "GBP",
    category: String? = "Stock",
    accountType: String? = "Invest",
    broker: String? = "Revolut",
    matchId: Int? = nil
) -> ParsedStatementEntry {
    ParsedStatementEntry(
        name: name, symbol: symbol, shares: shares, value: value, price: price, currencyCode: currency,
        category: category, accountType: accountType, broker: broker, matchId: matchId
    )
}

/// The JSON object Claude's structured output would contain for one statement entry.
func entryJSON(
    _ name: String,
    symbol: String? = nil,
    shares: Double = 1,
    value: Double? = nil,
    price: Double? = nil,
    currency: String = "GBP",
    category: String = "Stock",
    accountType: String? = "Invest",
    broker: String? = "Revolut",
    matchId: Int? = nil
) -> [String: Any] {
    [
        "name": name,
        "symbol": symbol ?? NSNull(),
        "shares": shares,
        "value": value ?? NSNull(),
        "price": price ?? NSNull(),
        "currencyCode": currency,
        "category": category,
        "accountType": accountType ?? NSNull(),
        "broker": broker ?? NSNull(),
        "matchId": matchId ?? NSNull()
    ]
}

/// A text statement source (content is irrelevant — Claude's reply is stubbed).
func textSource(_ name: String = "statement.csv") -> StatementSource {
    StatementSource(name: name, contentBlock: ["type": "text", "text": "stub statement"])
}

extension StubHTTPClient {
    /// Stubs Claude's statement-parsing reply.
    func claudeStatement(_ entries: [[String: Any]]) {
        claude { prompt in
            prompt.contains("Analyze this broker account statement")
                ? .json(StubHTTPClient.jsonString(["entries": entries]))
                : nil
        }
    }

    /// Stubs Claude's symbol-suggestion reply (number is the 1-based position among failed holdings).
    func claudeSuggestions(_ suggestions: [(number: Int, symbol: String?)]) {
        claude { prompt in
            prompt.contains("have no working Yahoo Finance symbol")
                ? .json(StubHTTPClient.jsonString(["suggestions": suggestions.map {
                    ["number": $0.number, "symbol": $0.symbol ?? NSNull()] as [String: Any]
                }]))
                : nil
        }
    }

    /// Stubs Claude's sector-classification reply.
    func claudeSectors(_ assignments: [(number: Int, sector: String)]) {
        claude { prompt in
            prompt.contains("sector categories")
                ? .json(StubHTTPClient.jsonString(["assignments": assignments.map { ["number": $0.number, "sector": $0.sector] }]))
                : nil
        }
    }

    /// Prompts of every Claude request sent so far.
    var claudePrompts: [String] {
        claudeRequests.map(StubHTTPClient.promptText(of:))
    }
}

extension PortfolioStore {
    func investment(named name: String) -> Investment? {
        investments.first { $0.name == name }
    }
}
