//
//  StatementImportView.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 04/10/2026.
//

import SwiftUI

private struct EntryChanges {
    let changes: [String]
    static let empty = EntryChanges(changes: [])
}

struct StatementImportPreviewSheet: View {
    /// Editable so the user can override each entry's match before applying.
    @State private var entries: [ParsedStatementEntry]
    let store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    /// The broker every entry is recorded under. Holdings are keyed by broker, so the user confirms it before applying.
    @State private var brokerText: String
    /// Whether Claude found a broker name in the statement (affects the hint shown).
    private let brokerWasDetected: Bool

    /// The file this statement came from, e.g. "statement.pdf (2 of 5)".
    private let sourceLabel: String?

    init(entries: [ParsedStatementEntry], store: PortfolioStore, sourceLabel: String? = nil) {
        self.sourceLabel = sourceLabel
        _entries = State(initialValue: entries)
        let detected = entries.compactMap(\.broker).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        _brokerText = State(initialValue: detected ?? "")
        brokerWasDetected = detected != nil
        self.store = store
    }

    private var trimmedBroker: String {
        brokerText.trimmingCharacters(in: .whitespaces)
    }

    /// nil = use the account type Claude detected per entry (handles statements with both ISA and Invest sections).
    @State private var accountTypeOverride: String?

    /// Account types offered in the picker: the common ones plus any already used in the portfolio.
    private var accountTypeOptions: [String] {
        var seen = Set<String>()
        return (["ISA", "Invest"] + store.investments.flatMap(\.holdings).map(\.accountType))
            .filter { $0 != "General" && seen.insert($0.lowercased()).inserted }
    }

