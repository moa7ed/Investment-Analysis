//
//  TargetsView.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//

import SwiftUI

/// Edits every investment's target percentage at once, with a running total that should reach 100%.
/// Changes are kept in a draft and only saved when the user taps Save.
struct TargetsView: View {
    let store: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    /// Draft targets keyed by investment ID.
    @State private var targets: [UUID: Double]
    @State private var showDiscardConfirmation = false
    @State private var searchText = ""

    /// Slider and field granularity.
    static let step = 0.25

    init(store: PortfolioStore) {
        self.store = store
        _targets = State(initialValue: Dictionary(uniqueKeysWithValues: store.investments.map { ($0.id, $0.targetPercentage) }))
    }

    private var total: Double {
        targets.values.reduce(0, +)
    }

    /// Exactly 100% (allowing for floating-point noise from adding many 0.25 steps).
    private var totalIsValid: Bool {
        abs(total - 100) < 0.001
    }

    private var hasChanges: Bool {
        store.investments.contains { abs((targets[$0.id] ?? 0) - $0.targetPercentage) > 0.0001 }
    }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// Investments matching the search by name or symbol (all of them when the search is empty).
    private var matchingInvestments: [Investment] {
        guard !trimmedSearch.isEmpty else { return store.investments }
        return store.investments.filter {
            $0.name.localizedStandardContains(trimmedSearch)
                || ($0.symbol?.localizedStandardContains(trimmedSearch) ?? false)
        }
    }

    /// Matching investments grouped by sector, ignoring the main list's broker/type filter.
    private var groups: [(sector: String, items: [Investment])] {
        let grouped = Dictionary(grouping: matchingInvestments, by: \.sectorOrDefault)
        return store.knownSectors.compactMap { sector in
            guard let items = grouped[sector], !items.isEmpty else { return nil }
            return (sector, items)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.sector) { group in
                    Section {
                        ForEach(group.items) { investment in
                            TargetRow(
                                investment: investment,
                                currentPercentage: store.currentPercentage(for: investment),
                                target: binding(for: investment.id)
                            )
                        }
                    } header: {
                        sectorHeader(group.sector)
                    }
                }
            }
            .overlay {
                if groups.isEmpty, !trimmedSearch.isEmpty {
                    ContentUnavailableView.search(text: trimmedSearch)
                }
            }
            // Search only narrows the list — the total below always covers every investment
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or symbol")
            // Always-visible total, above the home indicator
            .safeAreaInset(edge: .bottom) {
                totalBar
            }
            .navigationTitle("Targets")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges {
                            showDiscardConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setTargets(targets)
                        dismiss()
                    }
                    .disabled(!hasChanges)
                    .accessibilityIdentifier("targets.save")
                }
            }
            .confirmationDialog("Discard target changes?", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) { }
            }
        }
    }

    private func binding(for id: UUID) -> Binding<Double> {
        Binding(
            get: { targets[id] ?? 0 },
            set: { targets[id] = $0 }
        )
    }

    /// Sector name and its total target — across the whole sector, even when search hides some rows.
    private func sectorHeader(_ sector: String) -> some View {
        let icon = AssetIcons.sector(sector)
        let sectorTotal = store.investments
            .filter { $0.sectorOrDefault == sector }
            .reduce(0) { $0 + (targets[$1.id] ?? 0) }
        return HStack(spacing: 8) {
            AssetIconView(symbol: icon.symbol, color: icon.color, size: 20)
            Text(sector)
            Spacer()
            Text(Self.format(sectorTotal))
                .monospacedDigit()
        }
    }

    private var totalBar: some View {
        let remaining = 100 - total
        return HStack(spacing: 10) {
            Image(systemName: totalIsValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(totalIsValid ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Total \(Self.format(total))")
                    .font(.headline)
                    .monospacedDigit()
                Text(totalIsValid
                     ? "Targets add up to 100%"
                     : remaining > 0
                        ? "\(Self.format(remaining)) left to assign"
                        : "\(Self.format(-remaining)) over 100%")
                    .font(.caption)
                    .foregroundStyle(totalIsValid ? Color.secondary : Color.orange)
            }
            Spacer()
        }
        .padding()
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("targets.total")
    }

    /// "12.75%", "10%"
    static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + "%"
    }

    /// Rounds to the nearest step and keeps it within 0–100%.
    static func snap(_ value: Double) -> Double {
        min(100, max(0, (value / step).rounded() * step))
    }
}

