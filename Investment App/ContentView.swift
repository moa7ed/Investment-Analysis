//
//  ContentView.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/09/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store = PortfolioStore()
    @State private var selectedInvestment: Investment?
    @State private var expandedSectors: Set<String> = []
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showReclassifySheet = false
    @State private var showAddInvestment = false
    @State private var showFileImporter = false
    @State private var isParsingStatement = false
    @State private var parsedEntries: [ParsedStatementEntry]?
    @State private var showImportPreview = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && !store.hasFetchedOnce {
                    loadingView
                } else {
                    mainContent
                }
            }
            .navigationTitle("Portfolio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showReclassifySheet = true
                        } label: {
                            Label("Reclassify Sectors", systemImage: "arrow.trianglehead.2.clockwise")
                        }
                        Button(role: .destructive) {
                            showResetConfirmation = true
                        } label: {
                            Label("Reset All Data", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFileImporter = true
                    } label: {
                        if isParsingStatement {
                            ProgressView()
                        } else {
                            Image(systemName: "doc.badge.plus")
                        }
                    }
                    .disabled(isParsingStatement)
                }
            }
            .sheet(item: $selectedInvestment) { investment in
                EditInvestmentView(investment: investment, knownSectors: store.knownSectors, exchangeRates: store.exchangeRates) { updated in
                    store.updateInvestment(updated)
                }
            }
            .sheet(isPresented: $showReclassifySheet) {
                ReclassifySheet(store: store)
            }
            .sheet(isPresented: $showAddInvestment) {
                EditInvestmentView(
                    investment: Investment(name: "", targetPercentage: 0),
                    knownSectors: store.knownSectors,
                    exchangeRates: store.exchangeRates
                ) { newInvestment in
                    store.investments.append(newInvestment)
                    store.saveToUserDefaults()
                }
            }
            .refreshable {
                await store.fetchAllPrices()
            }
            .task {
                await store.fetchAllPrices()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .png, .jpeg],
                allowsMultipleSelection: false
            ) { result in
                Task {
                    await handleFileImport(result)
                }
            }
            .sheet(isPresented: $showImportPreview) {
                if let entries = parsedEntries {
                    StatementImportPreviewSheet(entries: entries, store: store)
                }
            }
            .alert("Import Error", isPresented: $showImportError) {
                Button("OK") { }
            } message: {
                Text(importError ?? "An unknown error occurred.")
            }
            .alert("Reset All Data", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    store.resetAllData()
                }
            } message: {
                Text("This will delete all investments and saved data. This cannot be undone.")
            }
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading prices...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 20) {
                    portfolioHeader

                    sectorBarChart
                        .padding(.horizontal)

                    sectorList

                    totalCard
                        .padding(.horizontal)

                    Button {
                        showAddInvestment = true
                    } label: {
                        Label("Add Investment", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .onAppear { scrollProxy = proxy }
        }
    }

    private func scrollToSector(_ sector: String) {
        // Wait for expansion animation to complete and layout to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeInOut(duration: 0.3)) {
                // Scroll to the bottom of the expanded list, so the whole section is visible
                scrollProxy?.scrollTo("bottom-\(sector)", anchor: .bottom)
            }
        }
    }

    // MARK: - Portfolio Header

    private var portfolioHeader: some View {
        VStack(spacing: 4) {
            Text("Total Value")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(store.totalPortfolioValue, format: .currency(code: "GBP").precision(.fractionLength(0)))
                    .font(.largeTitle.bold())
                if store.isLoading {
                    ProgressView()
                }
            }
        }
    }

    // MARK: - Sector Bar Chart

    private var sectorBarChart: some View {
        let sectors = store.investmentsBySector
        let total = store.totalPortfolioValue
        let hasSelection = !expandedSectors.isEmpty

        // Max current percentage across sectors — used to scale bar widths
        let maxPct = sectors.map { store.sectorCurrentPercentage($0.sector) }.max() ?? 1

        // Dynamic ceiling: the largest GBP gap across all sectors
        let maxGap: Double = {
            let gaps = sectors.map { group -> Double in
                let currentVal = store.sectorValue(group.sector)
                let targetVal = total * store.sectorTargetPercentage(group.sector) / 100.0
                return abs(currentVal - targetVal)
            }
            return gaps.max() ?? 1
        }()

        return VStack(spacing: 4) {
            ForEach(sectors, id: \.sector) { group in
                let curPct = store.sectorCurrentPercentage(group.sector)
                let tgtPct = store.sectorTargetPercentage(group.sector)
                let value = store.sectorValue(group.sector)
                let isExpanded = expandedSectors.contains(group.sector)

                let targetValue = total * tgtPct / 100.0
                let gbpGap = abs(value - targetValue)
                let intensity = maxGap > 0 ? 0.3 + (gbpGap / maxGap) * 0.7 : 0.3
                let baseColor: Color = {
                    if value == 0 && tgtPct == 0 { return .gray }
                    if value == 0 { return .red }
                    return curPct >= tgtPct ? .green : .red
                }()
                let fillOpacity: Double = {
                    if isExpanded { return intensity }
                    if hasSelection { return intensity * 0.35 }
                    return intensity * 0.7
                }()

                // Bar width fraction relative to the largest sector
                let barFraction = maxPct > 0 ? curPct / maxPct : 0

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Background track
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.systemGray6))

                        // Filled bar
                        RoundedRectangle(cornerRadius: 6)
                            .fill(baseColor.opacity(fillOpacity))
                            .frame(width: max(0, geo.size.width * barFraction))

                        // Border for expanded
                        if isExpanded {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary, lineWidth: 2)
                        }

                        // Labels
                        HStack {
                            Text(group.sector)
                                .font(.subheadline.bold())
                                .lineLimit(1)

                            Spacer()

                            HStack(spacing: 4) {
                                Text(formatPct(curPct))
                                    .foregroundStyle(baseColor)
                                Text("/ \(formatPct(tgtPct))")
                                    .foregroundStyle(.secondary)

                                let diff = value - targetValue
                                Text("(\(diff >= 0 ? "+" : "")\(diff.formatted(.currency(code: "GBP").precision(.fractionLength(0)))))")
                                    .foregroundStyle(diff >= 0 ? .green : .red)
                            }
                            .font(.caption)
                        }
                        .padding(.horizontal, 10)
                    }
                }
                .frame(height: 40)
                .contentShape(Rectangle())
                .onTapGesture {
                    let willExpand = !isExpanded
                    withAnimation(.easeInOut(duration: 0.25)) {
                        toggleSector(group.sector)
                    }
                    if willExpand {
                        scrollToSector(group.sector)
                    }
                }
            }
        }
    }

    private func toggleSector(_ sector: String) {
        if expandedSectors.contains(sector) {
            expandedSectors.remove(sector)
        } else {
            expandedSectors.insert(sector)
        }
    }

    // MARK: - Sector List

    private var sectorList: some View {
        VStack(spacing: 2) {
            ForEach(store.investmentsBySector, id: \.sector) { group in
                VStack(spacing: 0) {
                    // Sector row
                    sectorListRow(group.sector)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                toggleSector(group.sector)
                            }
                        }

                    // Expanded investments
                    if expandedSectors.contains(group.sector) {
                        VStack(spacing: 0) {
                            ForEach(group.items) { investment in
                                Divider()
                                    .padding(.leading, 34)
                                investmentRow(investment)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedInvestment = investment
                                    }
                            }
                        }
                        .padding(.bottom, 4)
                        .background(Color(.systemGray6).opacity(0.3), in: RoundedRectangle(cornerRadius: 0))
                        .clipShape(
                            UnevenRoundedRectangle(
                                bottomLeadingRadius: 10,
                                bottomTrailingRadius: 10
                            )
                        )
                        .id("bottom-\(group.sector)")
                    }
                }
                .id(group.sector)
            }
        }
        .padding(.horizontal)
    }

    private func sectorListRow(_ sector: String) -> some View {
        let value = store.sectorValue(sector)
        let curPct = store.sectorCurrentPercentage(sector)
        let tgtPct = store.sectorTargetPercentage(sector)
        let isExpanded = expandedSectors.contains(sector)
        let statusColor: Color = {
            if value == 0 { return .secondary }
            return curPct >= tgtPct ? .green : .red
        }()

        return HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(sector)
                    .font(.subheadline.bold())
                HStack(spacing: 4) {
                    Text(formatPct(curPct))
                        .foregroundStyle(statusColor)
                    Text("/ \(formatPct(tgtPct))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }

            Spacer()

            Text(value > 0
                 ? value.formatted(.currency(code: "GBP").precision(.fractionLength(0)))
                 : "—")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            Color(.systemGray6).opacity(0.5),
            in: isExpanded
                ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
                : AnyShape(RoundedRectangle(cornerRadius: 10))
        )
        .contentShape(Rectangle())
    }

    // MARK: - Investment Row

    private func investmentRow(_ investment: Investment) -> some View {
        let gbpValue = store.valueInGBP(for: investment)
        let currentPct = store.currentPercentage(for: investment)
        let statusColor: Color = {
            if gbpValue == 0 && investment.targetPercentage == 0 { return .secondary }
            if gbpValue == 0 { return .secondary }
            return currentPct >= investment.targetPercentage ? .green : .red
        }()

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(investment.name)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(formatPct(currentPct))
                        .foregroundStyle(statusColor)
                    Text("/ \(formatPct(investment.targetPercentage))")
                        .foregroundStyle(.secondary)

                    let targetValue = store.totalPortfolioValue * investment.targetPercentage / 100.0
                    let diff = gbpValue - targetValue
                    Text("(\(diff >= 0 ? "+" : "")\(diff.formatted(.currency(code: "GBP").precision(.fractionLength(0)))))")
                        .foregroundStyle(diff >= 0 ? .green : .red)
                }
                .font(.caption2)
            }
            Spacer()
            Text(gbpValue > 0
                 ? gbpValue.formatted(.currency(code: "GBP").precision(.fractionLength(0)))
                 : "—")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .padding(.leading, 22)
    }

    // MARK: - Total Card

    private var totalCard: some View {
        let totalCurPct = store.investments.reduce(0.0) { $0 + store.currentPercentage(for: $1) }
        let totalTgtPct = store.investments.reduce(0.0) { $0 + $1.targetPercentage }

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total")
                    .font(.subheadline.bold())
                HStack(spacing: 4) {
                    Text(formatPct(totalCurPct))
                    Text("/ \(formatPct(totalTgtPct))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
            Spacer()
            Text(store.totalPortfolioValue.formatted(.currency(code: "GBP").precision(.fractionLength(0))))
                .font(.subheadline.bold())
        }
        .padding()
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Statement Import

    private func handleFileImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Unable to access the selected file."
                showImportError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                let ext = url.pathExtension.lowercased()
                let mimeType: String
                switch ext {
                case "pdf": mimeType = "application/pdf"
                case "png": mimeType = "image/png"
                case "jpg", "jpeg": mimeType = "image/jpeg"
                default:
                    importError = "Unsupported file type: \(ext)"
                    showImportError = true
                    return
                }

                isParsingStatement = true
                let entries = await store.parseStatement(data: data, mimeType: mimeType)
                isParsingStatement = false

                if let entries, !entries.isEmpty {
                    parsedEntries = entries
                    showImportPreview = true
                } else {
                    importError = "No investments found in the statement."
                    showImportError = true
                }
            } catch {
                importError = "Failed to read the file: \(error.localizedDescription)"
                showImportError = true
            }

        case .failure(let error):
            importError = "File selection failed: \(error.localizedDescription)"
            showImportError = true
        }
    }

    // MARK: - Helpers

    private func formatPct(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f%%", value)
        }
        return String(format: "%.2f%%", value)
    }
}

// MARK: - Reclassify Sheet

struct ReclassifySheet: View {
    let store: PortfolioStore
    @State private var maxSectors: Int = 8
    @State private var additionalPrompt: String = ""
    @State private var isClassifying = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Number of Sectors") {
                    Stepper("\(maxSectors) sectors", value: $maxSectors, in: 2...12)
                }

                Section("Additional Instructions") {
                    TextField("e.g. Separate semiconductors from software", text: $additionalPrompt, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section {
                    Button {
                        isClassifying = true
                        Task {
                            await store.classifySectors(maxSectors: maxSectors, additionalPrompt: additionalPrompt, forceAll: true)
                            isClassifying = false
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if isClassifying {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Classifying...")
                            } else {
                                Text("Reclassify All")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isClassifying)
                }
            }
            .navigationTitle("Reclassify Sectors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isClassifying)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
