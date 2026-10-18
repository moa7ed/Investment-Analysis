//
//  ImportFlowIntegrationTests.swift
//  Investment AppTests
//
//  Functional tests: complete user flows through the real store, Claude client, Yahoo client and
//  preview model — only the network is stubbed (offline).
//

import Foundation
import Testing
@testable import Investment_App

@MainActor
@Suite("Functional: statement import flows")
struct ImportFlowIntegrationTests {
    /// Parses a statement, runs the preview's checks, and returns the preview ready for the user's choices.
    func preview(_ store: PortfolioStore, source: StatementSource = textSource()) async throws -> ImportPreviewModel {
        let entries = try await store.parseStatement(source).get()
        let model = ImportPreviewModel(entries: entries, store: store, sourceLabel: source.name)
        await model.runSymbolChecks()
        return model
    }

    @Test("Import → preview → apply → refresh produces correct holdings, prices, totals and sectors")
    func fullImport() async throws {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("AAPL", price: 200, currency: "USD", type: "EQUITY", name: "Apple Inc.")
        http.claudeStatement([
            entryJSON("Apple", symbol: "AAPL", shares: 10, value: 1500, broker: nil),
            entryJSON("Cash", shares: 500, value: 500, category: "Cash", broker: nil)
        ])
        http.claudeSectors([(1, "Cash"), (2, "Tech")])
        let store = makeStore(http: http)

        let model = try await preview(store)
        #expect(!model.canApply, "No broker on the statement")
        model.brokerText = "Trading 212"
        #expect(model.canApply)
        #expect(model.newCount == 1)
        #expect(model.matchedCount == 1, "Cash matches the Cash investment")

        model.apply()
        await store.fetchAllPrices()

        let apple = try #require(store.investment(named: "Apple"))
        #expect(apple.holdings == [Holding(broker: "Trading 212", accountType: "Invest", shares: 10)])
        #expect(apple.apiPrice == 200)
        #expect(apple.currencyCode == "USD")
        #expect(apple.sector == "Tech")
        #expect(store.valueInGBP(for: apple) == 1500)
        #expect(store.investment(named: "Cash")?.holdings == [Holding(broker: "Trading 212", accountType: "Invest", shares: 500)])
        #expect(store.totalPortfolioValue == 2000)
        #expect(store.currentPercentage(for: apple) == 75)
    }

    @Test("Sui: Claude corrects SUI-GBP to SUI20947-USD, and the next import reuses it without asking Claude")
    func suiCorrectionIsRemembered() async throws {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("SUI20947-USD", price: 1.0, currency: "USD", type: "CRYPTOCURRENCY", name: "Sui USD")
        http.yahooQuote("SUI", price: 118, currency: "USD", type: "EQUITY", name: "Sun Communities, Inc.")
        http.yahooSearch("Sui", results: [("SUI", "EQUITY", "Sun Communities, Inc."), ("SUI20947-USD", "CRYPTOCURRENCY", "Sui USD")])
        http.claudeSuggestions([(1, "SUI20947-USD")])
        http.claudeStatement([entryJSON("Sui", symbol: "SUI-GBP", shares: 1000, value: 750, category: "Crypto")])
        let store = makeStore(http: http)

        // First import: corrected automatically
        let first = try await preview(store)
        let sui = try #require(first.entries.first)
        #expect(first.priceCheck(for: sui) == .corrected(symbol: "SUI20947-USD", name: "Sui USD"))
        first.apply()
        await store.fetchAllPrices()

        let saved = try #require(store.investment(named: "Sui"))
        #expect(saved.symbol == "SUI20947-USD")
        #expect(store.priceStatus(for: saved) == .live)
        #expect(store.valueInGBP(for: saved) == 750)

        // Second import of an updated statement (Claude still says SUI-GBP)
        http.claudeStatement([entryJSON("Sui", symbol: "SUI-GBP", shares: 1200, value: 900, category: "Crypto")])
        let suggestionRequestsBefore = http.claudePrompts.filter { $0.contains("have no working Yahoo Finance symbol") }.count
        let second = try await preview(store)
        #expect(second.entries.first?.symbol == "SUI20947-USD", "Remembered ticker enforced")
        #expect(second.priceCheck(for: try #require(second.entries.first)) == .ok)
        #expect(http.claudePrompts.filter { $0.contains("have no working Yahoo Finance symbol") }.count == suggestionRequestsBefore)

        second.apply()
        #expect(store.investments.filter { $0.name == "Sui" }.count == 1)
        #expect(store.investment(named: "Sui")?.totalShares == 1200)
    }

    @Test("Gold held as ounces: no ticker on the statement, Claude picks GC=F, price check passes")
    func goldOunces() async throws {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("GC=F", price: 4181, currency: "USD", type: "FUTURE", name: "Gold Dec 26")
        http.yahooSearch("Gold", results: [("GC=F", "FUTURE", "Gold Dec 26"), ("XAUT-USD", "CRYPTOCURRENCY", "Tether Gold USD")])
        http.claudeSuggestions([(1, "GC=F")])
        http.claudeStatement([entryJSON("Gold", shares: 3.514292, value: 11010.64, category: "Commodity")])
        let store = makeStore(http: http)

        let model = try await preview(store)
        #expect(model.priceCheck(for: try #require(model.entries.first)) == .corrected(symbol: "GC=F", name: "Gold Dec 26"))
        model.apply()
        await store.fetchAllPrices()

        let gold = try #require(store.investment(named: "Gold"))
        #expect(abs(store.valueInGBP(for: gold) - 3.514292 * 4181 * 0.75) < 0.01)
    }

