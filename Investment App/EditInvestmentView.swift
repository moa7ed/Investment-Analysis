//
//  EditInvestmentView.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/09/2026.
//

import SwiftUI

struct EditInvestmentView: View {
    @State private var investment: Investment
    @State private var nameText: String
    @State private var symbolText: String
    @State private var manualPriceText: String
    @State private var currencyCode: String
    @State private var manualValueText: String
    @State private var targetPctText: String
    @State private var sectorText: String
    @State private var holdings: [Holding]
    @State private var newBroker = ""
    @State private var newAccountType = "Invest"
    @Environment(\.dismiss) private var dismiss

    let knownSectors: [String]
    let exchangeRates: [String: Double]
    let onSave: (Investment) -> Void

    init(investment: Investment, knownSectors: [String], exchangeRates: [String: Double] = [:], onSave: @escaping (Investment) -> Void) {
        _investment = State(initialValue: investment)
        _nameText = State(initialValue: investment.name)
        _symbolText = State(initialValue: investment.symbol ?? "")
        _manualPriceText = State(initialValue: investment.manualPrice.map { String($0) } ?? "")
        _currencyCode = State(initialValue: investment.currencyCode)
        _manualValueText = State(initialValue: investment.manualValue.map { String($0) } ?? "")
        _targetPctText = State(initialValue: String(investment.targetPercentage))
        _sectorText = State(initialValue: investment.sectorOrDefault)
        _holdings = State(initialValue: investment.holdings)
        self.knownSectors = knownSectors
        self.exchangeRates = exchangeRates
        self.onSave = onSave
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
                    ForEach($holdings.indices, id: \.self) { index in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(holdings[index].broker)
                                    .font(.subheadline)
                                Text(holdings[index].accountType)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("Shares", value: $holdings[index].shares, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                        }
                    }
                    .onDelete { indexSet in
                        holdings.remove(atOffsets: indexSet)
                    }

                    // Add new holding
                    HStack {
                        TextField("Broker", text: $newBroker)
                        TextField("Type", text: $newAccountType)
                            .frame(width: 70)
                        Button {
                            let broker = newBroker.trimmingCharacters(in: .whitespaces)
                            guard !broker.isEmpty else { return }
                            holdings.append(Holding(broker: broker, accountType: newAccountType, shares: 0))
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
                    if let manualVal = Double(manualValueText), manualVal > 0 {
                        let rate = exchangeRates[currencyCode] ?? 1.0
                        let gbpValue = manualVal * rate
                        if currencyCode != "GBP" {
                            LabeledContent("Value in GBP") {
                                Text(gbpValue, format: .currency(code: "GBP").precision(.fractionLength(0)))
                            }
                        }
                    } else if manualValueText.isEmpty {
                        let totalShares = holdings.reduce(0.0) { $0 + $1.shares }
                        let price = Double(manualPriceText) ?? investment.apiPrice ?? 0
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
                        investment.manualPrice = Double(manualPriceText)
                        investment.currencyCode = currencyCode
                        investment.manualValue = Double(manualValueText)
                        investment.holdings = holdings
                        investment.targetPercentage = Double(targetPctText) ?? 0
                        investment.sector = sectorText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? nil : sectorText.trimmingCharacters(in: .whitespaces)
                        onSave(investment)
                        dismiss()
                    }
                    .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
