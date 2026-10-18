//
//  PortfolioStoreTests.swift
//  Investment AppTests
//

import Foundation
import Testing
@testable import Investment_App

@MainActor
@Suite("Portfolio values")
struct PortfolioValueTests {
    @Test("A new store starts with only the protected Cash investment")
    func startsWithCash() {
        let store = makeStore()
        #expect(store.investments.map(\.name) == ["Cash"])
        #expect(store.investments.first?.sector == "Cash")
        #expect(!store.canDelete(store.investments[0]))
    }

    @Test("Values convert to GBP with exchange rates; missing rates count as 1.0")
    func valueInGBP() {
        let store = makeStore()
        store.exchangeRates["USD"] = 0.75
        var usd = Investment(name: "Apple", currencyCode: "USD", holdings: [Holding(broker: "B", accountType: "ISA", shares: 10)])
        usd.apiPrice = 200
        var gbx = Investment(name: "BP", currencyCode: "GBX", holdings: [Holding(broker: "B", accountType: "ISA", shares: 100)])
        gbx.apiPrice = 450
        #expect(store.valueInGBP(for: usd) == 1500)
        #expect(store.valueInGBP(for: gbx) == 450, "GBX is pence")

        var unknown = usd
        unknown.currencyCode = "JPY"
        #expect(store.valueInGBP(for: unknown) == 2000, "Unknown currency falls back to 1.0")
    }

    @Test("Percentages and sector totals")
    func percentagesAndSectors() {
        let store = makeStore()
        store.investments = [
            Investment(name: "A", targetPercentage: 60, currencyCode: "GBP", manualValue: 300),
            Investment(name: "B", targetPercentage: 40, currencyCode: "GBP", manualValue: 100)
        ]
        store.investments[0].sector = "Tech"
        store.investments[1].sector = "Tech"

        #expect(store.totalPortfolioValue == 400)
        #expect(store.currentPercentage(for: store.investments[0]) == 75)
        #expect(store.sectorValue("Tech") == 400)
        #expect(store.sectorCurrentPercentage("Tech") == 100)
        #expect(store.sectorTargetPercentage("Tech") == 100)
        #expect(store.knownSectors == ["Tech"])
        #expect(store.investmentsBySector.map(\.sector) == ["Tech"])
    }

    @Test("Empty portfolio has 0% for everything")
    func emptyPortfolio() {
        let store = makeStore()
        #expect(store.totalPortfolioValue == 0)
        #expect(store.currentPercentage(for: store.investments[0]) == 0)
    }
}

@MainActor
@Suite("Statement matching")
struct MatchingTests {
    func storeWithInvestments() -> PortfolioStore {
        let store = makeStore()
        store.investments += [
            Investment(name: "Alphabet", symbol: "GOOGL"),
            Investment(name: "Vanguard S&P 500", symbol: "VUSA.L", category: "ETF"),
            Investment(name: "BP", symbol: "BP")
        ]
        return store
    }

    @Test("Cash entries always match the Cash investment")
    func cash() {
        let store = storeWithInvestments()
        #expect(store.matchingInvestment(for: entry("Cash", category: "Cash"))?.name == "Cash")
    }

    @Test("Claude's match wins over symbol and name")
    func claudeMatch() {
        let store = storeWithInvestments()
        var e = entry("Google Class C", symbol: "GOOG")
        e.matchedInvestmentID = store.investment(named: "Alphabet")?.id
        #expect(store.matchingInvestment(for: e)?.name == "Alphabet")
    }

    @Test("Exact symbol, then base symbol across exchanges, then normalized name")
    func fallbacks() {
        let store = storeWithInvestments()
        #expect(store.matchingInvestment(for: entry("X", symbol: "googl"))?.name == "Alphabet", "Exact, case-insensitive")
        #expect(store.matchingInvestment(for: entry("X", symbol: "VUSA.AS"))?.name == "Vanguard S&P 500", "Same base, other exchange")
        #expect(store.matchingInvestment(for: entry("vanguard s & p 500!"))?.name == "Vanguard S&P 500", "Normalized name")
        #expect(store.matchingInvestment(for: entry("Tesla", symbol: "TSLA")) == nil)
    }

    @Test("A forced-new entry never matches")
    func forcedNew() {
        let store = storeWithInvestments()
        var e = entry("Alphabet", symbol: "GOOGL")
        e.isForcedNew = true
        #expect(store.matchingInvestment(for: e) == nil)
    }