    @Test("An old statement priced far from today: the user keeps the right ticker with 'Use anyway'")
    func staleStatement() async throws {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("NVDA", price: 200, currency: "USD", type: "EQUITY", name: "NVIDIA")
        http.claudeSuggestions([(1, "NVDA")]) // same as the failed symbol → ignored
        http.claudeStatement([entryJSON("NVIDIA", symbol: "NVDA", shares: 10, value: 500)]) // £50/share, now £150
        let store = makeStore(http: http)

        let model = try await preview(store)
        let nvidia = try #require(model.entries.first)
        guard case .missing = model.priceCheck(for: nvidia) else { Issue.record("Expected manual options"); return }

        model.priceResolutions[nvidia.id] = PriceResolution(mode: .ticker, tickerText: "NVDA")
        await model.checkTicker(for: nvidia)
        model.useTickerAnyway(forEntry: nvidia.id)
        #expect(model.canApply)

        model.apply()
        await store.fetchAllPrices()
        #expect(store.valueInGBP(for: try #require(store.investment(named: "NVIDIA"))) == 1500)
    }

    @Test("Revolut Invest then ISA: one investment per stock, cash kept separate per account")
    func investThenISA() async throws {
        let http = StubHTTPClient()
        http.yahooQuote("VUSA.L", price: 9000, currency: "GBp", type: "ETF")
        let store = makeStore(http: http)

        http.claudeStatement([
            entryJSON("Vanguard S&P 500", symbol: "VUSA.L", shares: 10, value: 900, category: "ETF", accountType: "Invest"),
            entryJSON("Cash", shares: 120, value: 120, category: "Cash", accountType: "Invest")
        ])
        try await preview(store).apply()

        http.claudeStatement([
            entryJSON("Vanguard S&P 500", symbol: "VUSA.L", shares: 4, value: 360, category: "ETF", accountType: "ISA", matchId: 1),
            entryJSON("Cash", shares: 80, value: 80, category: "Cash", accountType: "ISA")
        ])
        let isaPreview = try await preview(store)
        #expect(isaPreview.displayEntries.first { $0.isCash }.map { isaPreview.computeChanges(entry: $0, existing: store.investment(named: "Cash")!) }?
            .changes.first?.hasPrefix("Add cash: Revolut · ISA") == true, "ISA cash is added, not overwriting Invest cash")
        isaPreview.apply()
        await store.fetchAllPrices()

        let vusa = try #require(store.investment(named: "Vanguard S&P 500"))
        #expect(store.investments.filter { $0.symbol == "VUSA.L" }.count == 1)
        #expect(vusa.totalShares == 14)
        let cash = try #require(store.investment(named: "Cash"))
        #expect(cash.holdings.first { $0.accountType == "Invest" }?.shares == 120)
        #expect(cash.holdings.first { $0.accountType == "ISA" }?.shares == 80)
        #expect(store.totalPortfolioValue == 14 * 90 + 200)
    }

    @Test("Foreign-currency cash uses the rate fetched before the preview (Issue 2)")
    func foreignCash() async throws {
        let http = StubHTTPClient()
        http.fxRate("EUR", toGBP: 0.85)
        http.claudeStatement([entryJSON("Cash", shares: 1000, value: 1000, currency: "EUR", category: "Cash")])
        let store = makeStore(http: http)

        let entries = try await store.parseStatement(textSource()).get()
        #expect(await store.ensureExchangeRates(for: ["EUR"]).isEmpty)
        let model = ImportPreviewModel(entries: entries, store: store)
        #expect(model.displayEntries.first?.value == 850)
        model.apply()
        #expect(store.investment(named: "Cash")?.holdings.first?.shares == 850)
    }

    @Test("Everything imported survives a relaunch, including remembered tickers")
    func survivesRelaunch() async throws {
        let defaults = makeDefaults()
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("SUI20947-USD", price: 1.0, currency: "USD", type: "CRYPTOCURRENCY", name: "Sui USD")
        http.claudeSuggestions([(1, "SUI20947-USD")])
        http.claudeStatement([entryJSON("Sui", symbol: "SUI-GBP", shares: 1000, value: 750, category: "Crypto")])
        let store = makeStore(http: http, defaults: defaults)
        try await preview(store).apply()

        let relaunched = makeStore(http: http, defaults: defaults)
        #expect(relaunched.investment(named: "Sui")?.symbol == "SUI20947-USD")
        #expect(relaunched.tickerOverrides.values.map(\.ticker) == ["SUI20947-USD"])
    }

    @Test("A failed reclassification keeps the user's sectors end to end")
    func reclassifyFailure() async throws {
        let http = StubHTTPClient()
        http.claudeStatement([entryJSON("Apple", symbol: "AAPL", shares: 1)])
        let store = makeStore(http: http)
        try await preview(store).apply()
        var apple = try #require(store.investment(named: "Apple"))
        apple.sector = "My Tech"
        store.updateInvestment(apple)

        http.claude { prompt in prompt.contains("sector categories") ? .refusal : nil }
        #expect(await store.classifySectors(forceAll: true) == .refused)
        #expect(store.investment(named: "Apple")?.sector == "My Tech")
    }
}
