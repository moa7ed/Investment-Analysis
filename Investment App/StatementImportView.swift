//
//  StatementImportView.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 04/10/2026.
//

import SwiftUI
import QuickLook

/// Preview of a parsed statement before it's applied. All state and logic live in `ImportPreviewModel`.
struct StatementImportPreviewSheet: View {
    @State private var model: ImportPreviewModel
    @Environment(\.dismiss) private var dismiss

    /// The original statement file, viewable from the preview so entries can be checked against it.
    private let source: StatementSource?
    /// Temporary copy of the statement shown in Quick Look; removed when Quick Look closes.
    @State private var statementFileURL: URL?
    @State private var statementOpenError: String?

    init(entries: [ParsedStatementEntry], store: PortfolioStore, sourceLabel: String? = nil, source: StatementSource? = nil) {
        _model = State(initialValue: ImportPreviewModel(entries: entries, store: store, sourceLabel: sourceLabel))
        self.source = source
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    TextField("Broker name", text: $model.brokerText)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("import.broker")
                    if !model.knownBrokers.isEmpty {
                        Menu("Choose an existing broker") {
                            ForEach(model.knownBrokers, id: \.self) { broker in
                                Button(broker) { model.brokerText = broker }
                            }
                        }
                    }
                } header: {
                    Text("Broker")
                } footer: {
                    if model.trimmedBroker.isEmpty {
                        Text("No broker name was found in the statement. Enter one to continue — it decides which holdings are updated.")
                            .foregroundStyle(.red)
                    } else if model.brokerWasDetected {
                        Text("Detected from the statement. Check it's correct — it decides which holdings are updated.")
                    }
                }

                Section {
                    Picker("Account Type", selection: $model.accountTypeOverride) {
                        Text("As detected").tag(String?.none)
                        ForEach(model.accountTypeOptions, id: \.self) { type in
                            Text(type).tag(String?.some(type))
                        }
                    }
                    .accessibilityIdentifier("import.accountType")
                } footer: {
                    Text(model.accountTypeOverride == nil
                         ? "Uses the account type found for each entry. Choose one to apply it to the whole statement."
                         : "Every entry, including cash, is recorded under \(model.accountTypeOverride ?? "").")
                }

                Section {
                    if let sourceLabel = model.sourceLabel {
                        LabeledContent("Statement", value: sourceLabel)
                    }
                    if let source, source.canPreview {
                        Button {
                            openStatement(source)
                        } label: {
                            Label("View Statement", systemImage: "doc.text.magnifyingglass")
                        }
                        .accessibilityIdentifier("import.viewStatement")
                    }
                    LabeledContent("Investments Found", value: "\(model.displayEntries.count)")
                    LabeledContent("Matched to Existing") {
                        Text("\(model.matchedCount)")
                            .foregroundStyle(.green)
                    }
                    if model.updateCount > 0 {
                        LabeledContent("Will Be Updated") {
                            Text("\(model.updateCount)")
                                .foregroundStyle(.orange)
                        }
                    }
                    LabeledContent("New Investments") {
                        Text("\(model.newCount)")
                            .foregroundStyle(.blue)
                    }
                    if !model.accountTypes.isEmpty {
                        LabeledContent("Account Types", value: model.accountTypes.joined(separator: ", "))
                    }
                }

