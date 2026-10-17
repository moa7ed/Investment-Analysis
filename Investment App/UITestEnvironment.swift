//
//  UITestEnvironment.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//

#if DEBUG
import Foundation

/// Launch-argument driven test mode for UI tests: an isolated, empty store with offline canned
/// Yahoo/Claude responses, so UI tests never touch real data or the internet.
///
/// - `-uiTesting`: use the stubbed store
/// - `-uiTestImportSample`: start an import of a sample statement on launch
enum UITestEnvironment {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-uiTesting")
    static let importsSampleOnLaunch = ProcessInfo.processInfo.arguments.contains("-uiTestImportSample")

    /// Separate defaults suite, wiped on every launch so each UI test starts from an empty portfolio.
    private static let defaultsSuite = "Investment-App.UITests"

    static func makeStore() -> PortfolioStore {
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        return PortfolioStore(defaults: defaults, http: makeStubClient(), apiKeyProvider: { "ui-test-key" })
    }

    /// A text statement whose parsed result is canned in `makeStubClient()`.
    static var sampleImports: [StatementSource] {
        guard importsSampleOnLaunch else { return [] }
        return [StatementSource(name: "sample.csv", contentBlock: ["type": "text", "text": "UI test sample statement"])]
    }

    /// Canned market data and Claude replies for the sample statement:
    /// Apple prices directly; Sui's statement symbol (SUI-GBP) fails and Claude corrects it to SUI20947-USD.
    static func makeStubClient() -> StubHTTPClient {
        let http = StubHTTPClient()
        http.fxRate("USD", toGBP: 0.75)
        http.yahooQuote("AAPL", price: 200, currency: "USD", type: "EQUITY", name: "Apple Inc.")
        http.yahooQuote("SUI20947-USD", price: 1.0, currency: "USD", type: "CRYPTOCURRENCY", name: "Sui USD")
        http.yahooSearch("Sui", results: [
            ("SUI", "EQUITY", "Sun Communities, Inc."),
            ("SUI20947-USD", "CRYPTOCURRENCY", "Sui USD")
        ])

        http.claude { prompt in
            if prompt.contains("Analyze this broker account statement") {
                return .json(StubHTTPClient.jsonString(["entries": [
                    sampleEntry(name: "Apple", symbol: "AAPL", shares: 10, value: 1500, category: "Stock"),
                    sampleEntry(name: "Sui", symbol: "SUI-GBP", shares: 1000, value: 750, category: "Crypto"),
                    sampleEntry(name: "Cash", symbol: nil, shares: 500, value: 500, category: "Cash")
                ]]))
            }
            if prompt.contains("have no working Yahoo Finance symbol") {
                return .json(StubHTTPClient.jsonString(["suggestions": [["number": 1, "symbol": "SUI20947-USD"]]]))
            }
            if prompt.contains("sector categories") {
                // Numbers beyond the portfolio size are ignored by the app
                return .json(StubHTTPClient.jsonString(["assignments": (1...20).map { ["number": $0, "sector": "Tech"] }]))
            }
            return nil
        }
        return http
    }

    /// A parsed statement entry as Claude would return it. No broker, so the preview must ask for one.
    private static func sampleEntry(name: String, symbol: String?, shares: Double, value: Double, category: String) -> [String: Any] {
        [
            "name": name,
            "symbol": symbol ?? NSNull(),
            "shares": shares,
            "price": NSNull(),
            "value": value,
            "currencyCode": "GBP",
            "category": category,
            "accountType": "Invest",
            "broker": NSNull(),
            "matchId": NSNull()
        ]
    }
}
#endif
