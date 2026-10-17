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
    let source: StatementSource
}

struct ContentView: View {
    @State private var store: PortfolioStore

    /// Statements to import as soon as the view appears (used by UI tests).
    private let initialImports: [StatementSource]

    init(store: PortfolioStore, initialImports: [StatementSource] = []) {
        _store = State(initialValue: store)
        self.initialImports = initialImports
    }
    @State private var selectedInvestment: Investment?
    @State private var expandedSectors: Set<String> = []
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showReclassifySheet = false
    @State private var showTargets = false
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""

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
            .searchable(text: $searchText, prompt: "Name or symbol")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showTargets = true
                        } label: {
                            Label("Update Targets", systemImage: "target")
                        }
                        .accessibilityIdentifier("menu.targets")
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
                    .accessibilityIdentifier("menu.more")
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
                    .accessibilityIdentifier("menu.import")
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
            .sheet(isPresented: $showTargets) {
                TargetsView(store: store)
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
            // Drop a filter whose broker or account type no longer exists (e.g. after a reset or delete)
            .onChange(of: store.filterBrokers) { _, brokers in
                if let broker = store.brokerFilter,
                   !brokers.contains(where: { PortfolioStore.normalizeBroker($0) == PortfolioStore.normalizeBroker(broker) }) {
                    store.brokerFilter = nil
                }
            }
            .onChange(of: store.filterAccountTypes) { _, types in
                if let type = store.accountTypeFilter, !types.contains(where: { $0.lowercased() == type.lowercased() }) {
                    store.accountTypeFilter = nil
                }
            }
            .refreshable {
                await store.fetchAllPrices()
            }
            .task {
                if !initialImports.isEmpty {
                    enqueueImports(initialImports.map { .source($0) })
                }
                importSharedInbox()
                await store.fetchAllPrices()
            }
            // Statements sent from the Share extension while the app was in the background
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    importSharedInbox()
                }
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
            // investmentapp://import comes from the Share extension; anything else is a file
            // shared to the app ("Open in Investment App" in the share sheet)
            .onOpenURL { url in
                if url.scheme == SharedInbox.urlScheme {
                    importSharedInbox()
                } else {
                    handleSharedFile(url)
                }
            }
            .sheet(item: $currentPreview, onDismiss: processNextImport) { preview in
                StatementImportPreviewSheet(entries: preview.entries, store: store, sourceLabel: preview.label, source: preview.source)
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

                    if !store.targetsAddUpTo100 {
                        targetWarning
                            .padding(.horizontal)
                    }

                    filterBar
                        .padding(.horizontal)

                    if isSearching {
                        searchResults
                    } else {
                        sectorBarChart
                            .padding(.horizontal)

                        sectorList

                        totalCard
                            .padding(.horizontal)
                    }

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

    // MARK: - Search

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var isSearching: Bool {
        !trimmedSearch.isEmpty
    }

    /// Investments (within the broker/type filter) whose name or symbol contains the search text.
    private var searchMatches: [Investment] {
        store.visibleInvestments
            .filter {
                $0.name.localizedStandardContains(trimmedSearch)
                    || ($0.symbol?.localizedStandardContains(trimmedSearch) ?? false)
            }
            .sorted { store.valueInGBP(for: $0) > store.valueInGBP(for: $1) }
    }

    private var searchResults: some View {
        let matches = searchMatches
        return VStack(spacing: 0) {
            if matches.isEmpty {
                ContentUnavailableView.search(text: trimmedSearch)
            } else {
                ForEach(matches) { investment in
                    if investment.id != matches.first?.id {
                        Divider()
                            .padding(.leading, 34)
                    }
                    investmentActions(investmentRow(investment, showsSector: true), for: investment)
                }
            }
        }
        .padding(.vertical, 4)
        .background(Color(.systemGray6).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    /// Tap to edit, long-press for Edit/Delete — shared by the sector list and search results.
    private func investmentActions(_ row: some View, for investment: Investment) -> some View {
        row
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
            Text(store.isFiltering
                 ? "\([store.brokerFilter, store.accountTypeFilter].compactMap { $0 }.joined(separator: " · ")) Value"
                 : "Total Value")
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

    // MARK: - Target Warning

    /// Shown when targets across all investments don't sum to 100%; tapping opens the Targets page.
    private var targetWarning: some View {
        let total = store.totalTargetPercentage
        let difference = 100 - total
        return Button {
            showTargets = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Targets add up to \(TargetsView.format(total))")
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                    Text(difference > 0
                         ? "\(TargetsView.format(difference)) left to assign. Tap to update targets."
                         : "\(TargetsView.format(-difference)) over 100%. Tap to update targets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.targetWarning")
    }

    // MARK: - Filter Bar

    /// Broker and account type filters. Values, percentages and sectors below only count matching holdings.
    private var filterBar: some View {
        HStack(spacing: 8) {
            filterMenu(
                title: "Broker",
                selection: $store.brokerFilter,
                options: store.filterBrokers,
                identifier: "filter.broker"
            )
            filterMenu(
                title: "Type",
                selection: $store.accountTypeFilter,
                options: store.filterAccountTypes,
                identifier: "filter.accountType"
            )
            Spacer()
            if store.isFiltering {
                Button("Clear") {
                    store.brokerFilter = nil
                    store.accountTypeFilter = nil
                }
                .font(.caption)
                .accessibilityIdentifier("filter.clear")
            }
        }
    }

    private func filterMenu(title: String, selection: Binding<String?>, options: [String], identifier: String) -> some View {
        Menu {
            Picker(title, selection: selection) {
                Text("All").tag(String?.none)
                ForEach(options, id: \.self) { option in
                    Text(option).tag(String?.some(option))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(title): \(selection.wrappedValue ?? "All")")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(selection.wrappedValue == nil ? Color.primary : Color.white)
            .background(
                selection.wrappedValue == nil ? Color(.systemGray5) : Color.accentColor,
                in: Capsule()
            )
        }
        .accessibilityIdentifier(identifier)
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
                                investmentActions(investmentRow(investment), for: investment)
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

            let icon = AssetIcons.sector(sector)
            AssetIconView(symbol: icon.symbol, color: icon.color)

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

    /// - Parameter showsSector: Adds the symbol and sector under the name (search results aren't grouped by sector).
    private func investmentRow(_ investment: Investment, showsSector: Bool = false) -> some View {
        let gbpValue = store.valueInGBP(for: investment)
        let currentPct = store.currentPercentage(for: investment)
        let statusColor: Color = {
            if gbpValue == 0 && investment.targetPercentage == 0 { return .secondary }
            if gbpValue == 0 { return .secondary }
            return currentPct >= investment.targetPercentage ? .green : .red
        }()

        return HStack(spacing: 10) {
            // Sits under the sector icon (the row's leading padding matches the sector row's dot + spacing)
            InvestmentLogoView(symbol: investment.symbol, category: investment.category)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(investment.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    priceStatusBadge(for: investment)
                }
                if showsSector {
                    Text([investment.symbol, investment.sectorOrDefault].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
        let totalCurPct = store.visibleInvestments.reduce(0.0) { $0 + store.currentPercentage(for: $1) }
        let totalTgtPct = store.visibleInvestments.reduce(0.0) { $0 + $1.targetPercentage }

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
        guard store.hasAPIKey else {
            showMissingKeyAlert = true
            return
        }
        let item = loadFile(url)
        try? FileManager.default.removeItem(at: url)
        enqueueImports([item])
    }

    /// Imports statements the Share extension left in the App Group inbox.
    /// Without an API key the files stay in the inbox, so they're imported once a key is added.
    private func importSharedInbox() {
        let files = SharedInbox.pendingFiles()
        guard !files.isEmpty else { return }
        guard store.hasAPIKey else {
            showMissingKeyAlert = true
            return
        }
        let items = files.map { file in
            let item = loadFile(file)
            SharedInbox.remove(file)
            return item
        }
        enqueueImports(items)
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
            currentPreview = ImportPreview(entries: entries, label: label, source: source)
        }
    }

    private func presentImportError(_ message: String) {
        importError = message
        showImportError = true
    }

    // MARK: - Helpers

    /// Runs the action only if a Claude API key is saved; otherwise prompts the user to add one.
    private func requireAPIKey(_ action: () -> Void) {
        if store.hasAPIKey {
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
    ContentView(store: PortfolioStore())
}