                Section("Investments") {
                    ForEach(model.displayEntries) { entry in
                        entryRow(entry)
                    }
                }
            }
            // Re-runs whenever new symbols need checking (e.g. after changing a match)
            .task(id: model.pendingCheckKey) {
                await model.runSymbolChecks()
            }
            .quickLookPreview($statementFileURL)
            .onChange(of: statementFileURL) { oldURL, newURL in
                // Quick Look closed — remove the temporary copy
                if newURL == nil, let oldURL {
                    try? FileManager.default.removeItem(at: oldURL.deletingLastPathComponent())
                }
            }
            .alert("Couldn't Open Statement", isPresented: Binding(
                get: { statementOpenError != nil },
                set: { if !$0 { statementOpenError = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(statementOpenError ?? "")
            }
            .navigationTitle("Import Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        model.apply()
                        let store = model.store
                        Task { await store.fetchAllPrices() }
                        dismiss()
                    }
                    .disabled(!model.canApply)
                    .accessibilityIdentifier("import.apply")
                }
            }
        }
    }

    // MARK: - Entry Row

    @ViewBuilder
    private func entryRow(_ entry: ParsedStatementEntry) -> some View {
        let matched = model.matchedInvestment(for: entry)
        let changes = matched.map { model.computeChanges(entry: entry, existing: $0) } ?? .empty
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
                    ForEach(model.matchCandidates) { investment in
                        Text("\(investment.name) (\(investment.symbol ?? "no symbol"))")
                            .tag(UUID?.some(investment.id))
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .accessibilityIdentifier("import.match.\(entry.name)")
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

            // Holdings Yahoo can't price must be resolved before Apply
            switch model.priceCheck(for: entry) {
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking live price…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .findingSymbol:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("No live price for \(model.pricingSymbol(for: entry) ?? entry.name) — finding the correct symbol…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .corrected(let symbol, let name):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Label(
                        "Symbol corrected: \(model.pricingSymbol(for: entry) ?? "none") → \(symbol)\(name.map { " (\($0))" } ?? "")",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                    Spacer()
                    Button("Undo") {
                        model.undoCorrection(forEntry: entry.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            case .missing(let reason):
                priceResolutionView(for: entry, reason: reason)
            case .ok, .notNeeded:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Statement

    private func openStatement(_ source: StatementSource) {
        do {
            statementFileURL = try source.writePreviewFile()
        } catch {
            statementOpenError = error.localizedDescription
        }
    }

    // MARK: - Bindings

    /// Binding for an entry's match picker: nil means "New investment".
    private func matchSelection(for entryID: UUID) -> Binding<UUID?> {
        Binding(
            get: { model.matchedInvestmentID(forEntry: entryID) },
            set: { model.setMatch(forEntry: entryID, to: $0) }
        )
    }

    private func resolution(_ id: UUID) -> Binding<PriceResolution> {
        Binding(
            get: { model.priceResolutions[id] ?? PriceResolution() },
            set: { model.priceResolutions[id] = $0 }
        )
    }

    // MARK: - Price Resolution

    @ViewBuilder
    private func priceResolutionView(for entry: ParsedStatementEntry, reason: String) -> some View {
        let binding = resolution(entry.id)
        let currency = entry.currencyCode ?? "GBP"
        VStack(alignment: .leading, spacing: 6) {
            Label("\(reason) Choose how to price it:", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            Picker("Price source", selection: binding.mode) {
                Text("Choose…").tag(PriceResolution.Mode?.none)
                Text("Enter a price").tag(PriceResolution.Mode?.some(.manualPrice))
                if model.valuePerUnit(for: entry) != nil {
                    Text("Value ÷ units").tag(PriceResolution.Mode?.some(.fromValue))
                }
                Text("Enter a ticker").tag(PriceResolution.Mode?.some(.ticker))
            }
            .pickerStyle(.menu)
            .font(.caption)
            .accessibilityIdentifier("import.priceSource.\(entry.name)")

            switch binding.wrappedValue.mode {
            case .manualPrice?:
                TextField("Price per unit in \(currency)", text: binding.priceText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("import.manualPrice.\(entry.name)")
                if NumberText.isInvalid(binding.wrappedValue.priceText) {
                    Text("Invalid number").font(.caption).foregroundStyle(.red)
                }
            case .fromValue?:
                if let value = entry.value, let perUnit = model.valuePerUnit(for: entry) {
                    Text("\(value.formatted(.currency(code: currency))) ÷ \(entry.shares.formatted()) = \(perUnit.formatted(.currency(code: currency))) per unit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .ticker?:
                HStack {
                    TextField("Yahoo ticker, e.g. GC=F", text: binding.tickerText)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("import.ticker.\(entry.name)")
                    if binding.wrappedValue.isCheckingTicker {
                        ProgressView()
                    } else {
                        Button("Check") {
                            Task { await model.checkTicker(for: entry) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(binding.wrappedValue.trimmedTicker.isEmpty)
                    }
                }
                if let verified = binding.wrappedValue.verifiedTicker, verified == binding.wrappedValue.trimmedTicker {
                    Label("\(verified) has a live price — it will be remembered for future imports", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if let error = binding.wrappedValue.tickerError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    // A price-range mismatch may just be an old statement — let the user decide
                    if let mismatched = binding.wrappedValue.priceMismatchTicker, mismatched == binding.wrappedValue.trimmedTicker {
                        Button("Use \(mismatched) anyway") {
                            model.useTickerAnyway(forEntry: entry.id)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            case nil:
                EmptyView()
            }
        }
        .padding(.top, 4)
    }
}
