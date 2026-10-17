//
//  PortfolioStore.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/09/2026.
//

import Foundation
import Observation

// MARK: - Claude API

/// Why a Claude request produced no usable result.
enum ClaudeFailure: Error {
    case missingKey
    /// Claude's safety filters declined the request (`stop_reason: "refusal"`).
    case refused
    /// Network, HTTP, or decoding failure.
    case failed

    var message: String {
        switch self {
        case .missingKey: "Add your Claude API key in Settings."
        case .refused: "Claude declined to process this request."
        case .failed: "The request to Claude failed. Check your connection and try again."
        }
    }
}

private enum ClaudeAPI {
    static let model = "claude-opus-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// The parts of a Messages API response the app reads.
    private struct MessagesResponse: Decodable {
        let content: [Block]
        let stopReason: String?
        struct Block: Decodable {
            let type: String?
            let text: String?
        }
        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    /// Sends content blocks (text, images, PDFs) and decodes the reply as `T`.
    /// The JSON schema is enforced by the API via structured outputs, so the reply is always valid JSON matching it.
    static func askJSON<T: Decodable>(
        _ contentBlocks: [[String: Any]],
        schema: [String: Any],
        as type: T.Type,
        maxTokens: Int = 4096,
        http: any HTTPClient,
        apiKey: String?
    ) async -> Result<T, ClaudeFailure> {
        guard let apiKey else { return .failure(.missingKey) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "messages": [["role": "user", "content": contentBlocks]]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return .failure(.failed) }
        request.httpBody = httpBody

        do {
            let (data, response) = try await http.send(request)
            guard let httpResponse = response as? HTTPURLResponse else { return .failure(.failed) }
            guard httpResponse.statusCode == 200 else {
                print("[ClaudeAPI] HTTP \(httpResponse.statusCode): \(String(data: data, encoding: .utf8) ?? "no body")")
                return .failure(.failed)
            }

            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            switch decoded.stopReason {
            case "refusal":
                return .failure(.refused)
            case "max_tokens":
                // Output was cut off mid-JSON
                print("[ClaudeAPI] Response truncated at max_tokens (\(maxTokens))")
                return .failure(.failed)
            default:
                break
            }

            guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
                return .failure(.failed)
            }
            do {
                return .success(try JSONDecoder().decode(T.self, from: Data(text.utf8)))
            } catch {
                print("[ClaudeAPI] Decode error: \(error)\nRaw response: \(text)")
                return .failure(.failed)
            }
        } catch {
            print("[ClaudeAPI] Error: \(error)")
            return .failure(.failed)
        }
    }

    // MARK: Schema helpers

    static func nullable(_ type: String) -> [String: Any] {
        ["anyOf": [["type": type], ["type": "null"]]]
    }

    /// An object schema where every property is required (nullable ones may be null), as structured outputs expects.
    static func object(_ properties: [String: Any]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": Array(properties.keys),
            "additionalProperties": false
        ]
    }
}

// MARK: - Statement Import Models

/// A ticker the user confirmed for a holding Yahoo couldn't price, reused on future imports.
struct TickerOverride: Codable {
    /// What the statement showed, e.g. "Gold (XAU)" — used in the Claude prompt
    let label: String
    let ticker: String
}

struct ParsedStatementEntry: Identifiable, Decodable {
    let id = UUID()
    let name: String
    /// Var so a remembered or user-entered ticker can replace Claude's symbol.
    var symbol: String?
    /// Price the user chose in the preview for a holding with no live price (in `currencyCode`). Not decoded.
    var manualPrice: Double?
    /// True when the user entered this ticker in the preview, so it replaces an existing investment's symbol. Not decoded.
    var symbolConfirmedByUser = false
    let shares: Double
    let value: Double?
    let price: Double?
    let currencyCode: String?
    let category: String?
    /// Var so the import preview can apply a user-chosen account type to every entry.
    var accountType: String?
    /// Var so the import preview can apply the user-confirmed broker to every entry.
    var broker: String?
    /// Claude's pick from the numbered list of existing investments sent with the statement (1-based), or nil if new.
    let matchId: Int?
    /// The existing investment `matchId` resolves to, or the user's pick in the import preview. Not decoded.
    var matchedInvestmentID: UUID?
    /// True when the user chose "New investment" in the preview, overriding all automatic matching. Not decoded.
    var isForcedNew = false

    var isCash: Bool {
        (category ?? "").lowercased() == "cash"
    }

    /// Broker and account type used to key holdings — shared by the preview and apply so they always agree.
    var resolvedBroker: String { broker ?? "Unknown" }
    var resolvedAccountType: String { accountType ?? "Invest" }

    private enum CodingKeys: String, CodingKey {
        case name, symbol, shares, value, price, currencyCode, category, accountType, broker, matchId
    }

    init(name: String, symbol: String?, shares: Double, value: Double?, price: Double?, currencyCode: String?, category: String?, accountType: String?, broker: String?, matchId: Int? = nil) {
        self.name = name
        self.symbol = symbol
        self.shares = shares
        self.value = value
        self.price = price
        self.currencyCode = currencyCode
        self.category = category
        self.accountType = accountType
        self.broker = broker
        self.matchId = matchId
    }
}

// MARK: - Yahoo Finance API Response

private struct YahooChartResponse: Decodable {
    let chart: YahooChart
}

private struct YahooChart: Decodable {
    let result: [YahooResult]?
}

private struct YahooResult: Decodable {
    let meta: YahooMeta
}

private struct YahooMeta: Decodable {
    let regularMarketPrice: Double
    let currency: String?
    let instrumentType: String?
    let longName: String?
    let shortName: String?
}

// MARK: - Portfolio Store

