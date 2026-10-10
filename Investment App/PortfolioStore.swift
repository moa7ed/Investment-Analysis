//
//  PortfolioStore.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/09/2026.
//

import Foundation
import Observation

// MARK: - Claude API

private enum ClaudeAPI {
    static let apiKey: String = {
        guard let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path),
              let key = dict["CLAUDE_API_KEY"] as? String else {
            fatalError("Missing Secrets.plist or CLAUDE_API_KEY. See README for setup instructions.")
        }
        return key
    }()
    static let model = "claude-opus-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Sends a prompt to Claude and returns the text response, or nil on failure.
    static func ask(_ prompt: String, maxTokens: Int = 4096) async -> String? {
        await askWithContent([["type": "text", "text": prompt]], maxTokens: maxTokens)
    }

    /// Sends multi-content blocks (text + images/documents) to Claude and returns the text response.
    static func askWithContent(_ contentBlocks: [[String: Any]], maxTokens: Int = 4096) async -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("pdfs-2024-09-25", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": contentBlocks]]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("[ClaudeAPI] HTTP \(http.statusCode): \(body)")
                return nil
            }

            struct Response: Decodable {
                let content: [Block]
                struct Block: Decodable {
                    let type: String?
                    let text: String?
                }
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.content.first(where: { $0.type == "text" })?.text
        } catch {
            print("[ClaudeAPI] Error: \(error)")
            return nil
        }
    }
}

// MARK: - Statement Import Models

struct ParsedStatementEntry: Identifiable, Decodable {
    let id = UUID()
    let name: String
    let symbol: String?
    let shares: Double
    let value: Double?
    let price: Double?
    let currencyCode: String?
    let category: String?
    let accountType: String?
    let broker: String?

    private enum CodingKeys: String, CodingKey {
        case name, symbol, shares, value, price, currencyCode, category, accountType, broker
    }

    init(name: String, symbol: String?, shares: Double, value: Double?, price: Double?, currencyCode: String?, category: String?, accountType: String?, broker: String?) {
        self.name = name
        self.symbol = symbol
        self.shares = shares
        self.value = value
        self.price = price
        self.currencyCode = currencyCode
        self.category = category
        self.accountType = accountType
        self.broker = broker
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

    private let userDefaultsKey = "portfolio_investments"
    private let dataResetKey = "data_reset_v8_cash_consolidation"
    static let defaultMaxSectors = 8

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
            async let ratesTask: Void = fetchExchangeRates()

            await withTaskGroup(of: (UUID, Double, String)?.self) { group in
                for investment in investments where investment.symbol != nil {
                    let id = investment.id
                    let symbol = investment.symbol!
                    group.addTask {
                        guard let quote = await self.fetchYahooQuote(for: symbol) else {
                            print("[fetchAllPrices] No price found for symbol: \(symbol)")
                            return nil
                        }
                        return (id, quote.price, quote.currency)
                    }
                }

                for await result in group {
                    guard !Task.isCancelled else { break }
                    if let (id, price, currency) = result,
                       let index = investments.firstIndex(where: { $0.id == id }) {
                        investments[index].apiPrice = price
                        investments[index].currencyCode = currency
                    }
                }
            }

            await ratesTask

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
    ///   - forceAll: If true, reclassifies all investments (clears existing sectors first)
    func classifySectors(maxSectors: Int = defaultMaxSectors, additionalPrompt: String = "", forceAll: Bool = false) async {
        if forceAll {
            for i in investments.indices {
                investments[i].sector = nil
            }
        }

        let unclassified = investments.filter { $0.sector == nil }
        guard !unclassified.isEmpty else { return }

        let entries = investments.map { inv in
            "\(inv.name) (\(inv.symbol ?? "N/A"), \(inv.category))"
        }
        let unclassifiedNames = Set(unclassified.map(\.name))

        var prompt = """
        I have a portfolio of investments. Analyze them and:
        1. Determine the best set of sector categories (maximum \(maxSectors) sectors) that meaningfully represent this portfolio.
        2. Assign each investment to exactly one sector.

        Use short, clear sector names (e.g. "Tech", "Crypto", "Commodities", "Index Funds", "Auto", "Finance").
        
        Keep Cash, in its own Sector

        Investments:
        \(entries.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        Respond with ONLY a JSON object mapping each investment name (exactly as given) to its sector name. Example:
        {"Google": "Tech", "Bitcoin": "Crypto", "S&P 500": "Index Funds"}

        Every investment must be assigned. Use at most \(maxSectors) sectors total.
        """

        if !additionalPrompt.trimmingCharacters(in: .whitespaces).isEmpty {
            prompt += "\n\nAdditional instructions: \(additionalPrompt)"
        }

        guard let text = await ClaudeAPI.ask(prompt) else { return }

        // Strip markdown code fences if present
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleaned.data(using: .utf8),
              let mapping = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String]
        else { return }

        for (name, sectorName) in mapping {
            if unclassifiedNames.contains(name),
               let index = investments.firstIndex(where: { $0.name == name }) {
                investments[index].sector = sectorName
            }
        }

        saveToUserDefaults()
    }

