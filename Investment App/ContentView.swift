//
//  ContentView.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/09/2026.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// One statement in the import queue: either ready to send, or a file that couldn't be loaded.
private enum QueuedImport {
    case source(StatementSource)
    case failed(String)
}

/// A parsed statement awaiting the user's review in the preview sheet.
private struct ImportPreview: Identifiable {
    let id = UUID()
    let entries: [ParsedStatementEntry]
    let label: String
}

struct ContentView: View {
    @State private var store = PortfolioStore()
    @State private var selectedInvestment: Investment?
    @State private var expandedSectors: Set<String> = []
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showReclassifySheet = false
    @State private var showAddInvestment = false
    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isParsingStatement = false
    /// Statements waiting to be parsed and previewed. Each file is its own statement, handled one at a time.
    @State private var importQueue: [QueuedImport] = []
    @State private var isImportRunning = false
    @State private var importTotal = 0
    @State private var importPosition = 0
    @State private var currentPreview: ImportPreview?
    @State private var importError: String?
    @State private var showImportError = false
    @State private var showResetConfirmation = false
    @State private var showSettings = false
    @State private var showMissingKeyAlert = false
    @State private var investmentToDelete: Investment?

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
                            requireAPIKey { showReclassifySheet = true }
                        } label: {
                            Label("Reclassify Sectors", systemImage: "arrow.trianglehead.2.clockwise")
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gear")
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
                    Menu {
                        Button {
                            requireAPIKey { showFileImporter = true }
                        } label: {
                            Label("Choose Files…", systemImage: "folder")
                        }
                        Button {
                            requireAPIKey { showPhotosPicker = true }
                        } label: {
                            Label("Choose from Photos…", systemImage: "photo.on.rectangle")
                        }
                    } label: {
                        if isParsingStatement {
                            ProgressView()
                        } else {
                            Image(systemName: "doc.badge.plus")
                        }
                    }
                    .disabled(isImportRunning)
                }
            }
            .sheet(item: $selectedInvestment) { investment in
                EditInvestmentView(
                    investment: investment,
                    knownSectors: store.knownSectors,
                    exchangeRates: store.exchangeRates,
                    onSave: { updated in store.updateInvestment(updated) },
                    onDelete: store.canDelete(investment) ? { store.deleteInvestment(investment) } : nil
                )
            }
            .sheet(isPresented: $showReclassifySheet) {
                ReclassifySheet(store: store)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("Claude API Key Needed", isPresented: $showMissingKeyAlert) {
                Button("Not Now", role: .cancel) { }
                Button("Open Settings") { showSettings = true }
            } message: {
                Text("Add your Claude API key in Settings to import statements and classify sectors.")
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
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result)
            }
            .photosPicker(isPresented: $showPhotosPicker, selection: $photoSelection, matching: .images)
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                Task { await handlePhotoImport(items) }
            }
            // Files shared to the app ("Open in Investment App" in the share sheet)
            .onOpenURL { url in
                handleSharedFile(url)
            }
            .sheet(item: $currentPreview, onDismiss: processNextImport) { preview in
                StatementImportPreviewSheet(entries: preview.entries, store: store, sourceLabel: preview.label)
            }
            .alert("Import Error", isPresented: $showImportError) {
                // Continue with the next queued statement once the error is acknowledged
                Button("OK") { processNextImport() }
            } message: {
                Text(importError ?? "An unknown error occurred.")
            }
            .alert(
                "Delete \(investmentToDelete?.name ?? "Investment")?",
                isPresented: Binding(
                    get: { investmentToDelete != nil },
                    set: { if !$0 { investmentToDelete = nil } }
                ),
                presenting: investmentToDelete
            ) { investment in
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    store.deleteInvestment(investment)
                }
            } message: { _ in
                Text("This removes all its holdings and can't be undone.")
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
        Task {
            // Wait for expansion animation to complete and layout to settle
            try? await Task.sleep(for: .milliseconds(400))
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
                                    .contextMenu {
                                        Button {
                                            selectedInvestment = investment
                                        } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        if store.canDelete(investment) {
                                            Button(role: .destructive) {
                                                investmentToDelete = investment
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
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
                HStack(spacing: 4) {
                    Text(investment.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    priceStatusBadge(for: investment)
                }
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

    /// Flags investments whose value isn't from a live market price, so stale or missing values are visible.
    @ViewBuilder
    private func priceStatusBadge(for investment: Investment) -> some View {
        switch store.priceStatus(for: investment) {
        case .noLivePrice:
            Label("No live price", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
        case .manual:
            Text("Manual")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .background(Color(.systemGray5), in: Capsule())
        case .live:
            EmptyView()
        }
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

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            enqueueImports(urls.map(loadFile))
        case .failure(let error):
            presentImportError("File selection failed: \(error.localizedDescription)")
        }
    }

    private func handlePhotoImport(_ items: [PhotosPickerItem]) async {
        var queued: [QueuedImport] = []
        for (index, item) in items.enumerated() {
            let name = items.count > 1 ? "Photo \(index + 1)" : "Photo"
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                queued.append(.failed("\(name) couldn't be loaded from Photos."))
                continue
            }
            do {
                let source = try StatementFileLoader.load(data: data, type: item.supportedContentTypes.first, name: name)
                queued.append(.source(source))
            } catch {
                queued.append(.failed(error.localizedDescription))
            }
        }
        enqueueImports(queued)
    }

    /// Handles a file another app shared to this one. iOS gives us a private copy, removed once read.
    private func handleSharedFile(_ url: URL) {
        guard APIKeyStore.hasClaudeKey else {
            showMissingKeyAlert = true
            return
        }
        let item = loadFile(url)
        try? FileManager.default.removeItem(at: url)
        enqueueImports([item])
    }

    private func loadFile(_ url: URL) -> QueuedImport {
        do {
            return .source(try StatementFileLoader.load(fileAt: url))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Adds statements to the queue and starts processing if idle. Items shared while an import runs join the queue.
    private func enqueueImports(_ items: [QueuedImport]) {
        guard !items.isEmpty else { return }
        importQueue.append(contentsOf: items)
        importTotal += items.count
        if !isImportRunning {
            isImportRunning = true
            processNextImport()
        }
    }

    /// Takes the next queued statement. Called again when its preview sheet or error alert is dismissed.
    private func processNextImport() {
        guard !importQueue.isEmpty else {
            isImportRunning = false
            importTotal = 0
            importPosition = 0
            return
        }
        let next = importQueue.removeFirst()
        importPosition += 1
        switch next {
        case .failed(let message):
            presentImportError(message)
        case .source(let source):
            Task { await parseAndPreview(source) }
        }
    }

    private func parseAndPreview(_ source: StatementSource) async {
        let label = importTotal > 1 ? "\(source.name) (\(importPosition) of \(importTotal))" : source.name

        isParsingStatement = true
        let entries: [ParsedStatementEntry]
        switch await store.parseStatement(source) {
        case .success(let parsed):
            entries = parsed
        case .failure(let failure):
            isParsingStatement = false
            presentImportError("\(label): \(failure.message)")
            return
        }

        // Cash is converted to GBP when applied, so its rates must be known before previewing
        let cashCurrencies = Set(entries.filter(\.isCash).map { $0.currencyCode ?? "GBP" })
        let missingRates = await store.ensureExchangeRates(for: cashCurrencies)
        isParsingStatement = false

        if !missingRates.isEmpty {
            let pairs = missingRates.sorted().map { "\($0)→GBP" }.joined(separator: ", ")
            presentImportError("\(label): Couldn't get the \(pairs) exchange rate. Check your connection and try again.")
        } else if entries.isEmpty {
            presentImportError("\(label): No investments found in the statement.")
        } else {
            currentPreview = ImportPreview(entries: entries, label: label)
        }
    }

    private func presentImportError(_ message: String) {
        importError = message
        showImportError = true
    }

    // MARK: - Helpers

    /// Runs the action only if a Claude API key is saved; otherwise prompts the user to add one.
    private func requireAPIKey(_ action: () -> Void) {
        if APIKeyStore.hasClaudeKey {
            action()
        } else {
            showMissingKeyAlert = true
        }
    }

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
    @State private var showError = false
    @State private var errorMessage = ""
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
                            let failure = await store.classifySectors(maxSectors: maxSectors, additionalPrompt: additionalPrompt, forceAll: true)
                            isClassifying = false
                            if let failure {
                                errorMessage = failure.message
                                showError = true
                            } else {
                                dismiss()
                            }
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
            .alert("Reclassification Failed", isPresented: $showError) {
                Button("OK") { }
            } message: {
                Text("\(errorMessage) Your existing sectors were kept.")
            }
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
