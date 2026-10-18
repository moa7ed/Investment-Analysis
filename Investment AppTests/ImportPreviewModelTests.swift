//
//  ImportPreviewModelTests.swift
//  Investment AppTests
//

import Foundation
import Testing
@testable import Investment_App

@MainActor
@Suite("Import preview: broker, account type and matching")
struct ImportPreviewBasicsTests {
    @Test("The detected broker is pre-filled; without one, Apply is blocked")
    func broker() {
        let store = makeStore()
        let detected = ImportPreviewModel(entries: [entry("Cash", value: 10, category: "Cash", broker: "Revolut")], store: store)
        #expect(detected.brokerText == "Revolut")
        #expect(detected.brokerWasDetected)
        #expect(detected.canApply, "Cash needs no price check")

        let missing = ImportPreviewModel(entries: [entry("Cash", value: 10, category: "Cash", broker: nil)], store: store)
        #expect(missing.brokerText.isEmpty)
        #expect(!missing.canApply)
        missing.brokerText = "  Revolut "
        #expect(missing.canApply)
        #expect(missing.effectiveEntries.first?.broker == "Revolut", "Trimmed and applied to every entry")
    }

    @Test("Forcing an account type applies it to every entry, cash included")
    func accountTypeOverride() {
        let model = ImportPreviewModel(entries: [
            entry("Apple", symbol: "AAPL", accountType: "Invest"),
            entry("Cash", value: 100, category: "Cash", accountType: "Invest")
        ], store: makeStore())
        #expect(model.accountTypes == ["Invest"])
        model.accountTypeOverride = "ISA"
        #expect(model.effectiveEntries.allSatisfy { $0.accountType == "ISA" })
        #expect(model.accountTypes == ["ISA"])
        #expect(model.displayEntries.first { $0.isCash }?.accountType == "ISA")
    }

    @Test("Account type options include ISA, Invest, General and types already used, without duplicates")
    func accountTypeOptions() {
        let store = makeStore()
        store.investments.append(Investment(name: "Pension", holdings: [
            Holding(broker: "AJ Bell", accountType: "SIPP", shares: 1),
            Holding(broker: "Old", accountType: "general", shares: 1)
        ]))
        #expect(ImportPreviewModel(entries: [], store: store).accountTypeOptions == ["ISA", "Invest", "General", "SIPP"])
    }

    @Test("Cash rows are consolidated per broker and account type, like Apply")
    func displayCash() {
        let model = ImportPreviewModel(entries: [
            entry("Cash", value: 100, category: "Cash", accountType: "ISA"),
            entry("Cash", value: 50, category: "Cash", accountType: "ISA"),
            entry("Apple", symbol: "AAPL")
        ], store: makeStore())
        #expect(model.displayEntries.count == 2)
        #expect(model.displayEntries.first { $0.isCash }?.value == 150)
    }

    @Test("Overriding a match updates counts; choosing New forces a new investment")
    func matchOverride() throws {
        let store = makeStore()
        store.investments.append(Investment(name: "Apple", symbol: "AAPL"))
        let model = ImportPreviewModel(entries: [entry("Apple", symbol: "AAPL")], store: store)
        let id = try #require(model.entries.first?.id)

        #expect(model.matchedInvestmentID(forEntry: id) == store.investment(named: "Apple")?.id)
        #expect(model.matchedCount == 1)
        #expect(model.newCount == 0)

        model.setMatch(forEntry: id, to: nil)
        #expect(model.matchedInvestmentID(forEntry: id) == nil)
        #expect(model.newCount == 1)
        #expect(model.matchCandidates.map(\.name) == ["Apple"], "Cash is never a candidate")
    }