@MainActor
@Observable
class PortfolioStore {
    var investments: [Investment] = []
    var isLoading = false
    var hasFetchedOnce = false
    var exchangeRates: [String: Double] = ["GBP": 1.0, "GBX": 0.01]
    private var priceFetchTask: Task<Void, Never>?
    /// Investments whose symbol returned no price on the last refresh (not persisted — rechecked every refresh).
    private var fetchFailedIDs = Set<UUID>()
    /// Tickers the user confirmed during import, keyed by the statement's normalized symbol/name.
    private(set) var tickerOverrides: [String: TickerOverride] = [:]

    private let userDefaultsKey = "portfolio_investments"
    private let tickerOverridesKey = "ticker_overrides"
    private let dataResetKey = "data_reset_v8_cash_consolidation"
    /// nonisolated so it can be used as a default argument (an immutable Int is safe from any context)
    nonisolated static let defaultMaxSectors = 8

    /// Limits the main list to holdings at one broker and/or account type. nil = all. Not persisted.
    var brokerFilter: String?
    var accountTypeFilter: String?

    var isFiltering: Bool {
        brokerFilter != nil || accountTypeFilter != nil
    }

    private func matchesFilter(_ holding: Holding) -> Bool {
        if let brokerFilter, Self.normalizeBroker(holding.broker) != Self.normalizeBroker(brokerFilter) {
            return false
        }
        if let accountTypeFilter, holding.accountType.lowercased() != accountTypeFilter.lowercased() {
            return false
        }
        return true
    }

    /// Investments with at least one holding matching the filter (all investments when not filtering).
    var visibleInvestments: [Investment] {
        guard isFiltering else { return investments }
        return investments.filter { $0.holdings.contains(where: matchesFilter) }
    }

    /// Brokers offered in the filter, narrowed to the selected account type if there is one.
    var filterBrokers: [String] {
        var seen = Set<String>()
        return investments.flatMap(\.holdings)
            .filter { accountTypeFilter == nil || $0.accountType.lowercased() == accountTypeFilter?.lowercased() }
            .map(\.broker)
            .filter { seen.insert(Self.normalizeBroker($0)).inserted }
            .sorted()
    }

    /// Account types offered in the filter, narrowed to the selected broker if there is one.
    var filterAccountTypes: [String] {
        var seen = Set<String>()
        return investments.flatMap(\.holdings)
            .filter { brokerFilter == nil || Self.normalizeBroker($0.broker) == Self.normalizeBroker(brokerFilter ?? "") }
            .map(\.accountType)
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted()
    }

    var totalPortfolioValue: Double {
        visibleInvestments.reduce(0) { $0 + valueInGBP(for: $1) }
    }

    /// GBP value of the investment — only the holdings matching the filter when one is set.
    func valueInGBP(for investment: Investment) -> Double {
        let rate = exchangeRates[investment.currencyCode] ?? 1.0
        guard isFiltering else { return investment.totalValue * rate }
        // Share of the value held in matching holdings (also covers manual total values)
        let total = investment.totalShares
        guard total > 0 else { return 0 }
        let matching = investment.holdings.filter(matchesFilter).reduce(0) { $0 + $1.shares }
        return investment.totalValue * (matching / total) * rate
    }

    func currentPercentage(for investment: Investment) -> Double {
        guard totalPortfolioValue > 0 else { return 0 }
        return (valueInGBP(for: investment) / totalPortfolioValue) * 100
    }

