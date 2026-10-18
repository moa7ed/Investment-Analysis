//
//  PricingTests.swift
//  Investment AppTests
//

import Foundation
import Testing
@testable import Investment_App

@MainActor
@Suite("Price refresh and exchange rates")
struct PriceRefreshTests {
    @Test("Refresh sets the market price and Yahoo's currency")
    func setsPrices() async throws {
        let http = StubHTTPClient()
        http.yahooQuote("AAPL", price: 200, currency: "USD")
        http.fxRate("USD", toGBP: 0.75)
        let store = makeStore(http: http)
        store.investments.append(Investment(name: "Apple", symbol: "AAPL", currencyCode: "GBP",
                                            holdings: [Holding(broker: "B", accountType: "ISA", shares: 10)]))

        await store.fetchAllPrices()

        let apple = try #require(store.investment(named: "Apple"))
        #expect(apple.apiPrice == 200)
        #expect(apple.currencyCode == "USD")
        #expect(store.priceStatus(for: apple) == .live)
        #expect(store.valueInGBP(for: apple) == 1500)
        #expect(store.hasFetchedOnce)
        #expect(!store.isLoading)
    }

    @Test("A currency introduced by the price fetch gets its rate in the same refresh (Issue 1)")
    func fetchesRateForNewCurrency() async {
        let http = StubHTTPClient()
        http.yahooQuote("AAPL", price: 200, currency: "USD")
        http.fxRate("USD", toGBP: 0.75)
        let store = makeStore(http: http)
        store.investments.append(Investment(name: "Apple", symbol: "AAPL", currencyCode: "GBP"))

        await store.fetchAllPrices()
        #expect(store.exchangeRates["USD"] == 0.75)
    }

    @Test("Known rates are refreshed on every refresh; GBP and GBX stay fixed")
    func refreshesRates() async {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.80)
        let store = makeStore(http: http)
        store.exchangeRates["USD"] = 0.70
        store.investments.append(Investment(name: "Fund", currencyCode: "USD", manualValue: 100))

        await store.fetchAllPrices()
        #expect(store.exchangeRates["USD"] == 0.80)
        #expect(store.exchangeRates["GBP"] == 1.0)
        #expect(store.exchangeRates["GBX"] == 0.01)
        #expect(!http.requests.contains { $0.url?.path.contains("GBPGBP") == true })
    }

    @Test("A failed lookup marks the investment as having no live price")
    func failedLookup() async throws {
        let store = makeStore()
        var stale = Investment(name: "Sui", symbol: "SUI-GBP", category: "Crypto")
        stale.apiPrice = 1 // from an earlier refresh
        store.investments.append(stale)

        await store.fetchAllPrices()
        #expect(store.priceStatus(for: try #require(store.investment(named: "Sui"))) == .noLivePrice)
    }

    @Test("A manually priced investment keeps its currency when Yahoo reports another")
    func manualPriceKeepsCurrency() async throws {
        let http = StubHTTPClient()
        http.yahooQuote("GC=F", price: 4200, currency: "USD", type: "FUTURE")
        let store = makeStore(http: http)
        var gold = Investment(name: "Gold", symbol: "GC=F", category: "Commodity", currencyCode: "GBP")
        gold.manualPrice = 3133
        store.investments.append(gold)

        await store.fetchAllPrices()
        let refreshed = try #require(store.investment(named: "Gold"))
        #expect(refreshed.currencyCode == "GBP")
        #expect(refreshed.effectivePrice == 3133)
    }

    @Test("Bare symbols retry common exchange suffixes")
    func suffixRetry() async throws {
        let http = StubHTTPClient()
        http.yahooQuote("VUSA.L", price: 9000, currency: "GBp", type: "ETF")
        let store = makeStore(http: http)
        store.investments.append(Investment(name: "Vanguard", symbol: "VUSA", category: "ETF"))

        await store.fetchAllPrices()
        let vusa = try #require(store.investment(named: "Vanguard"))
        #expect(vusa.apiPrice == 9000)
        #expect(vusa.currencyCode == "GBX", "Yahoo's GBp is normalized to GBX")
    }

    @Test("ensureExchangeRates fetches only missing rates and reports any still missing")
    func ensureRates() async {
        let http = StubHTTPClient()
        http.fxRate("EUR", toGBP: 0.85)
        let store = makeStore(http: http)

        let missing = await store.ensureExchangeRates(for: ["EUR", "CHF", "GBP"])
        #expect(missing == ["CHF"])
        #expect(store.exchangeRates["EUR"] == 0.85)
    }
}