    @Test("Broker names normalize for matching")
    func normalizeBroker() {
        #expect(PortfolioStore.normalizeBroker("Trading 212") == PortfolioStore.normalizeBroker("trading212"))
        #expect(PortfolioStore.normalizeBroker("Revolut Ltd.") == "revolutltd")
    }
}

@MainActor
@Suite("Applying statements")
struct ApplyStatementTests {
    @Test("A new investment keeps the full Yahoo symbol and gets one holding")
    func createsInvestment() throws {
        let store = makeStore()
        store.applyStatementEntries([entry("BP", symbol: "BP.L", shares: 100, currency: "GBX", accountType: "ISA", broker: "Trading 212")])
        let bp = try #require(store.investment(named: "BP"))
        #expect(bp.symbol == "BP.L")
        #expect(bp.currencyCode == "GBX")
        #expect(bp.holdings == [Holding(broker: "Trading 212", accountType: "ISA", shares: 100)])
    }

    @Test("Same broker + account type updates shares; a different account adds a holding")
    func upsertsHoldings() throws {
        let store = makeStore()
        store.applyStatementEntries([entry("Apple", symbol: "AAPL", shares: 10, accountType: "ISA", broker: "Revolut")])
        store.applyStatementEntries([entry("Apple", symbol: "AAPL", shares: 12, accountType: "isa", broker: "revolut")])
        store.applyStatementEntries([entry("Apple", symbol: "AAPL", shares: 5, accountType: "Invest", broker: "Revolut")])
        let apple = try #require(store.investment(named: "Apple"))
        #expect(store.investments.filter { $0.name == "Apple" }.count == 1)
        #expect(apple.holdings.count == 2)
        #expect(apple.holdings.first { $0.accountType.lowercased() == "isa" }?.shares == 12)
        #expect(apple.holdings.first { $0.accountType == "Invest" }?.shares == 5)
    }

    @Test("A legacy bare symbol gains the statement's exchange suffix, but is never replaced by a different ticker")
    func upgradesBareSymbol() throws {
        let store = makeStore()
        store.investments.append(Investment(name: "BP", symbol: "BP"))
        store.applyStatementEntries([entry("BP", symbol: "BP.L")])
        #expect(store.investment(named: "BP")?.symbol == "BP.L")

        store.investments.append(Investment(name: "Volkswagen", symbol: "VOW3.DE"))
        var other = entry("Volkswagen", symbol: "VOW.DE")
        other.matchedInvestmentID = store.investment(named: "Volkswagen")?.id
        store.applyStatementEntries([other])
        #expect(store.investment(named: "Volkswagen")?.symbol == "VOW3.DE")
    }

    @Test("A user-confirmed symbol replaces the existing one")
    func userConfirmedSymbol() {
        let store = makeStore()
        store.investments.append(Investment(name: "Sui", symbol: "SUI-GBP", category: "Crypto"))
        var e = entry("Sui", symbol: "SUI20947-USD", category: "Crypto")
        e.matchedInvestmentID = store.investment(named: "Sui")?.id
        e.symbolConfirmedByUser = true
        store.applyStatementEntries([e])
        #expect(store.investment(named: "Sui")?.symbol == "SUI20947-USD")
    }

    @Test("A manual price from the preview is saved, in the statement's currency")
    func manualPrice() {
        let store = makeStore()
        var gold = entry("Gold", shares: 3.514292, value: 11010.64, currency: "GBP", category: "Commodity")
        gold.manualPrice = 3133.10
        store.applyStatementEntries([gold])
        #expect(store.investment(named: "Gold")?.manualPrice == 3133.10)
        #expect(store.investment(named: "Gold")?.currencyCode == "GBP")
    }

    @Test("Cash is converted to GBP and kept separate per broker and account type")
    func cashPerAccount() throws {
        let store = makeStore()
        store.exchangeRates["USD"] = 0.75
        store.applyStatementEntries([
            entry("Cash", shares: 1000, value: 1000, currency: "GBP", category: "Cash", accountType: "ISA"),
            entry("Cash", shares: 200, value: 200, currency: "USD", category: "Cash", accountType: "ISA")
        ])
        store.applyStatementEntries([entry("Cash", shares: 500, value: 500, category: "Cash", accountType: "Invest")])

        let cash = try #require(store.investment(named: "Cash"))
        #expect(cash.holdings.count == 2)
        #expect(cash.holdings.first { $0.accountType == "ISA" }?.shares == 1150)
        #expect(cash.holdings.first { $0.accountType == "Invest" }?.shares == 500)
        #expect(store.investments.filter { $0.name == "Cash" }.count == 1)
    }

