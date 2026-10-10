//
//  EditInvestmentView.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/09/2026.
//

import SwiftUI

struct EditInvestmentView: View {
    /// Editable copy of a holding. Shares are kept as text so they're parsed with the device's number format,
    /// and each row has a stable ID so deleting rows can't mix up which field belongs to which holding.
    private struct HoldingDraft: Identifiable {
        let id = UUID()
        var broker: String
        var accountType: String
        var sharesText: String
    }

    @State private var investment: Investment
    @State private var nameText: String
    @State private var symbolText: String
    @State private var manualPriceText: String
    @State private var currencyCode: String
    @State private var manualValueText: String
    @State private var targetPctText: String
    @State private var sectorText: String
    @State private var holdingDrafts: [HoldingDraft]
    @State private var newBroker = ""
    @State private var newAccountType = "Invest"
    @Environment(\.dismiss) private var dismiss

    let knownSectors: [String]
    let exchangeRates: [String: Double]
    let onSave: (Investment) -> Void
    /// When set, shows a Delete button. Nil for new investments and for the protected Cash investment.
    let onDelete: (() -> Void)?
    @State private var showDeleteConfirmation = false

    init(investment: Investment, knownSectors: [String], exchangeRates: [String: Double] = [:], onSave: @escaping (Investment) -> Void, onDelete: (() -> Void)? = nil) {
        _investment = State(initialValue: investment)
        _nameText = State(initialValue: investment.name)
        _symbolText = State(initialValue: investment.symbol ?? "")
        _manualPriceText = State(initialValue: investment.manualPrice.map(NumberText.format) ?? "")
        _currencyCode = State(initialValue: investment.currencyCode)
        _manualValueText = State(initialValue: investment.manualValue.map(NumberText.format) ?? "")
        _targetPctText = State(initialValue: NumberText.format(investment.targetPercentage))
        _sectorText = State(initialValue: investment.sectorOrDefault)
        _holdingDrafts = State(initialValue: investment.holdings.map {
            HoldingDraft(broker: $0.broker, accountType: $0.accountType, sharesText: NumberText.format($0.shares))
        })
        self.knownSectors = knownSectors
        self.exchangeRates = exchangeRates
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Investment") {
                    TextField("Name", text: $nameText)
                    TextField("Symbol (e.g. AAPL)", text: $symbolText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }

                Section("Price") {
                    if let apiPrice = investment.apiPrice {
                        LabeledContent("Market Price") {
                            Text(apiPrice, format: .currency(code: investment.currencyCode))
                        }
                    } else {
                        Text("No market price available")
                            .foregroundStyle(.secondary)
                    }
                    TextField("Price override", text: $manualPriceText)
                        .keyboardType(.decimalPad)
                    invalidHint(manualPriceText)
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(["USD", "GBP", "EUR", "GBX"], id: \.self) { code in
                            Text(code).tag(code)
                        }
                        if !["USD", "GBP", "EUR", "GBX"].contains(currencyCode) {
                            Text(currencyCode).tag(currencyCode)
                        }
                    }
                }