/// One investment: logo, name, current share, slider and a number field kept in sync.
private struct TargetRow: View {
    let investment: Investment
    let currentPercentage: Double
    @Binding var target: Double

    @State private var text = ""
    @FocusState private var isEditingText: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                InvestmentLogoView(symbol: investment.symbol, category: investment.category)
                VStack(alignment: .leading, spacing: 1) {
                    Text(investment.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("Now \(TargetsView.format(currentPercentage))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                stepButton(-TargetsView.step)
                percentField
                stepButton(TargetsView.step)
            }
            // Snaps to 0.25% itself instead of passing `step:` — with a step, iOS draws a tick per step,
            // and 400 ticks merge into a solid line under the track
            Slider(value: snappedTarget, in: 0...100) {
                Text("Target for \(investment.name)")
            }
            .accessibilityValue(TargetsView.format(target))
        }
        .padding(.vertical, 2)
        .onAppear { text = Self.text(for: target) }
        // Slider moved → update the field (unless the user is typing in it)
        .onChange(of: target) { _, newValue in
            if !isEditingText {
                text = Self.text(for: newValue)
            }
        }
        // Leaving the field (tap elsewhere, next row) commits what was typed
        .onChange(of: isEditingText) { _, editing in
            if !editing {
                commitText()
            }
        }
    }

    private var percentField: some View {
        HStack(spacing: 2) {
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($isEditingText)
                .frame(width: 52)
                .onSubmit(commitText)
            Text("%")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 6))
    }

    /// − / + beside the field: one 0.25% step per tap, repeating while held.
    private func stepButton(_ delta: Double) -> some View {
        let isIncrease = delta > 0
        return Button {
            // Apply anything half-typed first, so the step starts from what the user sees
            if isEditingText {
                commitText()
            }
            target = TargetsView.snap(target + delta)
            text = Self.text(for: target)
        } label: {
            Image(systemName: isIncrease ? "plus.circle.fill" : "minus.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
        }
        // Borderless so each button gets its own taps inside the List row (otherwise the whole row fires both)
        .buttonStyle(.borderless)
        .buttonRepeatBehavior(.enabled)
        .disabled(isIncrease ? target >= 100 : target <= 0)
        .accessibilityLabel(isIncrease ? "Increase \(investment.name) by 0.25%" : "Decrease \(investment.name) by 0.25%")
    }

    /// The slider's value, snapped to 0.25% steps.
    private var snappedTarget: Binding<Double> {
        Binding(get: { target }, set: { target = TargetsView.snap($0) })
    }

    /// Applies the typed value (snapped to 0.25%, clamped to 0–100%); invalid text reverts.
    private func commitText() {
        if NumberText.isEmpty(text) {
            target = 0
        } else if let value = NumberText.parse(text) {
            target = TargetsView.snap(value)
        }
        text = Self.text(for: target)
    }

    private static func text(for value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

#Preview {
    let store = PortfolioStore(defaults: UserDefaults(suiteName: "targets-preview")!, apiKeyProvider: { nil })
    let samples: [(Investment, String)] = [
        (Investment(name: "Alphabet", symbol: "GOOGL", category: "Stock", targetPercentage: 20), "Tech"),
        (Investment(name: "Vanguard S&P 500", symbol: "VUSA.L", category: "ETF", targetPercentage: 50.25), "Index Funds"),
        (Investment(name: "Bitcoin", symbol: "BTC-USD", category: "Crypto", targetPercentage: 10), "Crypto"),
        (Investment(name: "Cash", category: "Cash", targetPercentage: 5), "Cash"),
    ]
    store.investments = samples.map { investment, sector in
        var investment = investment
        investment.sector = sector
        return investment
    }
    return TargetsView(store: store)
}
