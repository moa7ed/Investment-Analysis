//
//  ClaudeTests.swift
//  Investment AppTests
//

import Foundation
import Testing
@testable import Investment_App

@MainActor
@Suite("Statement parsing via Claude")
struct StatementParsingTests {
    @Test("Parses entries and resolves Claude's matchId to the existing investment")
    func parsesAndResolvesMatch() async throws {
        let http = StubHTTPClient()
        http.claudeStatement([
            entryJSON("Alphabet Class C", symbol: "GOOG", shares: 4, matchId: 1),
            entryJSON("Tesla", symbol: "TSLA", shares: 2, matchId: 99) // out of range → ignored
        ])
        let store = makeStore(http: http)
        store.investments.append(Investment(name: "Alphabet", symbol: "GOOGL"))

        let entries = try await store.parseStatement(textSource()).get()
        #expect(entries.count == 2)
        #expect(entries[0].matchedInvestmentID == store.investment(named: "Alphabet")?.id)
        #expect(entries[1].matchedInvestmentID == nil)
    }

    @Test("The request carries the key, model and a JSON schema, without the obsolete PDF beta header")
    func requestShape() async throws {
        let http = StubHTTPClient()
        http.claudeStatement([])
        _ = await makeStore(http: http, apiKey: "secret-key").parseStatement(textSource())

        let request = try #require(http.claudeRequests.first)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
        let body = try #require(JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any])
        #expect(body["model"] as? String == "claude-opus-5")
        let format = (body["output_config"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
    }

    @Test("The prompt lists existing investments (not Cash) and remembered tickers")
    func promptContents() async throws {
        let http = StubHTTPClient()
        http.claudeStatement([])
        let store = makeStore(http: http)
        store.investments.append(Investment(name: "Alphabet", symbol: "GOOGL"))
        store.rememberTicker("SUI20947-USD", for: entry("Sui", symbol: "SUI-GBP", category: "Crypto"))

        _ = await store.parseStatement(textSource())
        let prompt = try #require(http.claudePrompts.first)
        #expect(prompt.contains("1. Alphabet (GOOGL)"))
        #expect(!prompt.contains("Cash (no symbol)"))
        #expect(prompt.contains("Sui (SUI-GBP) → SUI20947-USD"))
        #expect(prompt.contains("GC=F"), "Precious-metal guidance")
        #expect(prompt.contains("COIN-USD"), "Crypto guidance")
    }

    @Test("A remembered ticker is enforced even if Claude returns the old symbol")
    func enforcesRememberedTicker() async throws {
        let http = StubHTTPClient()
        http.claudeStatement([entryJSON("Sui", symbol: "SUI-GBP", category: "Crypto")])
        let store = makeStore(http: http)
        store.rememberTicker("SUI20947-USD", for: entry("Sui", symbol: "SUI-GBP", category: "Crypto"))

        let entries = try await store.parseStatement(textSource()).get()
        #expect(entries.first?.symbol == "SUI20947-USD")
    }

    @Test("Failures map to clear errors", arguments: [
        (StubHTTPClient.ClaudeReply.refusal, ClaudeFailure.refused),
        (.truncated, .failed),
        (.httpError(500), .failed),
        (.json("not json"), .failed)
    ])
    func failures(reply: StubHTTPClient.ClaudeReply, expected: ClaudeFailure) async {
        let http = StubHTTPClient()
        http.claude { _ in reply }
        let result = await makeStore(http: http).parseStatement(textSource())
        guard case .failure(let failure) = result else { Issue.record("Expected failure"); return }
        #expect(failure == expected)
    }

    @Test("No API key fails without any network request")
    func missingKey() async {
        let http = StubHTTPClient()
        let result = await makeStore(http: http, apiKey: nil).parseStatement(textSource())
        guard case .failure(.missingKey) = result else { Issue.record("Expected missingKey"); return }
        #expect(http.requests.isEmpty)
    }

    @Test("Offline fails cleanly")
    func offline() async {
        let result = await makeStore(http: StubHTTPClient()).parseStatement(textSource())
        guard case .failure(.failed) = result else { Issue.record("Expected failed"); return }
    }

    @Test("Every failure has a user-facing message")
    func messages() {
        for failure in [ClaudeFailure.missingKey, .refused, .failed] {
            #expect(!failure.message.isEmpty)
        }
    }
}

@MainActor
@Suite("Sector classification")
struct SectorClassificationTests {
    func storeWithHoldings(_ http: StubHTTPClient) -> PortfolioStore {
        let store = makeStore(http: http)
        // investments: 1 = Cash, 2 = Apple, 3 = Bitcoin
        store.investments += [Investment(name: "Apple", symbol: "AAPL"), Investment(name: "Bitcoin", symbol: "BTC-USD", category: "Crypto")]
        return store
    }

    @Test("Assigns sectors by list number; Cash always stays Cash")
    func assigns() async {
        let http = StubHTTPClient()
        http.claudeSectors([(1, "Tech"), (2, "Tech"), (3, "Crypto")])
        let store = storeWithHoldings(http)

        let failure = await store.classifySectors(forceAll: true)
        #expect(failure == nil)
        #expect(store.investment(named: "Apple")?.sector == "Tech")
        #expect(store.investment(named: "Bitcoin")?.sector == "Crypto")
        #expect(store.investment(named: "Cash")?.sector == "Cash")
    }

    @Test("A failed request leaves every sector unchanged (Issue 4)")
    func failureKeepsSectors() async {
        let http = StubHTTPClient()
        http.claude { _ in .httpError(503) }
        let store = storeWithHoldings(http)
        store.investments[1].sector = "Tech"
        store.investments[2].sector = "Crypto"

        let failure = await store.classifySectors(forceAll: true)
        #expect(failure == .failed)
        #expect(store.investment(named: "Apple")?.sector == "Tech")
        #expect(store.investment(named: "Bitcoin")?.sector == "Crypto")
    }

    @Test("Investments Claude leaves out keep their sector; unknown numbers are ignored")
    func partialReply() async {
        let http = StubHTTPClient()
        http.claudeSectors([(2, "Big Tech"), (42, "Nonsense")])
        let store = storeWithHoldings(http)
        store.investments[2].sector = "Crypto"

        _ = await store.classifySectors(forceAll: true)
        #expect(store.investment(named: "Apple")?.sector == "Big Tech")
        #expect(store.investment(named: "Bitcoin")?.sector == "Crypto")
    }

    @Test("Without forceAll, only unclassified investments change, and nothing is sent if all are classified")
    func onlyUnclassified() async {
        let http = StubHTTPClient()
        http.claudeSectors([(1, "X"), (2, "Tech"), (3, "Y")])
        let store = storeWithHoldings(http)
        store.investments[2].sector = "Crypto"

        _ = await store.classifySectors()
        #expect(store.investment(named: "Apple")?.sector == "Tech")
        #expect(store.investment(named: "Bitcoin")?.sector == "Crypto")

        let before = http.claudeRequests.count
        _ = await store.classifySectors()
        #expect(http.claudeRequests.count == before, "Everything classified — no request")
    }

    @Test("The max-sector limit and extra instructions reach the prompt")
    func promptOptions() async throws {
        let http = StubHTTPClient()
        http.claudeSectors([])
        _ = await storeWithHoldings(http).classifySectors(maxSectors: 4, additionalPrompt: "Separate semiconductors", forceAll: true)
        let prompt = try #require(http.claudePrompts.first)
        #expect(prompt.contains("maximum 4 sectors"))
        #expect(prompt.contains("Additional instructions: Separate semiconductors"))
    }
}

@MainActor
@Suite("Symbol suggestions via Claude")
struct SymbolSuggestionTests {
    @Test("One request for all failed holdings, grounded in Yahoo search candidates")
    func suggests() async throws {
        let http = StubHTTPClient()
        http.yahooSearch("Sui", results: [("SUI", "EQUITY", "Sun Communities, Inc."), ("SUI20947-USD", "CRYPTOCURRENCY", "Sui USD")])
        http.claudeSuggestions([(1, "SUI20947-USD"), (2, nil)])
        let store = makeStore(http: http)
        let sui = entry("Sui", symbol: "SUI-GBP", category: "Crypto")
        let mystery = entry("Mystery Fund", symbol: "MYST", category: "ETF")

        let suggestions = await store.suggestSymbols(for: [sui, mystery], failedSymbols: [sui.id: "SUI-GBP", mystery.id: "MYST"])
        #expect(suggestions == [sui.id: "SUI20947-USD"])
        #expect(http.claudeRequests.count == 1)
        let prompt = try #require(http.claudePrompts.first)
        #expect(prompt.contains("SUI20947-USD | CRYPTOCURRENCY | Sui USD"))
        #expect(prompt.contains("symbol that failed: SUI-GBP"))
    }

    @Test("Suggesting the symbol that already failed is ignored")
    func ignoresSameSymbol() async {
        let http = StubHTTPClient()
        http.claudeSuggestions([(1, "sui-gbp")])
        let sui = entry("Sui", symbol: "SUI-GBP", category: "Crypto")
        let suggestions = await makeStore(http: http).suggestSymbols(for: [sui], failedSymbols: [sui.id: "SUI-GBP"])
        #expect(suggestions.isEmpty)
    }

    @Test("No API key → no request and no suggestions")
    func noKey() async {
        let http = StubHTTPClient()
        let sui = entry("Sui", symbol: "SUI-GBP", category: "Crypto")
        let suggestions = await makeStore(http: http, apiKey: nil).suggestSymbols(for: [sui], failedSymbols: [sui.id: "SUI-GBP"])
        #expect(suggestions.isEmpty)
        #expect(http.requests.isEmpty)
    }
}
