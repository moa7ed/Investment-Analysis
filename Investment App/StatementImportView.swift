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
    let entries: [ParsedStatementEntry]
    let store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    /// Entries for display: cash entries are aggregated per broker, regular entries pass through.
    private var displayEntries: [ParsedStatementEntry] {
        let cashEntries = entries.filter { ($0.category ?? "").lowercased() == "cash" }
        let regularEntries = entries.filter { ($0.category ?? "").lowercased() != "cash" }

        // Aggregate cash by broker, converting to GBP
        var cashByBroker: [String: Double] = [:]
        var brokerForCash: [String: String] = [:] // normalized → original
        for entry in cashEntries {
            let broker = entry.broker ?? "Unknown"
            let norm = PortfolioStore.normalizeBroker(broker)
            let value = entry.value ?? (entry.shares * (entry.price ?? 1))
            let currency = entry.currencyCode ?? "GBP"
            let rate = store.exchangeRates[currency] ?? 1.0
            cashByBroker[norm, default: 0] += value * rate
            if brokerForCash[norm] == nil { brokerForCash[norm] = broker }
        }

        let consolidatedCash: [ParsedStatementEntry] = cashByBroker.map { (norm, gbpTotal) in
            ParsedStatementEntry(
                name: "Cash",
                symbol: nil,
                shares: gbpTotal,
                value: gbpTotal,
                price: 1,
                currencyCode: "GBP",
                category: "Cash",
                accountType: "General",
                broker: brokerForCash[norm]
            )
        }

        return regularEntries + consolidatedCash
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
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
                    if let broker = dominantBroker {
                        LabeledContent("Broker Detected", value: broker)
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
                        Task {
                            await store.applyStatementEntries(entries)
                            await store.fetchAllPrices()
                        }
                        dismiss()
                    }
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
        Array(Set(entries.compactMap(\.accountType))).sorted()
    }

    private var dominantBroker: String? {
        entries.compactMap(\.broker).first
    }

    /// Computes changes between an entry and an existing investment.
    private func computeChanges(entry: ParsedStatementEntry, existing: Investment) -> EntryChanges {
        var changes: [String] = []
        let brokerName = entry.broker ?? "Unknown"
        let brokerNorm = PortfolioStore.normalizeBroker(brokerName)

        // Cash entries are already aggregated in displayEntries — compare the GBP total
        if (entry.category ?? "").lowercased() == "cash" {
            let gbpTotal = entry.value ?? entry.shares
            if let existingHolding = existing.holdings.first(where: {
                PortfolioStore.normalizeBroker($0.broker) == brokerNorm && $0.accountType.lowercased() == "general"
            }) {
                if existingHolding.shares != gbpTotal {
                    changes.append("Cash (\(brokerName)): \(existingHolding.shares.formatted(.currency(code: "GBP").precision(.fractionLength(0)))) → \(gbpTotal.formatted(.currency(code: "GBP").precision(.fractionLength(0))))")
                }
            } else {
                changes.append("Add cash: \(brokerName) — \(gbpTotal.formatted(.currency(code: "GBP").precision(.fractionLength(0))))")
            }
            return EntryChanges(changes: changes)
        }

        let acctType = entry.accountType ?? "Invest"
        let typeLower = acctType.lowercased()
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
    /// Cash entries are matched to the "Cash" investment by name.
    private func matchedInvestment(for entry: ParsedStatementEntry) -> Investment? {
        if (entry.category ?? "").lowercased() == "cash" {
            return store.investments.first(where: { $0.name == "Cash" })
        }
        return store.matchingInvestment(forSymbol: entry.symbol)
    }


}