    @Test("Change descriptions for new holdings, share updates and cash")
    func changes() throws {
        let store = makeStore()
        var apple = Investment(name: "Apple", symbol: "AAPL", holdings: [Holding(broker: "Revolut", accountType: "ISA", shares: 10)])
        apple.apiPrice = 1
        store.investments.append(apple)
        let model = ImportPreviewModel(entries: [], store: store)

        let update = model.computeChanges(entry: entry("Apple", shares: 12, accountType: "ISA"), existing: apple)
        #expect(update.changes == ["Shares (Revolut ISA): 10 → 12"])
        let same = model.computeChanges(entry: entry("Apple", shares: 10, accountType: "ISA"), existing: apple)
        #expect(same.changes.isEmpty)
        let added = model.computeChanges(entry: entry("Apple", shares: 5, accountType: "Invest"), existing: apple)
        #expect(added.changes.first?.hasPrefix("Add holding: Revolut · Invest") == true)
        let cash = model.computeChanges(entry: entry("Cash", shares: 300, value: 300, category: "Cash", accountType: "ISA"),
                                        existing: try #require(store.investment(named: "Cash")))
        #expect(cash.changes.first?.hasPrefix("Add cash: Revolut · ISA") == true)
    }
}

@MainActor
@Suite("Import preview: automatic symbol pipeline")
struct ImportPreviewPipelineTests {
    /// Yahoo prices AAPL and SUI20947-USD; SUI-GBP has no price; SUI is a stock.
    func stub() -> StubHTTPClient {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("AAPL", price: 200, currency: "USD", type: "EQUITY", name: "Apple Inc.")
        http.yahooQuote("SUI20947-USD", price: 1.0, currency: "USD", type: "CRYPTOCURRENCY", name: "Sui USD")
        http.yahooQuote("SUI", price: 118, currency: "USD", type: "EQUITY", name: "Sun Communities, Inc.")
        http.yahooSearch("Sui", results: [("SUI20947-USD", "CRYPTOCURRENCY", "Sui USD")])
        return http
    }

    let apple = entry("Apple", symbol: "AAPL", shares: 10, value: 1500)
    let sui = entry("Sui", symbol: "SUI-GBP", shares: 1000, value: 750, category: "Crypto")

    @Test("A valid symbol is OK without asking Claude")
    func validSymbol() async {
        let http = stub()
        let model = ImportPreviewModel(entries: [apple], store: makeStore(http: http))
        #expect(model.priceCheck(for: apple) == .checking)
        #expect(!model.canApply, "Blocked while checking")

        await model.runSymbolChecks()
        #expect(model.priceCheck(for: apple) == .ok)
        #expect(model.canApply)
        #expect(http.claudeRequests.isEmpty)
        #expect(model.pendingCheckKey.isEmpty)
    }

    @Test("A failing symbol is corrected by Claude and validated on Yahoo")
    func correctedByClaude() async {
        let http = stub()
        http.claudeSuggestions([(1, "SUI20947-USD")])
        let store = makeStore(http: http)
        let model = ImportPreviewModel(entries: [apple, sui], store: store)

        await model.runSymbolChecks()
        #expect(model.priceCheck(for: apple) == .ok)
        #expect(model.priceCheck(for: sui) == .corrected(symbol: "SUI20947-USD", name: "Sui USD"))
        #expect(model.canApply)
        #expect(http.claudeRequests.count == 1, "One request for all failures")

        let applied = model.entriesForApply()
        let appliedSui = applied.first { $0.name == "Sui" }
        #expect(appliedSui?.symbol == "SUI20947-USD")
        #expect(appliedSui?.symbolConfirmedByUser == true)
        #expect(store.tickerOverrides.values.map(\.ticker) == ["SUI20947-USD"], "Remembered for future imports")
    }

    @Test("Claude's suggestion is rejected if it's the wrong type, leaving the manual options")
    func suggestionRejected() async {
        let http = stub()
        http.claudeSuggestions([(1, "SUI")])
        let model = ImportPreviewModel(entries: [sui], store: makeStore(http: http))

        await model.runSymbolChecks()
        guard case .missing(let reason) = model.priceCheck(for: sui) else { Issue.record("Expected missing"); return }
        #expect(reason.contains("Claude suggested SUI"))
        #expect(reason.contains("Sun Communities"))
        #expect(!model.canApply)
    }