    /// Entries with the confirmed broker (and account type, if forced) applied — used for the preview and for Apply.
    private var effectiveEntries: [ParsedStatementEntry] {
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
    private var knownBrokers: [String] {
        var seen = Set<String>()
        return store.investments
            .flatMap(\.holdings)
            .map(\.broker)
            .filter { $0 != "Unknown" && seen.insert(PortfolioStore.normalizeBroker($0)).inserted }
            .sorted()
    }

    /// Existing investments a regular entry can be matched to (Cash is matched automatically).
    private var matchCandidates: [Investment] {
        store.investments.filter { $0.category.lowercased() != "cash" }
    }

    /// Entries for display: cash is aggregated per (broker, account type) exactly as Apply does; regular entries pass through.
    private var displayEntries: [ParsedStatementEntry] {
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Broker name", text: $brokerText)
                        .autocorrectionDisabled()
                    if !knownBrokers.isEmpty {
                        Menu("Choose an existing broker") {
                            ForEach(knownBrokers, id: \.self) { broker in
                                Button(broker) { brokerText = broker }
                            }
                        }
                    }
                } header: {
                    Text("Broker")
                } footer: {
                    if trimmedBroker.isEmpty {
                        Text("No broker name was found in the statement. Enter one to continue — it decides which holdings are updated.")
                            .foregroundStyle(.red)
                    } else if brokerWasDetected {
                        Text("Detected from the statement. Check it's correct — it decides which holdings are updated.")
                    }
                }

                Section {
                    Picker("Account Type", selection: $accountTypeOverride) {
                        Text("As detected").tag(String?.none)
                        ForEach(accountTypeOptions, id: \.self) { type in
                            Text(type).tag(String?.some(type))
                        }
                    }
                } footer: {
                    Text(accountTypeOverride == nil
                         ? "Uses the account type found for each entry. Choose one to apply it to the whole statement."
                         : "Every entry, including cash, is recorded under \(accountTypeOverride ?? "").")
                }

                Section {
                    if let sourceLabel {
                        LabeledContent("Statement", value: sourceLabel)
                    }
                    LabeledContent("Investments Found", value: "\(displayEntries.count)")
                    LabeledContent("Matched to Existing") {
                        Text("\(matchedCount)")
                            .foregroundStyle(.green)
                    }
                    if updateCount > 0 {
                        LabeledContent("Will Be Updated") {
                            Text("\(updateCount)")
                                .foregroundStyle(.orange)
                        }
                    }
                    LabeledContent("New Investments") {
                        Text("\(newCount)")
                            .foregroundStyle(.blue)
                    }
                    if !accountTypes.isEmpty {
                        LabeledContent("Account Types", value: accountTypes.joined(separator: ", "))
                    }
                }

                Section("Investments") {
                    ForEach(displayEntries) { entry in
                        entryRow(entry)
                    }
                }
            }
            .navigationTitle("Import Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let toApply = effectiveEntries
                        Task {
                            store.applyStatementEntries(toApply)
                            await store.fetchAllPrices()
                        }
                        dismiss()
                    }
                    .disabled(trimmedBroker.isEmpty)
                }
            }
        }
    }

    // MARK: - Entry Row

    @ViewBuilder
    private func entryRow(_ entry: ParsedStatementEntry) -> some View {
        let matched = matchedInvestment(for: entry)
        let changes = matched.map { computeChanges(entry: entry, existing: $0) } ?? .empty
        VStack(alignment: .leading, spacing: 4) {
            // Name + badges
            HStack(spacing: 6) {
                Text(entry.name)
                    .font(.subheadline.bold())
                if let accountType = entry.accountType {
                    Text(accountType)
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }
                if matched == nil {
                    Text("NEW")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue)
                        .clipShape(Capsule())
                } else if !changes.changes.isEmpty {
                    Text("UPDATE")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange)
                        .clipShape(Capsule())
                }
            }

            // Lets the user correct a wrong automatic match (or force a new investment)
            if !entry.isCash {
                Picker("Match to", selection: matchSelection(for: entry.id)) {
                    Text("New investment").tag(UUID?.none)
                    ForEach(matchCandidates) { investment in
                        Text("\(investment.name) (\(investment.symbol ?? "no symbol"))")
                            .tag(UUID?.some(investment.id))
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
            }

            // Symbol, shares, value
            HStack(spacing: 8) {
                if let symbol = entry.symbol {
                    Text(symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(entry.shares.formatted()) shares")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let value = entry.value {
                    Text(value.formatted(.currency(code: entry.currencyCode ?? "GBP").precision(.fractionLength(0))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let broker = entry.broker {
                    Spacer()
                    Text([broker, entry.accountType].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Change details for matched investments
            if matched != nil, !changes.changes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(changes.changes, id: \.self) { change in
                            Text(change)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    /// Binding for an entry's match picker: nil means "New investment".
    private func matchSelection(for entryID: UUID) -> Binding<UUID?> {
        Binding(
            get: {
                entries.first(where: { $0.id == entryID }).flatMap { matchedInvestment(for: $0)?.id }
            },
            set: { newValue in
                guard let i = entries.firstIndex(where: { $0.id == entryID }) else { return }
                entries[i].matchedInvestmentID = newValue
                entries[i].isForcedNew = newValue == nil
            }
        )
    }

    private var matchedCount: Int {
        displayEntries.filter { matchedInvestment(for: $0) != nil }.count
    }

    private var updateCount: Int {
        displayEntries.filter { entry in
            guard let existing = matchedInvestment(for: entry) else { return false }
            return !computeChanges(entry: entry, existing: existing).changes.isEmpty
        }.count
    }

    private var newCount: Int {
        displayEntries.filter { matchedInvestment(for: $0) == nil }.count
    }

    private var accountTypes: [String] {
        Array(Set(effectiveEntries.map(\.resolvedAccountType))).sorted()
    }

    /// Computes changes between an entry and an existing investment.
    private func computeChanges(entry: ParsedStatementEntry, existing: Investment) -> EntryChanges {
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

    /// Finds the existing investment that matches this entry, or nil if new.
    private func matchedInvestment(for entry: ParsedStatementEntry) -> Investment? {
        store.matchingInvestment(for: entry)
    }


}