    // MARK: - Statement Import

    /// Parses a broker statement (PDF or image) by sending it to Claude's vision API.
    func parseStatement(data: Data, mimeType: String) async -> [ParsedStatementEntry]? {
        let base64String = data.base64EncodedString()

        let sourceBlock: [String: Any]
        if mimeType == "application/pdf" {
            sourceBlock = [
                "type": "document",
                "source": ["type": "base64", "media_type": mimeType, "data": base64String]
            ]
        } else {
            sourceBlock = [
                "type": "image",
                "source": ["type": "base64", "media_type": mimeType, "data": base64String]
            ]
        }

        let textBlock: [String: Any] = [
            "type": "text",
            "text": """
            Analyze this broker account statement. Extract every investment/holding listed.

            For each investment, provide:
            - "name": The investment name (e.g., "Apple", "Vanguard S&P 500 ETF")
            - "symbol": The Yahoo Finance ticker symbol (e.g., "AAPL", "VUSA.L", "VOW3.DE"), or null. If the statement shows a different symbol, convert it to the Yahoo Finance equivalent. Include exchange suffixes for non-US stocks (e.g., ".L" for London, ".DE" for Frankfurt, ".PA" for Paris).
            - "shares": Number of shares/units held (as a number)
            - "price": The price per share/unit if shown (as a number), or null
            - "value": Total value if shown (as a number), or null. If not shown but price and shares are available, calculate it.
            - "currencyCode": The currency code (e.g., "USD", "GBP", "EUR", "GBX"). Use the currency shown in the statement. Default to "GBP" if unclear.
            - "category": Classify the investment into one of these categories: "Stock", "ETF", "Crypto", "Commodity", "Cash", "Real Estate". Rules:
              - Cryptocurrencies (Bitcoin, Ethereum, Solana, etc.) or symbols ending in "-USD" → "Crypto"
              - ETFs, index funds, iShares, Vanguard funds, or London-listed funds (.L suffix) → "ETF"
              - Gold, silver, metals, commodities → "Commodity"
              - Cash holdings → "Cash"
              - REITs, real estate → "Real Estate"
              - Individual company stocks → "Stock"
            - "accountType": The account type, e.g. "ISA" for ISA wrappers, "Invest" for general/non-ISA investment accounts, "General" if unclear
            - "broker": The broker/platform name if identifiable (e.g., "Trading 212", "Revolut", "Schwab", "Coinbase"), or null

            Respond with ONLY a JSON array. Example:
            [{"name": "Apple", "symbol": "AAPL", "shares": 10.5, "price": 223.45, "value": 2346.23, "currencyCode": "USD", "category": "Stock", "accountType": "Invest", "broker": "Trading 212"}]

            Important:
            - Include ALL investments/holdings shown
            - Use the exact share/unit counts shown
            - If the statement shows ISA and non-ISA sections separately, set accountType accordingly ("ISA" or "Invest")
            - Return an empty array [] if no investments are found
            """
        ]

        guard let text = await ClaudeAPI.askWithContent([sourceBlock, textBlock], maxTokens: 16384) else { return nil }

        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleaned.data(using: .utf8) else { return nil }

        do {
            return try JSONDecoder().decode([ParsedStatementEntry].self, from: jsonData)
        } catch {
            print("[parseStatement] JSON decode error: \(error)")
            print("[parseStatement] Raw response: \(cleaned)")
            return nil
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
        let cashEntries = entries.filter { ($0.category ?? "").lowercased() == "cash" }
        let regularEntries = entries.filter { ($0.category ?? "").lowercased() != "cash" }

        // Consolidate all cash entries into the "Cash" investment
        if !cashEntries.isEmpty {
            applyCashEntries(cashEntries)
        }

        for entry in regularEntries {
            let brokerName = entry.broker ?? "Unknown"
            let acctType = entry.accountType ?? "Invest"
            let holding = Holding(broker: brokerName, accountType: acctType, shares: entry.shares)

            if let idx = matchingInvestmentIndex(forSymbol: entry.symbol) {
                upsertHolding(holding, at: idx)
            } else {
                let newInvestment = Investment(
                    name: entry.name,
                    symbol: baseSymbol(entry.symbol),
                    category: entry.category ?? "Stock",
                    currencyCode: entry.currencyCode ?? "GBP",
                    holdings: [holding]
                )
                investments.append(newInvestment)
            }
        }

        saveToUserDefaults()
    }

    /// Consolidates cash entries into the "Cash" investment.
    /// Sums all cash values (converting to GBP if needed) under a single "General" holding
    /// for the entry's broker. Only updates if the total differs from the existing holding.
    private func applyCashEntries(_ cashEntries: [ParsedStatementEntry]) {
        ensureCashInvestmentExists()
        guard let cashIdx = investments.firstIndex(where: { $0.name == "Cash" }) else { return }

        // Group by broker and sum values, converting to GBP
        var totalByBroker: [String: Double] = [:]
        for entry in cashEntries {
            let broker = entry.broker ?? "Unknown"
            let value = entry.value ?? (entry.shares * (entry.price ?? 1))
            let currency = entry.currencyCode ?? "GBP"
            let rate = exchangeRates[currency] ?? 1.0
            let gbpValue = value * rate
            totalByBroker[broker, default: 0] += gbpValue
        }

        // Upsert a single "General" holding per broker
        for (broker, gbpTotal) in totalByBroker {
            let holding = Holding(broker: broker, accountType: "General", shares: gbpTotal)
            let brokerNorm = Self.normalizeBroker(broker)
            if let hIdx = investments[cashIdx].holdings.firstIndex(where: {
                Self.normalizeBroker($0.broker) == brokerNorm && $0.accountType.lowercased() == "general"
            }) {
                if investments[cashIdx].holdings[hIdx].shares != gbpTotal {
                    investments[cashIdx].holdings[hIdx].shares = gbpTotal
                }
            } else {
                investments[cashIdx].holdings.append(holding)
            }
        }
    }

    /// Finds an existing investment matching the given symbol.
    /// Compares the full symbol and the base (without exchange suffix, e.g. "VUSA" from "VUSA.L").
    /// Returns nil if no match is found or if symbol is nil.
    func matchingInvestment(forSymbol symbol: String?) -> Investment? {
        guard let idx = matchingInvestmentIndex(forSymbol: symbol) else { return nil }
        return investments[idx]
    }

    private func matchingInvestmentIndex(forSymbol symbol: String?) -> Int? {
        guard let symbol else { return nil }
        let symbolLower = symbol.lowercased()
        let symbolBase = symbolLower.split(separator: ".").first.map(String.init) ?? symbolLower
        return investments.firstIndex(where: {
            guard let existing = $0.symbol?.lowercased() else { return false }
            let existingBase = existing.split(separator: ".").first.map(String.init) ?? existing
            return existing == symbolLower || existingBase == symbolBase
        })
    }

    /// Strips the exchange suffix from a symbol (e.g. "VUSA.L" → "VUSA").
    private func baseSymbol(_ symbol: String?) -> String? {
        guard let symbol else { return nil }
        return symbol.split(separator: ".").first.map(String.init) ?? symbol
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
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Fetches exchange rates to GBP for all currencies used in the portfolio.
    private func fetchExchangeRates() async {
        // Collect all unique currency codes that need conversion
        let currenciesNeeded = Set(investments.map(\.currencyCode))
            .subtracting(exchangeRates.keys) // skip GBP, GBX (already known)

        await withTaskGroup(of: (String, Double)?.self) { group in
            for currency in currenciesNeeded {
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
