//
//  ImportPreviewModel.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//

import Foundation
import Observation

/// Human-readable changes an entry will make to an existing investment.
struct EntryChanges {
    let changes: [String]
    static let empty = EntryChanges(changes: [])
}

/// Whether a holding will have a live price after import.
enum PriceCheck: Equatable {
    case notNeeded
    case checking
    /// Yahoo failed; Claude is being asked for the correct symbol
    case findingSymbol
    case ok
    /// Claude's suggested symbol passed validation and will replace the failed one
    case corrected(symbol: String, name: String?)
    /// No working symbol — the user must choose a manual option
    case missing(reason: String)
}

/// Result of the automatic symbol pipeline for one entry.
struct SymbolCheck {
    /// The pricing symbol the check ran for; if the entry's symbol changes (e.g. a new match), the check is stale
    let forSymbol: String?
    var state: PriceCheck
}

/// How the user chose to price a holding Yahoo couldn't price.
struct PriceResolution {
    enum Mode: Hashable {
        case manualPrice, fromValue, ticker
    }
    var mode: Mode?
    var priceText = ""
    var tickerText = ""
    /// The ticker text that last passed the Yahoo check
    var verifiedTicker: String?
    var isCheckingTicker = false
    /// Why the last ticker check failed, shown under the field
    var tickerError: String?
    /// Set when the ticker only failed the price-range check, so the user can choose to use it anyway
    var priceMismatchTicker: String?

    var trimmedTicker: String {
        tickerText.trimmingCharacters(in: .whitespaces).uppercased()
    }
}

/// State and logic behind the statement import preview: broker / account type overrides, match overrides,
/// the automatic symbol pipeline (Yahoo → Claude → Yahoo), manual price resolutions, and what gets applied.
@Observable
final class ImportPreviewModel {
    let store: PortfolioStore
    /// Editable so the user can override each entry's match before applying.
    var entries: [ParsedStatementEntry]
    /// The broker every entry is recorded under. Holdings are keyed by broker, so the user confirms it before applying.
    var brokerText: String
    /// Whether Claude found a broker name in the statement (affects the hint shown).
    let brokerWasDetected: Bool
    /// The file this statement came from, e.g. "statement.pdf (2 of 5)".
    let sourceLabel: String?
    /// nil = use the account type Claude detected per entry (handles statements with both ISA and Invest sections).
    var accountTypeOverride: String?
    /// Automatic symbol check results, keyed by entry ID.
    var symbolChecks: [UUID: SymbolCheck] = [:]
    /// The user's chosen fix for each entry that has no live price, keyed by entry ID.
    var priceResolutions: [UUID: PriceResolution] = [:]

    init(entries: [ParsedStatementEntry], store: PortfolioStore, sourceLabel: String? = nil) {
        self.entries = entries
        self.store = store
        self.sourceLabel = sourceLabel
        let detected = entries.compactMap(\.broker).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        brokerText = detected ?? ""
        brokerWasDetected = detected != nil
    }

    // MARK: - Derived entries

    var trimmedBroker: String {
        brokerText.trimmingCharacters(in: .whitespaces)
    }