                Section("Holdings") {
                    ForEach($holdingDrafts) { $draft in
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(draft.broker)
                                        .font(.subheadline)
                                    Text(draft.accountType)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                TextField("Shares", text: $draft.sharesText)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 100)
                            }
                            invalidHint(draft.sharesText)
                        }
                    }
                    .onDelete { indexSet in
                        holdingDrafts.remove(atOffsets: indexSet)
                    }

                    // Add new holding
                    HStack {
                        TextField("Broker", text: $newBroker)
                        TextField("Type", text: $newAccountType)
                            .frame(width: 70)
                        Button {
                            let broker = newBroker.trimmingCharacters(in: .whitespaces)
                            guard !broker.isEmpty else { return }
                            holdingDrafts.append(HoldingDraft(broker: broker, accountType: newAccountType, sharesText: "0"))
                            newBroker = ""
                            newAccountType = "Invest"
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newBroker.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section("Value Override") {
                    TextField("Manual value in \(currencyCode) (leave empty for shares × price)", text: $manualValueText)
                        .keyboardType(.decimalPad)
                    invalidHint(manualValueText)
                    if let manualVal = NumberText.parse(manualValueText), manualVal > 0 {
                        let rate = exchangeRates[currencyCode] ?? 1.0
                        let gbpValue = manualVal * rate
                        if currencyCode != "GBP" {
                            LabeledContent("Value in GBP") {
                                Text(gbpValue, format: .currency(code: "GBP").precision(.fractionLength(0)))
                            }
                        }
                    } else if NumberText.isEmpty(manualValueText) {
                        let totalShares = holdingDrafts.reduce(0.0) { $0 + (NumberText.parse($1.sharesText) ?? 0) }
                        let price = NumberText.parse(manualPriceText) ?? investment.apiPrice ?? 0
                        let nativeValue = price * totalShares
                        let rate = exchangeRates[currencyCode] ?? 1.0
                        let gbpValue = nativeValue * rate
                        if nativeValue > 0 {
                            if currencyCode != "GBP" {
                                LabeledContent("Computed Value") {
                                    Text(nativeValue, format: .currency(code: currencyCode).precision(.fractionLength(0)))
                                }
                            }
                            LabeledContent("Value in GBP") {
                                Text(gbpValue, format: .currency(code: "GBP").precision(.fractionLength(0)))
                            }
                        }
                    }
                }

                Section("Target Allocation") {
                    HStack {
                        TextField("Target %", text: $targetPctText)
                            .keyboardType(.decimalPad)
                        Text("%")
                            .foregroundStyle(.secondary)
                    }
                    invalidHint(targetPctText)
                }

                Section("Sector") {
                    Picker("Sector", selection: $sectorText) {
                        ForEach(knownSectors, id: \.self) { sector in
                            Text(sector).tag(sector)
                        }
                        if !knownSectors.contains(sectorText) {
                            Text(sectorText).tag(sectorText)
                        }
                    }
                    TextField("Or type a custom sector", text: $sectorText)
                }

                if onDelete != nil {
                    Section {
                        Button("Delete Investment", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .alert("Delete \(investment.name)?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
            } message: {
                Text("This removes all its holdings and can't be undone.")
            }
            .navigationTitle(nameText.isEmpty ? "New Investment" : nameText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        investment.name = nameText.trimmingCharacters(in: .whitespaces)
                        let trimmedSymbol = symbolText.trimmingCharacters(in: .whitespaces)
                        investment.symbol = trimmedSymbol.isEmpty ? nil : trimmedSymbol
                        investment.manualPrice = NumberText.parse(manualPriceText)
                        investment.currencyCode = currencyCode
                        investment.manualValue = NumberText.parse(manualValueText)
                        investment.holdings = holdingDrafts.map {
                            Holding(broker: $0.broker, accountType: $0.accountType, shares: NumberText.parse($0.sharesText) ?? 0)
                        }
                        investment.targetPercentage = NumberText.parse(targetPctText) ?? 0
                        investment.sector = sectorText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? nil : sectorText.trimmingCharacters(in: .whitespaces)
                        onSave(investment)
                        dismiss()
                    }
                    .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty || hasInvalidNumber)
                }
            }
        }
    }

    /// True if any numeric field contains text that isn't a valid number — Save is blocked so nothing is silently dropped.
    private var hasInvalidNumber: Bool {
        ([manualPriceText, manualValueText, targetPctText] + holdingDrafts.map(\.sharesText))
            .contains(where: NumberText.isInvalid)
    }

    @ViewBuilder
    private func invalidHint(_ text: String) -> some View {
        if NumberText.isInvalid(text) {
            Text("Invalid number")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// Parses and formats numbers using the device's region settings (decimal separator, grouping, digits).
/// Parsing is strict: text that isn't entirely a valid non-negative number returns nil rather than a partial value.
private enum NumberText {
    private static let parser: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        formatter.minimum = 0
        return formatter
    }()

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        return formatter
    }()

    static func isEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The parsed value, or nil if the text is empty or invalid.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return parser.number(from: trimmed)?.doubleValue
    }

    /// Non-empty text that can't be parsed.
    static func isInvalid(_ text: String) -> Bool {
        !isEmpty(text) && parse(text) == nil
    }

    /// Formats without trailing ".0" or grouping, e.g. 5 → "5", 12.5 → "12.5" (or "12,5" in comma regions).
    static func format(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