    @Test("consolidatedCash sums per (broker, account type) and defaults the account to Invest")
    func consolidatedCash() {
        let totals = PortfolioStore.consolidatedCash([
            entry("Cash", value: 1000, currency: "GBP", category: "Cash", accountType: "ISA", broker: "Revolut"),
            entry("Cash", value: 200, currency: "USD", category: "Cash", accountType: "ISA", broker: "revolut"),
            entry("Cash", value: 500, currency: "GBP", category: "Cash", accountType: "Invest"),
            entry("Cash", value: 50, currency: "GBP", category: "Cash", accountType: nil)
        ], exchangeRates: ["GBP": 1, "USD": 0.75])
        #expect(totals.count == 2)
        #expect(totals[0].accountType == "ISA" && totals[0].gbpTotal == 1150)
        #expect(totals[1].accountType == "Invest" && totals[1].gbpTotal == 550)
    }
}

@MainActor
@Suite("Store management")
struct StoreManagementTests {
    @Test("Investments persist and reload from storage")
    func persistence() {
        let defaults = makeDefaults()
        let first = makeStore(defaults: defaults)
        first.applyStatementEntries([entry("Apple", symbol: "AAPL", shares: 3)])

        let reloaded = makeStore(defaults: defaults)
        #expect(reloaded.investment(named: "Apple")?.totalShares == 3)
        #expect(reloaded.investments.filter { $0.name == "Cash" }.count == 1)
    }

    @Test("Delete removes one investment; Cash is protected")
    func delete() throws {
        let store = makeStore()
        store.applyStatementEntries([entry("Apple", symbol: "AAPL")])
        store.deleteInvestment(try #require(store.investment(named: "Apple")))
        #expect(store.investment(named: "Apple") == nil)

        store.deleteInvestment(try #require(store.investment(named: "Cash")))
        #expect(store.investment(named: "Cash") != nil)
    }

    @Test("Reset clears everything except a fresh Cash investment")
    func reset() {
        let store = makeStore()
        store.applyStatementEntries([entry("Apple", symbol: "AAPL")])
        store.resetAllData()
        #expect(store.investments.map(\.name) == ["Cash"])
    }

    @Test("Updating an investment saves the edit")
    func update() throws {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        store.applyStatementEntries([entry("Apple", symbol: "AAPL")])
        var apple = try #require(store.investment(named: "Apple"))
        apple.targetPercentage = 25
        store.updateInvestment(apple)
        #expect(makeStore(defaults: defaults).investment(named: "Apple")?.targetPercentage == 25)
    }

    @Test("Remembered tickers persist and are listed by the statement's symbol")
    func tickerOverrides() {
        let defaults = makeDefaults()
        let store = makeStore(defaults: defaults)
        store.rememberTicker("SUI20947-USD", for: entry("Sui", symbol: "SUI-GBP", category: "Crypto"))
        let reloaded = makeStore(defaults: defaults)
        #expect(reloaded.tickerOverrides.values.map(\.ticker) == ["SUI20947-USD"])
        #expect(reloaded.tickerOverrides.values.first?.label == "Sui (SUI-GBP)")
    }

    @Test("hasAPIKey reflects the key provider")
    func apiKey() {
        #expect(makeStore(apiKey: "k").hasAPIKey)
        #expect(!makeStore(apiKey: nil).hasAPIKey)
    }

    @Test("Price status: manual, live, or no live price")
    func priceStatus() {
        let store = makeStore()
        var manual = Investment(name: "M", symbol: "X")
        manual.manualPrice = 1
        var live = Investment(name: "L", symbol: "AAPL")
        live.apiPrice = 100
        let noSymbol = Investment(name: "N")
        let neverPriced = Investment(name: "P", symbol: "AAPL")

        #expect(store.priceStatus(for: manual) == .manual)
        #expect(store.priceStatus(for: live) == .live)
        #expect(store.priceStatus(for: noSymbol) == .noLivePrice)
        #expect(store.priceStatus(for: neverPriced) == .noLivePrice)
        #expect(store.priceStatus(for: store.investments[0]) == .live, "Cash")
    }
}