    @Test("No suggestion from Claude leaves the manual options")
    func noSuggestion() async {
        let http = stub()
        http.claudeSuggestions([(1, nil)])
        let model = ImportPreviewModel(entries: [sui], store: makeStore(http: http))
        await model.runSymbolChecks()
        guard case .missing(let reason) = model.priceCheck(for: sui) else { Issue.record("Expected missing"); return }
        #expect(reason.contains("couldn't find a working symbol"))
    }

    @Test("Undo turns a correction back into the manual options")
    func undo() async {
        let http = stub()
        http.claudeSuggestions([(1, "SUI20947-USD")])
        let model = ImportPreviewModel(entries: [sui], store: makeStore(http: http))
        await model.runSymbolChecks()

        model.undoCorrection(forEntry: sui.id)
        guard case .missing = model.priceCheck(for: sui) else { Issue.record("Expected missing"); return }
        #expect(!model.canApply)
        #expect(model.entriesForApply().first?.symbol == "SUI-GBP", "Undone correction isn't applied")
    }

    @Test("Matched investments that already have a live or manual price skip the check")
    func matchedSkipsCheck() {
        let store = makeStore()
        var live = Investment(name: "Apple", symbol: "AAPL")
        live.apiPrice = 200
        var manual = Investment(name: "Gold", category: "Commodity")
        manual.manualPrice = 3000
        store.investments += [live, manual]
        let model = ImportPreviewModel(entries: [entry("Apple", symbol: "AAPL"), entry("Gold", category: "Commodity")], store: store)

        #expect(model.priceCheck(for: model.entries[0]) == .ok)
        #expect(model.priceCheck(for: model.entries[1]) == .notNeeded)
        #expect(model.pendingCheckKey.isEmpty)
    }

    @Test("Changing the match re-checks against the new pricing symbol")
    func staleCheckAfterMatchChange() async throws {
        let http = stub()
        let store = makeStore(http: http)
        store.investments.append(Investment(name: "Apple Inc", symbol: "AAPL"))
        let model = ImportPreviewModel(entries: [entry("Something", symbol: "NOPE")], store: store)
        let id = try #require(model.entries.first?.id)
        await model.runSymbolChecks()
        guard case .missing = model.priceCheck(for: model.entries[0]) else { Issue.record("Expected missing"); return }

        model.setMatch(forEntry: id, to: store.investment(named: "Apple Inc")?.id)
        #expect(model.priceCheck(for: model.entries[0]) == .checking, "Old result is stale")
        await model.runSymbolChecks()
        #expect(model.priceCheck(for: model.entries[0]) == .ok)
    }
}

@MainActor
@Suite("Import preview: manual price resolution")
struct ImportPreviewResolutionTests {
    let gold = entry("Gold", shares: 4, value: 12000, category: "Commodity")

    func unpricedModel() async -> ImportPreviewModel {
        let model = ImportPreviewModel(entries: [gold], store: makeStore())
        await model.runSymbolChecks() // offline: no symbol → missing; no API key needed
        return model
    }

    @Test("Without a choice, Apply is blocked")
    func blocked() async {
        let model = await unpricedModel()
        guard case .missing = model.priceCheck(for: gold) else { Issue.record("Expected missing"); return }
        #expect(!model.canApply)
    }

    @Test("Enter a price")
    func manualPrice() async {
        let model = await unpricedModel()
        model.priceResolutions[gold.id] = PriceResolution(mode: .manualPrice, priceText: "abc")
        #expect(!model.canApply, "Invalid number")
        model.priceResolutions[gold.id]?.priceText = NumberText.format(3100)
        #expect(model.canApply)
        #expect(model.entriesForApply().first?.manualPrice == 3100)
    }

    @Test("Value ÷ units")
    func fromValue() async {
        let model = await unpricedModel()
        #expect(model.valuePerUnit(for: gold) == 3000)
        model.priceResolutions[gold.id] = PriceResolution(mode: .fromValue)
        #expect(model.canApply)
        #expect(model.entriesForApply().first?.manualPrice == 3000)
    }

    @Test("Value ÷ units is unavailable without a value")
    func noValue() {
        let model = ImportPreviewModel(entries: [], store: makeStore())
        #expect(model.valuePerUnit(for: entry("X", shares: 5)) == nil)
        #expect(model.valuePerUnit(for: entry("X", shares: 0, value: 10)) == nil)
    }

