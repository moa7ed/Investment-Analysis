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
        maxTokens: Int = 4096
    ) async -> Result<T, ClaudeFailure> {
        // Read on every call so a key added or changed in Settings takes effect immediately
        guard let apiKey = APIKeyStore.claudeKey else { return .failure(.missingKey) }

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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.failed) }
            guard http.statusCode == 200 else {
                print("[ClaudeAPI] HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "no body")")
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

    var totalPortfolioValue: Double {
        investments.reduce(0) { $0 + valueInGBP(for: $1) }
    }

    func valueInGBP(for investment: Investment) -> Double {
        let rate = exchangeRates[investment.currencyCode] ?? 1.0
        return investment.totalValue * rate
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
        let grouped = Dictionary(grouping: investments, by: \.sectorOrDefault)
        return knownSectors.compactMap { sector in
            guard let items = grouped[sector], !items.isEmpty else { return nil }
            return (sector: sector, items: items)
        }
    }

    func sectorValue(_ sector: String) -> Double {
        investments.filter { $0.sectorOrDefault == sector }.reduce(0) { $0 + valueInGBP(for: $1) }
    }

    func sectorCurrentPercentage(_ sector: String) -> Double {
        investments.filter { $0.sectorOrDefault == sector }.reduce(0) { $0 + currentPercentage(for: $1) }
    }

    func sectorTargetPercentage(_ sector: String) -> Double {
        investments.filter { $0.sectorOrDefault == sector }.reduce(0) { $0 + $1.targetPercentage }
    }

    init() {
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
        guard !UserDefaults.standard.bool(forKey: dataResetKey) else { return }
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        UserDefaults.standard.set(true, forKey: dataResetKey)
    }

    // MARK: - Persistence

    func saveToUserDefaults() {
        if let data = try? JSONEncoder().encode(investments) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    private func loadFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([Investment].self, from: data)
        else {
            return
        }
        investments = decoded
    }

    // MARK: - Reset

    func resetAllData() {
        investments = []
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        ensureCashInvestmentExists()
    }

    // MARK: - Update

    func updateInvestment(_ investment: Investment) {
        if let index = investments.firstIndex(where: { $0.id == investment.id }) {
            investments[index] = investment
            saveToUserDefaults()
        }
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

    /// Whether Yahoo returns a price for the symbol (also tries the usual exchange suffixes).
    func hasLivePrice(symbol: String) async -> Bool {
        await fetchYahooQuote(for: symbol) != nil
    }

    // MARK: - Ticker Overrides

    /// Remembers a user-confirmed ticker for a statement holding, so future imports use it automatically.
    func rememberTicker(_ ticker: String, for entry: ParsedStatementEntry) {
        let label = entry.symbol.map { "\(entry.name) (\($0))" } ?? entry.name
        tickerOverrides[Self.overrideKey(for: entry)] = TickerOverride(label: label, ticker: ticker)
        if let data = try? JSONEncoder().encode(tickerOverrides) {
            UserDefaults.standard.set(data, forKey: tickerOverridesKey)
        }
    }

    private func loadTickerOverrides() {
        guard let data = UserDefaults.standard.data(forKey: tickerOverridesKey),
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
            await withTaskGroup(of: (UUID, (price: Double, currency: String)?).self) { group in
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

        let result = await ClaudeAPI.askJSON([["type": "text", "text": prompt]], schema: schema, as: Classification.self)
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
            - "symbol": The Yahoo Finance ticker symbol (e.g., "AAPL", "VUSA.L", "VOW3.DE"), or null. If the statement shows a different symbol, convert it to the Yahoo Finance equivalent. Include exchange suffixes for non-US stocks (e.g., ".L" for London, ".DE" for Frankfurt, ".PA" for Paris). Precious metals held directly as ounces/units (shown as XAU, XAG, XPT, XPD, or "gold"/"silver" balances) have no stock ticker: use the Yahoo futures symbol — gold "GC=F", silver "SI=F", platinum "PL=F", palladium "PA=F". Never use XAU/XAG/XPT/XPD as a symbol. Exchange-listed gold/silver funds (ETCs/ETFs such as "SGLN.L") keep their own ticker.
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
            - "accountType": The account type, e.g. "ISA" for ISA wrappers, "Invest" for general/non-ISA investment accounts, "General" if unclear
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
            maxTokens: 16384
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
    private nonisolated func fetchYahooQuote(for symbol: String) async -> (price: Double, currency: String)? {
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

    private nonisolated func fetchYahooQuoteDirect(for symbol: String) async -> (price: Double, currency: String)? {
        guard let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encodedSymbol)?range=1d&interval=1d")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
            guard let meta = decoded.chart.result?.first?.meta else { return nil }
            let price = meta.regularMarketPrice
            // Yahoo returns "GBp" (pence) for some London-listed securities — normalize to GBX
            let currency = meta.currency == "GBp" ? "GBX" : (meta.currency ?? "USD")
            return (price, currency)
        } catch {
            return nil
        }
    }
}