    /// All unique sector names currently assigned to investments, in stable order
    var knownSectors: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for inv in investments {
            let s = inv.sectorOrDefault
            if seen.insert(s).inserted {
                result.append(s)
            }
        }
        return result
    }

    var investmentsBySector: [(sector: String, items: [Investment])] {
        let grouped = Dictionary(grouping: visibleInvestments, by: \.sectorOrDefault)
        return knownSectors.compactMap { sector in
            guard let items = grouped[sector], !items.isEmpty else { return nil }
            return (sector: sector, items: items)
        }
    }

    func sectorValue(_ sector: String) -> Double {
        visibleInvestments.filter { $0.sectorOrDefault == sector }.reduce(0) { $0 + valueInGBP(for: $1) }
    }

    func sectorCurrentPercentage(_ sector: String) -> Double {
        visibleInvestments.filter { $0.sectorOrDefault == sector }.reduce(0) { $0 + currentPercentage(for: $1) }
    }

    func sectorTargetPercentage(_ sector: String) -> Double {
        visibleInvestments.filter { $0.sectorOrDefault == sector }.reduce(0) { $0 + $1.targetPercentage }
    }

    /// Where investments and ticker overrides are saved (`.standard` in the app; an isolated suite in tests).
    private let defaults: UserDefaults
    /// Network client for Yahoo and Claude. `nonisolated` so background price fetches can use it.
    nonisolated let http: any HTTPClient
    /// Returns the Claude API key, read on every call so a key changed in Settings takes effect immediately.
    private let apiKeyProvider: () -> String?

    var hasAPIKey: Bool {
        apiKeyProvider() != nil
    }

    init(
        defaults: UserDefaults = .standard,
        http: any HTTPClient = URLSession.shared,
        apiKeyProvider: @escaping () -> String? = { APIKeyStore.claudeKey }
    ) {
        self.defaults = defaults
        self.http = http
        self.apiKeyProvider = apiKeyProvider
        resetDataIfNeeded()
        loadFromUserDefaults()
        loadTickerOverrides()
        ensureCashInvestmentExists()
        debugPrintInvestments()
    }

    private func debugPrintInvestments() {
        print("[Portfolio] \(investments.count) investments:")
        for inv in investments {
            let holdings = inv.holdings.map { "\($0.broker)/\($0.accountType): \($0.shares)" }.joined(separator: ", ")
            print("  \(inv.name) | symbol: \(inv.symbol ?? "nil") | category: \(inv.category) | currency: \(inv.currencyCode) | apiPrice: \(inv.apiPrice.map { String($0) } ?? "nil") | manualPrice: \(inv.manualPrice.map { String($0) } ?? "nil") | manualValue: \(inv.manualValue.map { String($0) } ?? "nil") | totalValue: \(inv.totalValue) \(inv.currencyCode) | sector: \(inv.sector ?? "nil") | target: \(inv.targetPercentage)% | holdings: [\(holdings)]")
        }
    }

    /// Logs the full portfolio once prices and exchange rates are up to date (on launch and every refresh).
    private func logPortfolioAfterRefresh() {
        let gbp = FloatingPointFormatStyle<Double>.Currency(code: "GBP").precision(.fractionLength(2))
        let rates = exchangeRates.keys.sorted().map { "\($0)=\(exchangeRates[$0] ?? 0)" }.joined(separator: ", ")

        print("[Portfolio] ===== After price & exchange rate refresh =====")
        print("[Portfolio] Exchange rates to GBP: \(rates)")
        for inv in investments.sorted(by: { valueInGBP(for: $0) > valueInGBP(for: $1) }) {
            let status = switch priceStatus(for: inv) {
            case .live: "live"
            case .manual: "manual"
            case .noLivePrice: "NO LIVE PRICE"
            }
            let price = inv.effectivePrice.map { "\($0) \(inv.currencyCode)" } ?? "nil"
            let holdings = inv.holdings.map { "\($0.broker)/\($0.accountType): \($0.shares)" }.joined(separator: ", ")
            print("""
              \(inv.name) [\(inv.symbol ?? "no symbol")] | \(inv.category) | sector: \(inv.sectorOrDefault) \
            | price: \(price) (\(status)) | units: \(inv.totalShares) \
            | value: \(inv.totalValue) \(inv.currencyCode) = \(valueInGBP(for: inv).formatted(gbp)) \
            | \(String(format: "%.2f", currentPercentage(for: inv)))% of portfolio / target \(inv.targetPercentage)% \
            | holdings: [\(holdings)]
            """)
        }
        print("[Portfolio] Total: \(totalPortfolioValue.formatted(gbp)) across \(investments.count) investments")
        print("[Portfolio] ================================================")
    }

    /// Creates a default "Cash" investment if one doesn't already exist.
    private func ensureCashInvestmentExists() {
        guard !investments.contains(where: { $0.name == "Cash" }) else { return }
        var cash = Investment(name: "Cash", category: "Cash", currencyCode: "GBP")
        cash.sector = "Cash"
        cash.apiPrice = 1
        investments.append(cash)
        saveToUserDefaults()
    }

    /// One-time reset: clears old data that used enum-based categories.
    private func resetDataIfNeeded() {
        guard !defaults.bool(forKey: dataResetKey) else { return }
        defaults.removeObject(forKey: userDefaultsKey)
        defaults.set(true, forKey: dataResetKey)
    }

    // MARK: - Persistence

    func saveToUserDefaults() {
        if let data = try? JSONEncoder().encode(investments) {
            defaults.set(data, forKey: userDefaultsKey)
        }
    }

    private func loadFromUserDefaults() {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([Investment].self, from: data)
        else {
            return
        }
        investments = decoded
    }

    // MARK: - Reset

    func resetAllData() {
        investments = []
        defaults.removeObject(forKey: userDefaultsKey)
        ensureCashInvestmentExists()
    }

    // MARK: - Update

    func updateInvestment(_ investment: Investment) {
        if let index = investments.firstIndex(where: { $0.id == investment.id }) {
            investments[index] = investment
            saveToUserDefaults()
        }
    }

    /// Sum of every investment's target, regardless of the broker/type filter.
    var totalTargetPercentage: Double {
        investments.reduce(0) { $0 + $1.targetPercentage }
    }

    /// Targets add up to exactly 100% (allowing for floating-point noise from many 0.25% steps).
    var targetsAddUpTo100: Bool {
        abs(totalTargetPercentage - 100) < 0.001
    }

    /// Sets target percentages in one go (from the Targets page), keyed by investment ID.
    func setTargets(_ targets: [UUID: Double]) {
        for index in investments.indices {
            if let target = targets[investments[index].id] {
                investments[index].targetPercentage = target
            }
        }
        saveToUserDefaults()
    }

    // MARK: - Price Status

    enum PriceStatus {
        case live
        /// Valued from a manual price or value the user entered
        case manual
        /// No symbol, or the symbol returned no price on the last refresh
        case noLivePrice
    }

    func priceStatus(for investment: Investment) -> PriceStatus {
        if investment.manualPrice != nil || investment.manualValue != nil { return .manual }
        if investment.category.lowercased() == "cash" { return .live }
        if investment.symbol == nil || fetchFailedIDs.contains(investment.id) || investment.apiPrice == nil {
            return .noLivePrice
        }
        return .live
    }

    // MARK: - Symbol Validation

    enum SymbolValidation {
        case valid(YahooQuote)
        case noPrice
        /// Yahoo's instrument type doesn't fit the holding's category (e.g. a stock for a crypto holding)
        case typeMismatch(YahooQuote)
        /// Yahoo's price is far from the statement's — likely a different instrument or unit
        case priceMismatch(YahooQuote, yahooGBP: Double, statementGBP: Double)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
    }

    /// Checks that a symbol prices this holding: Yahoo has a price, the instrument type fits the category,
    /// and (when the statement shows a price or value) the price is within ±25% of it.
    func validateSymbol(_ symbol: String, for entry: ParsedStatementEntry) async -> SymbolValidation {
        guard let quote = await fetchYahooQuote(for: symbol) else { return .noPrice }
        guard Self.instrumentType(quote.instrumentType, fits: entry.category) else { return .typeMismatch(quote) }

        // Compare per-unit prices in GBP; skip if the statement has no price or a rate is unavailable
        let statementCurrency = entry.currencyCode ?? "GBP"
        guard let statementPrice = entry.price ?? entry.value.flatMap({ entry.shares > 0 ? $0 / entry.shares : nil }),
              statementPrice > 0
        else { return .valid(quote) }
        _ = await ensureExchangeRates(for: [quote.currency, statementCurrency])
        guard let yahooRate = exchangeRates[quote.currency],
              let statementRate = exchangeRates[statementCurrency]
        else { return .valid(quote) }

        let yahooGBP = quote.price * yahooRate
        let statementGBP = statementPrice * statementRate
        guard abs(yahooGBP / statementGBP - 1) <= 0.25 else {
            return .priceMismatch(quote, yahooGBP: yahooGBP, statementGBP: statementGBP)
        }
        return .valid(quote)
    }

    /// Which Yahoo instrument types are acceptable for a statement category. Unknown types are allowed.
    private static func instrumentType(_ type: String?, fits category: String?) -> Bool {
        guard let type = type?.uppercased() else { return true }
        switch (category ?? "").lowercased() {
        case "crypto":
            return type == "CRYPTOCURRENCY"
        case "commodity":
            return ["FUTURE", "ETF", "EQUITY", "MUTUALFUND"].contains(type)
        default: // Stock, ETF, Real Estate
            return ["EQUITY", "ETF", "MUTUALFUND"].contains(type)
        }
    }

    /// Readable name for a Yahoo instrument type, used in validation messages.
    nonisolated static func describe(instrumentType: String?) -> String {
        switch instrumentType?.uppercased() {
        case "EQUITY": "a stock"
        case "ETF": "an ETF"
        case "MUTUALFUND": "a fund"
        case "CRYPTOCURRENCY": "a cryptocurrency"
        case "FUTURE": "a futures contract"
        case "CURRENCY": "a currency pair"
        case "INDEX": "an index"
        default: "a different instrument"
        }
    }

    // MARK: - Claude Symbol Resolution

    /// For holdings whose symbol failed validation, asks Claude (in one request) for the correct Yahoo symbol.
    /// Claude is given real Yahoo search candidates so it picks symbols Yahoo actually lists.
    /// - Returns: Suggested symbol per entry ID (only entries Claude had a suggestion for).
    func suggestSymbols(for entries: [ParsedStatementEntry], failedSymbols: [UUID: String]) async -> [UUID: String] {
        guard !entries.isEmpty, hasAPIKey else { return [:] }

        // Gather Yahoo search candidates by name and by the failed symbol's base (e.g. "SUI" from "SUI-GBP")
        var candidatesByID: [UUID: [YahooSearchResult]] = [:]
        await withTaskGroup(of: (UUID, [YahooSearchResult]).self) { group in
            for entry in entries {
                let failed = failedSymbols[entry.id]
                let base = failed.map { String($0.split(whereSeparator: { "-.=".contains($0) }).first ?? Substring($0)) }
                let queries = Array(Set([entry.name, base].compactMap { $0 }))
                group.addTask {
                    var seen = Set<String>()
                    var results: [YahooSearchResult] = []
                    for query in queries {
                        for result in await self.searchYahoo(query) where seen.insert(result.symbol ?? "").inserted {
                            results.append(result)
                        }
                    }
                    return (entry.id, Array(results.prefix(10)))
                }
            }
            for await (id, results) in group {
                candidatesByID[id] = results
            }
        }

        let holdings = entries.enumerated().map { index, entry in
            let statementPrice = entry.price.map { "\($0) \(entry.currencyCode ?? "GBP") per unit" }
                ?? entry.value.map { "total value \($0) \(entry.currencyCode ?? "GBP") for \(entry.shares) units" }
                ?? "unknown"
            let candidates = (candidatesByID[entry.id] ?? [])
                .map { "    - \($0.symbol ?? "") | \($0.quoteType ?? "?") | \($0.displayName) | \($0.exchange ?? "?")" }
                .joined(separator: "\n")
            return """
            \(index + 1). \(entry.name) — category: \(entry.category ?? "unknown"), statement price: \(statementPrice), \
            symbol that failed: \(failedSymbols[entry.id] ?? "none")
              Yahoo Finance search results:
            \(candidates.isEmpty ? "    (none)" : candidates)
            """
        }.joined(separator: "\n\n")

        let prompt = """
        These holdings from a broker statement have no working Yahoo Finance symbol. For each, give the Yahoo Finance \
        symbol that prices exactly this holding, or null if none fits.

        Rules:
        - Prefer a symbol from its Yahoo search results; only suggest another if you're confident Yahoo lists it.
        - The instrument type must match the category (Crypto → CRYPTOCURRENCY, e.g. "SUI20947-USD"; stocks → EQUITY; \
        funds → ETF; metals held as ounces → futures such as "GC=F").
        - Cryptocurrencies: use the USD pair; Yahoo lists GBP pairs only for a few major coins.
        - The symbol's price should be consistent with the statement price (allowing for currency).
        - Never reuse the symbol that failed.

        Holdings:
        \(holdings)
        """

        struct Suggestions: Decodable {
            let suggestions: [Suggestion]
            struct Suggestion: Decodable {
                let number: Int
                let symbol: String?
            }
        }
        let schema = ClaudeAPI.object([
            "suggestions": [
                "type": "array",
                "items": ClaudeAPI.object([
                    "number": ["type": "integer"],
                    "symbol": ClaudeAPI.nullable("string")
                ])
            ]
        ])

        guard case .success(let result) = await ClaudeAPI.askJSON(
            [["type": "text", "text": prompt]], schema: schema, as: Suggestions.self,
            http: http, apiKey: apiKeyProvider()
        ) else { return [:] }

        var suggestionsByID: [UUID: String] = [:]
        for suggestion in result.suggestions {
            guard entries.indices.contains(suggestion.number - 1),
                  let symbol = suggestion.symbol?.trimmingCharacters(in: .whitespaces), !symbol.isEmpty
            else { continue }
            let entry = entries[suggestion.number - 1]
            if symbol.uppercased() != failedSymbols[entry.id]?.uppercased() {
                suggestionsByID[entry.id] = symbol
            }
        }
        return suggestionsByID
    }

    // MARK: - Ticker Overrides

    /// Remembers a user-confirmed ticker for a statement holding, so future imports use it automatically.
    func rememberTicker(_ ticker: String, for entry: ParsedStatementEntry) {
        let label = entry.symbol.map { "\(entry.name) (\($0))" } ?? entry.name
        tickerOverrides[Self.overrideKey(for: entry)] = TickerOverride(label: label, ticker: ticker)
        if let data = try? JSONEncoder().encode(tickerOverrides) {
            defaults.set(data, forKey: tickerOverridesKey)
        }
    }

    private func loadTickerOverrides() {
        guard let data = defaults.data(forKey: tickerOverridesKey),
              let decoded = try? JSONDecoder().decode([String: TickerOverride].self, from: data)
        else { return }
        tickerOverrides = decoded
    }

    /// Keyed on what the statement shows (its symbol if any, else the name), normalized.
    private static func overrideKey(for entry: ParsedStatementEntry) -> String {
        normalizeName(entry.symbol ?? entry.name)
    }

    // MARK: - Delete

    /// Whether an investment can be deleted. The "Cash" investment is required for cash imports, so it's protected.
    func canDelete(_ investment: Investment) -> Bool {
        investment.name != "Cash"
    }

    func deleteInvestment(_ investment: Investment) {
        guard canDelete(investment) else { return }
        investments.removeAll { $0.id == investment.id }
        saveToUserDefaults()
    }

    // MARK: - Yahoo Finance API

    func fetchAllPrices() async {
        priceFetchTask?.cancel()
        let task = Task {
            isLoading = true
            defer {
                isLoading = false
                hasFetchedOnce = true
                if !Task.isCancelled {
                    saveToUserDefaults()
                }
            }

            // Fetch exchange rates and stock prices concurrently
            async let ratesTask: Void = fetchExchangeRates(refreshAll: true)

            var failedIDs = Set<UUID>()
            await withTaskGroup(of: (UUID, YahooQuote?).self) { group in
                for investment in investments {
                    guard let symbol = investment.symbol else { continue }
                    let id = investment.id
                    group.addTask {
                        let quote = await self.fetchYahooQuote(for: symbol)
                        if quote == nil { print("[fetchAllPrices] No price found for symbol: \(symbol)") }
                        return (id, quote)
                    }
                }

                for await (id, quote) in group {
                    guard !Task.isCancelled else { break }
                    guard let index = investments.firstIndex(where: { $0.id == id }) else { continue }
                    guard let quote else {
                        failedIDs.insert(id)
                        continue
                    }
                    investments[index].apiPrice = quote.price
                    // A manual price/value is in the investment's own currency — don't switch it underneath
                    if investments[index].manualPrice == nil && investments[index].manualValue == nil {
                        investments[index].currencyCode = quote.currency
                    }
                }
            }
            if !Task.isCancelled {
                fetchFailedIDs = failedIDs
            }

            await ratesTask

            // Prices may have introduced new currencies (Yahoo overrides currencyCode) — fetch any missing rates
            if !Task.isCancelled {
                await fetchExchangeRates()
            }

            if !Task.isCancelled {
                logPortfolioAfterRefresh()
            }

            // Classify any investments that don't have a sector yet
            if !Task.isCancelled {
                await classifySectors()
            }
        }
        priceFetchTask = task
        await task.value
    }

    // MARK: - AI Sector Classification

    /// Asks Claude to classify unclassified investments into sectors.
    /// - Parameters:
    ///   - maxSectors: Maximum number of sector categories the AI should use
    ///   - additionalPrompt: Optional extra instructions appended to the prompt
    ///   - forceAll: If true, reclassifies all investments; any Claude leaves out keep their current sector
    /// - Returns: The failure if the Claude call didn't succeed, or nil on success. Sectors are only changed on success.
    @discardableResult
    func classifySectors(maxSectors: Int = defaultMaxSectors, additionalPrompt: String = "", forceAll: Bool = false) async -> ClaudeFailure? {
        // Nothing is cleared up-front, so a failed request leaves existing sectors untouched
        let targetIDs = Set(investments.filter { forceAll || $0.sector == nil }.map(\.id))
        guard !targetIDs.isEmpty else { return nil }

        // Claude replies by list number; map numbers back to stable IDs captured before the request
        let snapshot = investments
        let idByNumber = Dictionary(uniqueKeysWithValues: snapshot.enumerated().map { ($0.offset + 1, $0.element.id) })
        let entries = snapshot.map { inv in
            "\(inv.name) (\(inv.symbol ?? "N/A"), \(inv.category))"
        }

        var prompt = """
        I have a portfolio of investments. Analyze them and:
        1. Determine the best set of sector categories (maximum \(maxSectors) sectors) that meaningfully represent this portfolio.
        2. Assign each investment to exactly one sector.

        Use short, clear sector names (e.g. "Tech", "Crypto", "Commodities", "Index Funds", "Auto", "Finance").
        
        Keep Cash, in its own Sector

        Investments:
        \(entries.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        Return one assignment per investment, using its list number. Every investment must be assigned. Use at most \(maxSectors) sectors total.
        """

        if !additionalPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            prompt += "\n\nAdditional instructions: \(additionalPrompt)"
        }

        struct Classification: Decodable {
            let assignments: [Assignment]
            struct Assignment: Decodable {
                let number: Int
                let sector: String
            }
        }
        let schema = ClaudeAPI.object([
            "assignments": [
                "type": "array",
                "items": ClaudeAPI.object([
                    "number": ["type": "integer"],
                    "sector": ["type": "string"]
                ])
            ]
        ])

        let result = await ClaudeAPI.askJSON(
            [["type": "text", "text": prompt]], schema: schema, as: Classification.self,
            http: http, apiKey: apiKeyProvider()
        )
        let classification: Classification
        switch result {
        case .success(let value): classification = value
        case .failure(let failure): return failure
        }

        // Unknown list numbers are dropped
        var sectorByID: [UUID: String] = [:]
        for assignment in classification.assignments {
            if let id = idByNumber[assignment.number] {
                sectorByID[id] = assignment.sector
            }
        }

        // Apply all results in one pass; cash always stays in "Cash" regardless of Claude's answer
        for i in investments.indices where targetIDs.contains(investments[i].id) {
            if investments[i].category.lowercased() == "cash" {
                investments[i].sector = "Cash"
            } else if let sectorName = sectorByID[investments[i].id] {
                investments[i].sector = sectorName
            }
        }

        saveToUserDefaults()
        return nil
    }

    // MARK: - Statement Import

    /// Categories Claude may assign to a statement entry (enforced by the response schema).
    private static let statementCategories = ["Stock", "ETF", "Crypto", "Commodity", "Cash", "Real Estate"]

    /// Parses one broker statement (PDF, image, or text file) by sending it to Claude.
    func parseStatement(_ source: StatementSource) async -> Result<[ParsedStatementEntry], ClaudeFailure> {
        // Existing investments Claude can match entries against (Cash is handled separately)
        let candidates = investments.filter { $0.category.lowercased() != "cash" }
        let candidateList = candidates.isEmpty
            ? "(none)"
            : candidates.enumerated()
                .map { "\($0.offset + 1). \($0.element.name) (\($0.element.symbol ?? "no symbol"))" }
                .joined(separator: "\n")

        // Tickers the user confirmed on earlier imports, for holdings Yahoo couldn't price as Claude suggested
        let confirmedTickerList = tickerOverrides.isEmpty
            ? ""
            : "\nUser-confirmed tickers (always use these symbols for these holdings):\n"
                + tickerOverrides.values.map { "- \($0.label) → \($0.ticker)" }.sorted().joined(separator: "\n")

        let textBlock: [String: Any] = [
            "type": "text",
            "text": """
            Analyze this broker account statement. Extract every investment/holding listed.

            For each investment, provide:
            - "name": The investment name (e.g., "Apple", "Vanguard S&P 500 ETF")
            - "symbol": The Yahoo Finance ticker symbol (e.g., "AAPL", "VUSA.L", "VOW3.DE"), or null. If the statement shows a different symbol, convert it to the Yahoo Finance equivalent. Include exchange suffixes for non-US stocks (e.g., ".L" for London, ".DE" for Frankfurt, ".PA" for Paris). Precious metals held directly as ounces/units (shown as XAU, XAG, XPT, XPD, or "gold"/"silver" balances) have no stock ticker: use the Yahoo futures symbol — gold "GC=F", silver "SI=F", platinum "PL=F", palladium "PA=F". Never use XAU/XAG/XPT/XPD as a symbol. Exchange-listed gold/silver funds (ETCs/ETFs such as "SGLN.L") keep their own ticker. Cryptocurrencies: use Yahoo's USD pair "COIN-USD" (e.g. "BTC-USD"), since Yahoo lists GBP pairs only for a few major coins; some coins have a numeric Yahoo id (e.g. Sui is "SUI20947-USD").
            - "shares": Number of shares/units held (as a number). For precious metals held directly, the number of troy ounces (e.g. 3.514292 for "3.514292 XAU")
            - "price": The price per share/unit if shown (as a number), or null
            - "value": Total value if shown (as a number), or null. If not shown but price and shares are available, calculate it.
            - "currencyCode": The currency code (e.g., "USD", "GBP", "EUR", "GBX"). Use the currency the price/value is shown in on the statement. Default to "GBP" if unclear. Never use a metal code (XAU, XAG, XPT, XPD) as the currency.
            - "category": Classify the investment into one of these categories: "Stock", "ETF", "Crypto", "Commodity", "Cash", "Real Estate". Rules:
              - Cryptocurrencies (Bitcoin, Ethereum, Solana, etc.) or symbols ending in "-USD" → "Crypto"
              - ETFs, index funds, iShares, Vanguard funds, or London-listed funds (.L suffix) → "ETF"
              - Gold, silver, metals, commodities → "Commodity"
              - Cash holdings → "Cash"
              - REITs, real estate → "Real Estate"
              - Individual company stocks → "Stock"
            - "accountType": The account type: "ISA" for ISA wrappers, "General" only if the statement calls the account "General" or a General Investment Account (GIA), "Invest" for other non-ISA investment accounts, or null if unclear
            - "broker": The broker/platform name ONLY if it is explicitly written in the document (or shown as a readable logo). Do not infer it from the layout, formatting, or style of the statement. If the name does not appear, use null.
            - "matchId": If this holding is the same company or fund as one of the existing investments listed below, the number of that existing investment; otherwise null. Match even when the ticker or exchange differs (e.g. GOOG vs GOOGL, VUSA.L vs VUSA.AS, or a Frankfurt listing of a US company). Only match the same company or fund - never merely a similar one or the same sector.

            Existing investments:
            \(candidateList)
            \(confirmedTickerList)

            Important:
            - Include ALL investments/holdings shown
            - Use the exact share/unit counts shown
            - If the statement shows ISA and non-ISA sections separately, set accountType accordingly ("ISA" or "Invest")
            - If several entries in this statement are the same company or fund (e.g. GOOG and GOOGL), give them the identical "name"
            - Return an empty "entries" list if no investments are found
            """
        ]

        struct StatementResponse: Decodable {
            let entries: [ParsedStatementEntry]
        }
        let entrySchema = ClaudeAPI.object([
            "name": ["type": "string"],
            "symbol": ClaudeAPI.nullable("string"),
            "shares": ["type": "number"],
            "price": ClaudeAPI.nullable("number"),
            "value": ClaudeAPI.nullable("number"),
            "currencyCode": ClaudeAPI.nullable("string"),
            "category": ["type": "string", "enum": Self.statementCategories],
            "accountType": ClaudeAPI.nullable("string"),
            "broker": ClaudeAPI.nullable("string"),
            "matchId": ClaudeAPI.nullable("integer")
        ])
        let schema = ClaudeAPI.object([
            "entries": ["type": "array", "items": entrySchema]
        ])

        let result = await ClaudeAPI.askJSON(
            [source.contentBlock, textBlock],
            schema: schema,
            as: StatementResponse.self,
            maxTokens: 16384,
            http: http,
            apiKey: apiKeyProvider()
        )

        return result.map { response in
            var entries = response.entries
            // Resolve Claude's 1-based matchId to the candidate's stable ID, ignoring out-of-range values
            for i in entries.indices {
                if let matchId = entries[i].matchId, candidates.indices.contains(matchId - 1) {
                    entries[i].matchedInvestmentID = candidates[matchId - 1].id
                }
                // Enforce user-confirmed tickers even if Claude didn't follow the prompt
                if let override = tickerOverrides[Self.overrideKey(for: entries[i])] {
                    entries[i].symbol = override.ticker
                }
            }
            return entries
        }
    }

    /// Applies parsed statement entries to the portfolio.
    /// Only processes entries that are new or have changed holdings.
    /// Cash entries are consolidated into the single "Cash" investment.
    /// Call `fetchAllPrices()` after this to fetch live prices and classify sectors.
    func applyStatementEntries(_ entries: [ParsedStatementEntry]) {
        // Cancel any in-flight price fetch to prevent it from saving stale data
        priceFetchTask?.cancel()
        priceFetchTask = nil

        // Separate cash entries from regular entries
        let cashEntries = entries.filter(\.isCash)
        let regularEntries = entries.filter { !$0.isCash }

        // Consolidate all cash entries into the "Cash" investment
        if !cashEntries.isEmpty {
            applyCashEntries(cashEntries)
        }

        for entry in regularEntries {
            let holding = Holding(broker: entry.resolvedBroker, accountType: entry.resolvedAccountType, shares: entry.shares)

            if let idx = matchingInvestmentIndex(for: entry) {
                if entry.symbolConfirmedByUser {
                    investments[idx].symbol = entry.symbol
                } else {
                    upgradeBareSymbol(at: idx, with: entry.symbol)
                }
                if let manualPrice = entry.manualPrice {
                    investments[idx].manualPrice = manualPrice
                    investments[idx].currencyCode = entry.currencyCode ?? investments[idx].currencyCode
                }
                upsertHolding(holding, at: idx)
            } else {
                // Keep the full Yahoo symbol (e.g. "BP.L") so prices come from the right exchange
                var newInvestment = Investment(
                    name: entry.name,
                    symbol: entry.symbol,
                    category: entry.category ?? "Stock",
                    currencyCode: entry.currencyCode ?? "GBP",
                    holdings: [holding]
                )
                newInvestment.manualPrice = entry.manualPrice
                investments.append(newInvestment)
            }
        }

        saveToUserDefaults()
    }

    /// Consolidates cash entries into the "Cash" investment.
    /// Sums cash (converted to GBP) per (broker, account type), so e.g. Revolut ISA and Revolut Invest
    /// cash stay separate holdings — matching how regular holdings are keyed.
    private func applyCashEntries(_ cashEntries: [ParsedStatementEntry]) {
        ensureCashInvestmentExists()
        guard let cashIdx = investments.firstIndex(where: { $0.name == "Cash" }) else { return }

        for cash in Self.consolidatedCash(cashEntries, exchangeRates: exchangeRates) {
            upsertHolding(Holding(broker: cash.broker, accountType: cash.accountType, shares: cash.gbpTotal), at: cashIdx)
        }
    }

    /// Sums cash entries to GBP per (broker, account type). Used by both apply and the import preview.
    static func consolidatedCash(
        _ cashEntries: [ParsedStatementEntry],
        exchangeRates: [String: Double]
    ) -> [(broker: String, accountType: String, gbpTotal: Double)] {
        var totals: [String: (broker: String, accountType: String, gbpTotal: Double)] = [:]
        var order: [String] = []
        for entry in cashEntries {
            let value = entry.value ?? (entry.shares * (entry.price ?? 1))
            let rate = exchangeRates[entry.currencyCode ?? "GBP"] ?? 1.0
            let key = normalizeBroker(entry.resolvedBroker) + "|" + entry.resolvedAccountType.lowercased()
            if totals[key] == nil {
                totals[key] = (entry.resolvedBroker, entry.resolvedAccountType, 0)
                order.append(key)
            }
            totals[key]?.gbpTotal += value * rate
        }
        return order.compactMap { totals[$0] }
    }

    /// Finds the existing investment a statement entry belongs to, or nil if it's new.
    /// Shared by the import preview and `applyStatementEntries` so both always agree.
    func matchingInvestment(for entry: ParsedStatementEntry) -> Investment? {
        guard let idx = matchingInvestmentIndex(for: entry) else { return nil }
        return investments[idx]
    }

    /// Matching order: Cash → user forced new → Claude's/user's match → exact symbol → base symbol (e.g. "VUSA" from "VUSA.L") → normalized name.
    private func matchingInvestmentIndex(for entry: ParsedStatementEntry) -> Int? {
        if entry.isCash {
            return investments.firstIndex(where: { $0.name == "Cash" })
        }
        if entry.isForcedNew {
            return nil
        }
        if let id = entry.matchedInvestmentID,
           let idx = investments.firstIndex(where: { $0.id == id }) {
            return idx
        }
        if let symbol = entry.symbol?.lowercased() {
            if let idx = investments.firstIndex(where: { $0.symbol?.lowercased() == symbol }) {
                return idx
            }
            let base = Self.baseSymbol(symbol)
            if let idx = investments.firstIndex(where: { $0.symbol.map { Self.baseSymbol($0.lowercased()) } == base }) {
                return idx
            }
        }
        let name = Self.normalizeName(entry.name)
        return investments.firstIndex(where: {
            $0.category.lowercased() != "cash" && Self.normalizeName($0.name) == name
        })
    }

    /// Returns the symbol without its exchange suffix (e.g. "VUSA.L" → "VUSA").
    private static func baseSymbol(_ symbol: String) -> String {
        symbol.split(separator: ".").first.map(String.init) ?? symbol
    }

    /// Upgrades a legacy bare symbol (e.g. "BP") to the statement's exchange-qualified form (e.g. "BP.L").
    /// Only adds a suffix to the same base — never replaces one ticker with a different one.
    private func upgradeBareSymbol(at index: Int, with statementSymbol: String?) {
        guard let existing = investments[index].symbol, !existing.contains("."),
              let incoming = statementSymbol, incoming.contains("."),
              Self.baseSymbol(incoming).lowercased() == existing.lowercased()
        else { return }
        investments[index].symbol = incoming
    }

    /// Upserts a holding into an investment's holdings array.
    /// Matches by (broker, accountType). If found, updates shares. Otherwise appends.
    private func upsertHolding(_ holding: Holding, at index: Int) {
        let brokerNorm = Self.normalizeBroker(holding.broker)
        let typeLower = holding.accountType.lowercased()
        if let hIdx = investments[index].holdings.firstIndex(where: {
            Self.normalizeBroker($0.broker) == brokerNorm && $0.accountType.lowercased() == typeLower
        }) {
            investments[index].holdings[hIdx].shares = holding.shares
        } else {
            investments[index].holdings.append(holding)
        }
    }

    /// Normalizes broker name for matching — lowercased, whitespace/punctuation stripped.
    static func normalizeBroker(_ name: String) -> String {
        normalizeName(name)
    }

    /// Normalizes a name for matching — lowercased, whitespace/punctuation stripped.
    private static func normalizeName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Currencies with a fixed rate to GBP that never need fetching.
    private static let fixedRateCurrencies: Set<String> = ["GBP", "GBX"]

    /// Fetches exchange rates to GBP for currencies used in the portfolio.
    /// - Parameter refreshAll: If true, refetches every non-fixed currency; otherwise only currencies with no rate yet.
    private func fetchExchangeRates(refreshAll: Bool = false) async {
        // Collect all unique currency codes that need conversion
        let currenciesNeeded = Set(investments.map(\.currencyCode))
            .subtracting(refreshAll ? Self.fixedRateCurrencies : Set(exchangeRates.keys))
        await fetchRates(for: currenciesNeeded)
    }

    /// Fetches rates for any of the given currencies that don't have one yet.
    /// - Returns: Currencies whose rate is still unavailable after fetching (e.g. offline).
    func ensureExchangeRates(for currencies: Set<String>) async -> Set<String> {
        await fetchRates(for: currencies.subtracting(exchangeRates.keys))
        return currencies.subtracting(exchangeRates.keys)
    }

    /// Fetches the GBP rate for each currency concurrently and stores it in `exchangeRates`.
    private func fetchRates(for currencies: Set<String>) async {
        await withTaskGroup(of: (String, Double)?.self) { group in
            for currency in currencies {
                let pair = "\(currency)GBP=X"
                group.addTask {
                    guard let quote = await self.fetchYahooQuote(for: pair) else { return nil }
                    let rate = quote.price
                    return (currency, rate)
                }
            }

            for await result in group {
                if let (currency, rate) = result {
                    exchangeRates[currency] = rate
                }
            }
        }
    }

    /// Fetches a quote from Yahoo Finance's chart API.
    /// Works for both stock symbols (e.g. "AAPL") and forex pairs (e.g. "USDGBP=X"),
    /// since Yahoo uses the same endpoint for both.
    /// If the symbol fails, retries with common exchange suffixes (.L, .DE, .PA, etc.).
    /// Returns the price/rate and the currency it's denominated in.
    private nonisolated func fetchYahooQuote(for symbol: String) async -> YahooQuote? {
        // Try the symbol as-is first
        if let result = await fetchYahooQuoteDirect(for: symbol) {
            return result
        }

        // If it already has a suffix or is a forex pair, don't retry
        if symbol.contains(".") || symbol.contains("=") {
            return nil
        }

        // Retry with common exchange suffixes
        let suffixes = [".L", ".DE", ".PA", ".AS", ".MI", ".SW"]
        for suffix in suffixes {
            if let result = await fetchYahooQuoteDirect(for: symbol + suffix) {
                return result
            }
        }

        return nil
    }

    private nonisolated func fetchYahooQuoteDirect(for symbol: String) async -> YahooQuote? {
        guard let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encodedSymbol)?range=1d&interval=1d")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await http.send(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
            guard let meta = decoded.chart.result?.first?.meta else { return nil }
            let price = meta.regularMarketPrice
            // Yahoo returns "GBp" (pence) for some London-listed securities — normalize to GBX
            let currency = meta.currency == "GBp" ? "GBX" : (meta.currency ?? "USD")
            return YahooQuote(
                price: price,
                currency: currency,
                instrumentType: meta.instrumentType,
                name: meta.longName ?? meta.shortName
            )
        } catch {
            return nil
        }
    }

    /// Searches Yahoo Finance for symbols matching a name or ticker (e.g. "Sui" → SUI20947-USD).
    nonisolated func searchYahoo(_ query: String) async -> [YahooSearchResult] {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "quotesCount", value: "8"),
            URLQueryItem(name: "newsCount", value: "0")
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        struct SearchResponse: Decodable {
            let quotes: [YahooSearchResult]?
        }
        guard let (data, response) = try? await http.send(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SearchResponse.self, from: data)
        else { return [] }
        return (decoded.quotes ?? []).filter { $0.symbol != nil }
    }
}

/// A live quote from Yahoo's chart API.
struct YahooQuote: Sendable {
    let price: Double
    let currency: String
    /// Yahoo's instrument type, e.g. "EQUITY", "ETF", "CRYPTOCURRENCY", "FUTURE"
    let instrumentType: String?
    let name: String?
}

/// One result from Yahoo's symbol search.
struct YahooSearchResult: Decodable, Sendable {
    let symbol: String?
    let quoteType: String?
    let shortname: String?
    let longname: String?
    let exchange: String?

    var displayName: String { longname ?? shortname ?? symbol ?? "" }
}