    @Test("Enter a ticker: validated, applied and remembered")
    func ticker() async {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("GC=F", price: 4000, currency: "USD", type: "FUTURE")
        let store = makeStore(http: http)
        let model = ImportPreviewModel(entries: [gold], store: store)
        await model.runSymbolChecks()

        model.priceResolutions[gold.id] = PriceResolution(mode: .ticker, tickerText: " gc=f ")
        await model.checkTicker(for: gold)
        #expect(model.priceResolutions[gold.id]?.verifiedTicker == "GC=F")
        #expect(model.canApply)

        let applied = model.entriesForApply().first
        #expect(applied?.symbol == "GC=F")
        #expect(applied?.symbolConfirmedByUser == true)
        #expect(store.tickerOverrides.values.map(\.ticker) == ["GC=F"])
    }

    @Test("Editing a verified ticker requires checking again")
    func editInvalidatesTicker() async {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("GC=F", price: 4000, currency: "USD", type: "FUTURE")
        let model = ImportPreviewModel(entries: [gold], store: makeStore(http: http))
        await model.runSymbolChecks()
        model.priceResolutions[gold.id] = PriceResolution(mode: .ticker, tickerText: "GC=F")
        await model.checkTicker(for: gold)
        model.priceResolutions[gold.id]?.tickerText = "SI=F"
        #expect(!model.canApply)
    }

    @Test("A wrong-type ticker shows why; a price-range mismatch can be used anyway")
    func tickerErrors() async {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("BTC-USD", price: 60000, currency: "USD", type: "CRYPTOCURRENCY", name: "Bitcoin USD")
        http.yahooQuote("SGLN.L", price: 6141, currency: "GBp", type: "EQUITY", name: "iShares Physical Gold ETC")
        let model = ImportPreviewModel(entries: [gold], store: makeStore(http: http))
        await model.runSymbolChecks()

        model.priceResolutions[gold.id] = PriceResolution(mode: .ticker, tickerText: "BTC-USD")
        await model.checkTicker(for: gold)
        #expect(model.priceResolutions[gold.id]?.tickerError?.contains("a cryptocurrency") == true)
        #expect(model.priceResolutions[gold.id]?.priceMismatchTicker == nil)
        model.useTickerAnyway(forEntry: gold.id)
        #expect(!model.canApply, "Type mismatches can't be overridden")

        model.priceResolutions[gold.id]?.tickerText = "SGLN.L"
        await model.checkTicker(for: gold)
        #expect(model.priceResolutions[gold.id]?.tickerError?.contains("trades at") == true)
        #expect(!model.canApply)
        model.useTickerAnyway(forEntry: gold.id)
        #expect(model.canApply)
        #expect(model.entriesForApply().first?.symbol == "SGLN.L")
    }

    @Test("Apply writes the resolved statement into the portfolio")
    func apply() async throws {
        let store = makeStore()
        let model = ImportPreviewModel(entries: [gold], store: store)
        await model.runSymbolChecks()
        model.priceResolutions[gold.id] = PriceResolution(mode: .fromValue)

        model.apply()
        let saved = try #require(store.investment(named: "Gold"))
        #expect(saved.manualPrice == 3000)
        #expect(saved.totalValue == 12000)
        #expect(store.priceStatus(for: saved) == .manual)
    }
}

@MainActor
@Suite("Validation messages")
struct ValidationMessageTests {
    @Test("Each failure explains itself")
    func messages() {
        let quote = YahooQuote(price: 118, currency: "USD", instrumentType: "EQUITY", name: "Sun Communities, Inc.")
        #expect(ImportPreviewModel.validationMessage(.noPrice, symbol: "X").contains("no price for X"))
        #expect(ImportPreviewModel.validationMessage(.typeMismatch(quote), symbol: "SUI").contains("Sun Communities, Inc. (a stock)"))
        #expect(ImportPreviewModel.validationMessage(.priceMismatch(quote, yahooGBP: 60, statementGBP: 3000), symbol: "SGLN.L").contains("trades at"))
    }
}