@MainActor
@Suite("Symbol validation")
struct SymbolValidationTests {
    func stubbedStore() -> PortfolioStore {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("SUI", price: 118, currency: "USD", type: "EQUITY", name: "Sun Communities, Inc.")
        http.yahooQuote("SUI20947-USD", price: 1.0, currency: "USD", type: "CRYPTOCURRENCY", name: "Sui USD")
        http.yahooQuote("GC=F", price: 4181, currency: "USD", type: "FUTURE", name: "Gold Dec 26")
        http.yahooQuote("SGLN.L", price: 6141, currency: "GBp", type: "EQUITY", name: "iShares Physical Gold ETC")
        return makeStore(http: http)
    }

    let sui = entry("Sui", symbol: "SUI-GBP", shares: 1000, value: 750, category: "Crypto")
    let gold = entry("Gold", shares: 3.514292, value: 11010.64, category: "Commodity")

    @Test("No Yahoo price → noPrice")
    func noPrice() async {
        #expect(await stubbedStore().validateSymbol("SUI-GBP", for: sui).isValid == false)
        guard case .noPrice = await stubbedStore().validateSymbol("SUI-GBP", for: sui) else {
            Issue.record("Expected noPrice"); return
        }
    }

    @Test("A stock with the coin's ticker is rejected for a crypto holding")
    func typeMismatch() async {
        guard case .typeMismatch(let quote) = await stubbedStore().validateSymbol("SUI", for: sui) else {
            Issue.record("Expected typeMismatch"); return
        }
        #expect(quote.name == "Sun Communities, Inc.")
    }

    @Test("The right instrument within ±25% of the statement is valid")
    func valid() async {
        #expect(await stubbedStore().validateSymbol("SUI20947-USD", for: sui).isValid)
        #expect(await stubbedStore().validateSymbol("GC=F", for: gold).isValid, "Futures are ~2% above spot — allowed")
    }

    @Test("A price far from the statement's is rejected (e.g. a gold ETC unit vs an ounce)")
    func priceMismatch() async {
        guard case .priceMismatch(_, let yahooGBP, let statementGBP) = await stubbedStore().validateSymbol("SGLN.L", for: gold) else {
            Issue.record("Expected priceMismatch"); return
        }
        #expect(abs(yahooGBP - 61.41) < 0.01)
        #expect(abs(statementGBP - 3133.10) < 0.01)
    }

    @Test("Without a statement price, only price and type are checked")
    func noStatementPrice() async {
        let noValue = entry("Sui", symbol: "SUI-GBP", category: "Crypto")
        #expect(await stubbedStore().validateSymbol("SUI20947-USD", for: noValue).isValid)
    }

    @Test("Instrument descriptions used in messages")
    func describe() {
        #expect(PortfolioStore.describe(instrumentType: "EQUITY") == "a stock")
        #expect(PortfolioStore.describe(instrumentType: "CRYPTOCURRENCY") == "a cryptocurrency")
        #expect(PortfolioStore.describe(instrumentType: nil) == "a different instrument")
    }

    @Test("Yahoo search results are parsed")
    func search() async {
        let http = StubHTTPClient()
        http.yahooSearch("Sui", results: [("SUI20947-USD", "CRYPTOCURRENCY", "Sui USD")])
        let results = await makeStore(http: http).searchYahoo("sui")
        #expect(results.map(\.symbol) == ["SUI20947-USD"])
        #expect(results.first?.quoteType == "CRYPTOCURRENCY")
        #expect(results.first?.displayName == "Sui USD")
    }
}