    /// Account types offered in the picker: the common ones plus any already used in the portfolio.
    var accountTypeOptions: [String] {
        var seen = Set<String>()
        return (Holding.standardAccountTypes + store.investments.flatMap(\.holdings).map(\.accountType))
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Entries with the confirmed broker (and account type, if forced) applied — used for the preview and for Apply.
    var effectiveEntries: [ParsedStatementEntry] {
        entries.map { entry in
            var entry = entry
            entry.broker = trimmedBroker
            if let accountTypeOverride {
                entry.accountType = accountTypeOverride
            }
            return entry
        }
    }

    /// Brokers already used in the portfolio, offered as quick picks.
    var knownBrokers: [String] {
        var seen = Set<String>()
        return store.investments
            .flatMap(\.holdings)
            .map(\.broker)
            .filter { $0 != "Unknown" && seen.insert(PortfolioStore.normalizeBroker($0)).inserted }
            .sorted()
    }

    /// Existing investments a regular entry can be matched to (Cash is matched automatically).
    var matchCandidates: [Investment] {
        store.investments.filter { $0.category.lowercased() != "cash" }
    }

    /// Entries for display: cash is aggregated per (broker, account type) exactly as Apply does; regular entries pass through.
    var displayEntries: [ParsedStatementEntry] {
        let cashEntries = effectiveEntries.filter(\.isCash)
        let regularEntries = effectiveEntries.filter { !$0.isCash }

        let consolidatedCash = PortfolioStore.consolidatedCash(cashEntries, exchangeRates: store.exchangeRates).map { cash in
            ParsedStatementEntry(
                name: "Cash",
                symbol: nil,
                shares: cash.gbpTotal,
                value: cash.gbpTotal,
                price: 1,
                currencyCode: "GBP",
                category: "Cash",
                accountType: cash.accountType,
                broker: cash.broker
            )
        }

        return regularEntries + consolidatedCash
    }

    // MARK: - Matching & summary

    /// Finds the existing investment that matches this entry, or nil if new.
    func matchedInvestment(for entry: ParsedStatementEntry) -> Investment? {
        store.matchingInvestment(for: entry)
    }

    /// The investment an entry is matched to (nil = new), as shown in the "Match to" picker.
    func matchedInvestmentID(forEntry entryID: UUID) -> UUID? {
        entries.first(where: { $0.id == entryID }).flatMap { matchedInvestment(for: $0)?.id }
    }

    /// Overrides an entry's match. nil forces a new investment.
    func setMatch(forEntry entryID: UUID, to investmentID: UUID?) {
        guard let i = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[i].matchedInvestmentID = investmentID
        entries[i].isForcedNew = investmentID == nil
    }

    var matchedCount: Int {
        displayEntries.filter { matchedInvestment(for: $0) != nil }.count
    }

    var updateCount: Int {
        displayEntries.filter { entry in
            guard let existing = matchedInvestment(for: entry) else { return false }
            return !computeChanges(entry: entry, existing: existing).changes.isEmpty
        }.count
    }

    var newCount: Int {
        displayEntries.filter { matchedInvestment(for: $0) == nil }.count
    }

    var accountTypes: [String] {
        Array(Set(effectiveEntries.map(\.resolvedAccountType))).sorted()
    }

    /// Computes changes between an entry and an existing investment.
    func computeChanges(entry: ParsedStatementEntry, existing: Investment) -> EntryChanges {
        var changes: [String] = []
        let brokerName = entry.resolvedBroker
        let brokerNorm = PortfolioStore.normalizeBroker(brokerName)
        let acctType = entry.resolvedAccountType
        let typeLower = acctType.lowercased()

        // Cash entries are already aggregated per (broker, account type) in displayEntries — compare the GBP total
        if entry.isCash {
            let gbpTotal = entry.value ?? entry.shares
            if let existingHolding = existing.holdings.first(where: {
                PortfolioStore.normalizeBroker($0.broker) == brokerNorm && $0.accountType.lowercased() == typeLower
            }) {
                if existingHolding.shares != gbpTotal {
                    changes.append("Cash (\(brokerName) \(acctType)): \(existingHolding.shares.formatted(.currency(code: "GBP").precision(.fractionLength(0)))) → \(gbpTotal.formatted(.currency(code: "GBP").precision(.fractionLength(0))))")
                }
            } else {
                changes.append("Add cash: \(brokerName) · \(acctType) — \(gbpTotal.formatted(.currency(code: "GBP").precision(.fractionLength(0))))")
            }
            return EntryChanges(changes: changes)
        }

        if let existingHolding = existing.holdings.first(where: {
            PortfolioStore.normalizeBroker($0.broker) == brokerNorm && $0.accountType.lowercased() == typeLower
        }) {
            if existingHolding.shares != entry.shares {
                changes.append("Shares (\(brokerName) \(acctType)): \(existingHolding.shares.formatted()) → \(entry.shares.formatted())")
            }
        } else {
            changes.append("Add holding: \(brokerName) · \(acctType) — \(entry.shares.formatted()) shares")
        }

        return EntryChanges(changes: changes)
    }

    // MARK: - Live price check

    /// The symbol this entry will be priced with after import, or nil if it won't have one.
    func pricingSymbol(for entry: ParsedStatementEntry) -> String? {
        // A matched investment keeps its own symbol; a new one uses the statement's
        if let matched = matchedInvestment(for: entry) {
            return matched.symbol
        }
        return entry.symbol
    }

    func priceCheck(for entry: ParsedStatementEntry) -> PriceCheck {
        guard !entry.isCash else { return .notNeeded }
        if let matched = matchedInvestment(for: entry) {
            switch store.priceStatus(for: matched) {
            case .manual: return .notNeeded // already priced manually
            case .live: return .ok
            case .noLivePrice: break
            }
        }
        // No result yet, or it was for a different symbol (e.g. the match changed) → still checking
        guard let check = symbolChecks[entry.id], check.forSymbol == pricingSymbol(for: entry) else {
            return .checking
        }
        return check.state
    }

    /// True if the entry's live price depends on the automatic pipeline (not cash, and not an already-priced match).
    private func usesSymbolCheck(_ entry: ParsedStatementEntry) -> Bool {
        guard !entry.isCash else { return false }
        if let matched = matchedInvestment(for: entry), store.priceStatus(for: matched) != .noLivePrice {
            return false
        }
        return true
    }

    /// True if the entry needs the pipeline: it has never been checked, its check was for a different symbol,
    /// or a previous run was cancelled before finishing it.
    private func needsSymbolCheck(_ entry: ParsedStatementEntry) -> Bool {
        guard usesSymbolCheck(entry) else { return false }
        guard let check = symbolChecks[entry.id], check.forSymbol == pricingSymbol(for: entry) else { return true }
        return check.state == .checking || check.state == .findingSymbol
    }

    /// Drives the view's `.task` that runs the pipeline. Only changes when an entry's pricing symbol changes —
    /// not when a check starts or finishes — so a running check isn't cancelled by its own progress.
    var pendingCheckKey: [String] {
        displayEntries
            .filter(usesSymbolCheck)
            .map { "\($0.id):\(pricingSymbol(for: $0) ?? "-")" }
            .sorted()
    }

    /// Automatic pipeline: validate the symbol on Yahoo → if it fails, ask Claude (one request for all failures)
    /// → validate Claude's suggestions on Yahoo → anything still failing falls back to the manual options.
    func runSymbolChecks() async {
        let pending = displayEntries.filter(needsSymbolCheck)
        guard !pending.isEmpty else { return }
        let store = store

        let symbolByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, pricingSymbol(for: $0)) })
        for entry in pending {
            symbolChecks[entry.id] = SymbolCheck(forSymbol: symbolByID[entry.id] ?? nil, state: .checking)
        }

        // Only write results if the entry's symbol hasn't changed since this run started
        func update(_ id: UUID, _ state: PriceCheck) {
            guard !Task.isCancelled, symbolChecks[id]?.forSymbol == symbolByID[id] ?? nil else { return }
            symbolChecks[id]?.state = state
        }

        // Step 1: Yahoo
        var failed: [ParsedStatementEntry] = []
        var failedSymbols: [UUID: String] = [:]
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for entry in pending {
                guard let symbol = symbolByID[entry.id] ?? nil else {
                    group.addTask { (entry.id, false) }
                    continue
                }
                group.addTask { (entry.id, await store.validateSymbol(symbol, for: entry).isValid) }
            }
            for await (id, isValid) in group {
                if isValid {
                    update(id, .ok)
                } else if let entry = pending.first(where: { $0.id == id }) {
                    failed.append(entry)
                    failedSymbols[id] = symbolByID[id] ?? nil
                    update(id, .findingSymbol)
                }
            }
        }
        guard !failed.isEmpty, !Task.isCancelled else { return }

        // Step 2: one Claude request for every failed holding
        let suggestions = await store.suggestSymbols(for: failed, failedSymbols: failedSymbols)

        // Step 3: Yahoo again with Claude's suggestions
        await withTaskGroup(of: (UUID, PriceCheck).self) { group in
            for entry in failed {
                let original = failedSymbols[entry.id]
                guard let suggested = suggestions[entry.id] else {
                    group.addTask {
                        (entry.id, .missing(reason: "No live price for \(original ?? entry.name), and Claude couldn't find a working symbol."))
                    }
                    continue
                }
                group.addTask {
                    let validation = await store.validateSymbol(suggested, for: entry)
                    if case .valid(let quote) = validation {
                        return (entry.id, .corrected(symbol: suggested, name: quote.name))
                    }
                    let why = Self.validationMessage(validation, symbol: suggested)
                    return (entry.id, .missing(reason: "No live price for \(original ?? entry.name). Claude suggested \(suggested), but \(why)"))
                }
            }
            for await (id, state) in group {
                update(id, state)
            }
        }
    }

    /// Rejects Claude's suggested symbol, so the manual options are shown instead.
    func undoCorrection(forEntry entryID: UUID) {
        guard case .corrected(let symbol, _) = symbolChecks[entryID]?.state else { return }
        symbolChecks[entryID]?.state = .missing(reason: "You undid the suggested symbol \(symbol).")
    }

    /// Explains why a symbol failed validation, e.g. "SUI is Sun Communities, Inc. (a stock), …".
    nonisolated static func validationMessage(_ validation: PortfolioStore.SymbolValidation, symbol: String) -> String {
        let gbp = FloatingPointFormatStyle<Double>.Currency(code: "GBP")
        switch validation {
        case .valid:
            return "it's valid."
        case .noPrice:
            return "Yahoo Finance has no price for \(symbol)."
        case .typeMismatch(let quote):
            return "\(symbol) is \(quote.name ?? symbol) (\(PortfolioStore.describe(instrumentType: quote.instrumentType))), which doesn't match this holding's category."
        case .priceMismatch(_, let yahooGBP, let statementGBP):
            return "\(symbol) trades at \(yahooGBP.formatted(gbp)) per unit, but the statement shows \(statementGBP.formatted(gbp)) — it may be a different instrument."
        }
    }

    // MARK: - Manual resolution

    /// Price per unit from the statement's value, if it has one.
    func valuePerUnit(for entry: ParsedStatementEntry) -> Double? {
        guard let value = entry.value, entry.shares > 0 else { return nil }
        return value / entry.shares
    }

    func isResolved(_ entry: ParsedStatementEntry) -> Bool {
        guard let resolution = priceResolutions[entry.id], let mode = resolution.mode else { return false }
        switch mode {
        case .manualPrice: return (NumberText.parse(resolution.priceText) ?? 0) > 0
        case .fromValue: return valuePerUnit(for: entry) != nil
        case .ticker: return resolution.verifiedTicker != nil && resolution.verifiedTicker == resolution.trimmedTicker
        }
    }

    /// True while prices are being checked or any unpriced holding still needs the user's choice.
    var hasUnresolvedPrices: Bool {
        displayEntries.contains { entry in
            switch priceCheck(for: entry) {
            case .checking, .findingSymbol: true
            case .missing: !isResolved(entry)
            case .ok, .notNeeded, .corrected: false
            }
        }
    }

    /// Apply needs a broker and every holding priced.
    var canApply: Bool {
        !trimmedBroker.isEmpty && !hasUnresolvedPrices
    }

    /// Validates a ticker the user typed, with the same checks as the automatic pipeline.
    func checkTicker(for entry: ParsedStatementEntry) async {
        let id = entry.id
        let ticker = (priceResolutions[id] ?? PriceResolution()).trimmedTicker
        guard !ticker.isEmpty else { return }
        priceResolutions[id, default: PriceResolution()].isCheckingTicker = true
        let validation = await store.validateSymbol(ticker, for: entry)

        var updated = priceResolutions[id] ?? PriceResolution()
        updated.isCheckingTicker = false
        updated.verifiedTicker = validation.isValid ? ticker : nil
        updated.tickerError = validation.isValid ? nil : Self.validationMessage(validation, symbol: ticker)
        if case .priceMismatch = validation {
            updated.priceMismatchTicker = ticker
        } else {
            updated.priceMismatchTicker = nil
        }
        priceResolutions[id] = updated
    }

    /// Accepts a typed ticker that only failed the ±25% price-range check (e.g. an old statement).
    func useTickerAnyway(forEntry entryID: UUID) {
        guard let mismatched = priceResolutions[entryID]?.priceMismatchTicker,
              mismatched == priceResolutions[entryID]?.trimmedTicker
        else { return }
        priceResolutions[entryID]?.verifiedTicker = mismatched
        priceResolutions[entryID]?.tickerError = nil
    }

    // MARK: - Apply

    /// Entries ready for Apply: price choices are written in, and confirmed/corrected tickers are remembered.
    func entriesForApply() -> [ParsedStatementEntry] {
        effectiveEntries.map { entry in
            var entry = entry
            let check = priceCheck(for: entry)

            // Claude's validated correction replaces the failed symbol and is remembered for future imports
            if case .corrected(let symbol, _) = check {
                store.rememberTicker(symbol, for: entry)
                entry.symbol = symbol
                entry.symbolConfirmedByUser = true
                return entry
            }

            guard case .missing = check,
                  let resolution = priceResolutions[entry.id], let mode = resolution.mode
            else { return entry }

            switch mode {
            case .manualPrice:
                entry.manualPrice = NumberText.parse(resolution.priceText)
            case .fromValue:
                entry.manualPrice = valuePerUnit(for: entry)
            case .ticker:
                if let ticker = resolution.verifiedTicker {
                    store.rememberTicker(ticker, for: entry)
                    entry.symbol = ticker
                    entry.symbolConfirmedByUser = true
                }
            }
            return entry
        }
    }

    /// Applies the statement to the portfolio. The caller refreshes prices afterwards.
    func apply() {
        store.applyStatementEntries(entriesForApply())
    }
}
