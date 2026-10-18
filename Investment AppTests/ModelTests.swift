//
//  ModelTests.swift
//  Investment AppTests
//

import Foundation
import Testing
@testable import Investment_App

@MainActor
@Suite("Investment model")
struct InvestmentModelTests {
    @Test("Total shares sum across holdings")
    func totalShares() {
        let investment = Investment(name: "Apple", holdings: [
            Holding(broker: "Revolut", accountType: "ISA", shares: 3),
            Holding(broker: "Trading 212", accountType: "Invest", shares: 2.5)
        ])
        #expect(investment.totalShares == 5.5)
    }

    @Test("Manual price overrides the market price")
    func effectivePrice() {
        var investment = Investment(name: "Apple")
        investment.apiPrice = 200
        #expect(investment.effectivePrice == 200)
        investment.manualPrice = 180
        #expect(investment.effectivePrice == 180)
    }

    @Test("Value is shares × price unless a manual value is set")
    func totalValue() {
        var investment = Investment(name: "Apple", holdings: [Holding(broker: "B", accountType: "ISA", shares: 10)])
        #expect(investment.totalValue == 0, "No price yet")
        investment.apiPrice = 20
        #expect(investment.totalValue == 200)
        investment.manualValue = 999
        #expect(investment.totalValue == 999)
    }

    @Test("Missing sector shows as Unclassified")
    func sectorOrDefault() {
        var investment = Investment(name: "Apple")
        #expect(investment.sectorOrDefault == "Unclassified")
        investment.sector = "Tech"
        #expect(investment.sectorOrDefault == "Tech")
    }

    @Test("Older saved data without newer fields still decodes with defaults")
    func decodesLegacyJSON() throws {
        let json = #"[{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Apple"}]"#
        let decoded = try JSONDecoder().decode([Investment].self, from: Data(json.utf8))
        let investment = try #require(decoded.first)
        #expect(investment.name == "Apple")
        #expect(investment.category == "Stock")
        #expect(investment.currencyCode == "USD")
        #expect(investment.holdings.isEmpty)
        #expect(investment.targetPercentage == 0)
        #expect(investment.symbol == nil)
    }

    @Test("Investments round-trip through JSON")
    func roundTrip() throws {
        var original = Investment(name: "Gold", symbol: "GC=F", category: "Commodity", targetPercentage: 20, currencyCode: "USD",
                                  holdings: [Holding(broker: "Revolut", accountType: "Invest", shares: 3.514292)])
        original.sector = "Commodities"
        original.manualPrice = 4000
        let decoded = try JSONDecoder().decode(Investment.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}

@MainActor
@Suite("Parsed statement entry")
struct ParsedStatementEntryTests {
    @Test("Cash is detected case-insensitively")
    func isCash() {
        #expect(entry("Cash", category: "cash").isCash)
        #expect(entry("Cash", category: "Cash").isCash)
        #expect(!entry("Apple", category: "Stock").isCash)
        #expect(!entry("Mystery", category: nil).isCash)
    }

    @Test("Missing broker and account type fall back to Unknown / Invest")
    func resolvedDefaults() {
        let e = entry("Apple", accountType: nil, broker: nil)
        #expect(e.resolvedBroker == "Unknown")
        #expect(e.resolvedAccountType == "Invest")
    }

    @Test("Decodes Claude's JSON, ignoring local-only fields")
    func decodes() throws {
        let json = StubHTTPClient.jsonString(entryJSON("Apple", symbol: "AAPL", shares: 10, value: 1500, matchId: 2))
        let decoded = try JSONDecoder().decode(ParsedStatementEntry.self, from: Data(json.utf8))
        #expect(decoded.name == "Apple")
        #expect(decoded.symbol == "AAPL")
        #expect(decoded.shares == 10)
        #expect(decoded.value == 1500)
        #expect(decoded.matchId == 2)
        #expect(decoded.matchedInvestmentID == nil)
        #expect(decoded.manualPrice == nil)
        #expect(!decoded.isForcedNew)
        #expect(!decoded.symbolConfirmedByUser)
    }
}

@Suite("Number parsing")
struct NumberTextTests {
    let uk = Locale(identifier: "en_GB")
    let germany = Locale(identifier: "de_DE")

    @Test("Parses the region's decimal separator", arguments: [
        ("12.5", "en_GB", 12.5), ("12,5", "de_DE", 12.5), ("1,250", "en_GB", 1250), ("1.250", "de_DE", 1250), ("7", "en_GB", 7)
    ])
    func parsesRegionFormats(text: String, localeID: String, expected: Double) {
        #expect(NumberText.parse(text, locale: Locale(identifier: localeID)) == expected)
    }

    @Test("Rejects ambiguous or malformed input instead of guessing", arguments: ["12abc", "abc", "1,2,3", "-3", "12,5"])
    func rejectsInvalid(text: String) {
        #expect(NumberText.parse(text, locale: uk) == nil)
        #expect(NumberText.isInvalid(text, locale: uk))
    }

    @Test("Empty text means 'no value', not invalid")
    func emptyIsNotInvalid() {
        #expect(NumberText.parse("  ", locale: uk) == nil)
        #expect(!NumberText.isInvalid("", locale: uk))
        #expect(NumberText.isEmpty(" "))
    }

    @Test("Formats without trailing .0 or grouping, keeping precision")
    func formats() {
        #expect(NumberText.format(0, locale: uk) == "0")
        #expect(NumberText.format(5, locale: uk) == "5")
        #expect(NumberText.format(12.5, locale: uk) == "12.5")
        #expect(NumberText.format(12.5, locale: germany) == "12,5")
        #expect(NumberText.format(0.12345678, locale: uk) == "0.12345678")
        #expect(NumberText.format(1234567.891, locale: uk) == "1234567.891")
        #expect(NumberText.format(0.00001, locale: uk) == "0.00001")
    }

    @Test("Formatted values parse back to the same number", arguments: [0.0, 5, 12.5, 0.12345678, 0.00001, 1234567.891])
    func roundTrips(value: Double) {
        for locale in [uk, germany] {
            #expect(NumberText.parse(NumberText.format(value, locale: locale), locale: locale) == value)
        }
    }
}
