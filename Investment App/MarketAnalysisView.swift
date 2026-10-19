//
//  MarketAnalysisView.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import SwiftUI
import SwiftData

/// Runs a Claude market analysis and shows the latest one as a horizontal slider:
/// the market summary first, then one card per buy/sell recommendation (holds on request).
struct MarketAnalysisView: View {
    let store: PortfolioStore

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(Self.latestAnalysis) private var latest: [AnalysisRecord]
    /// Kept between runs so the user doesn't retype it; only sent to Claude when not blank
    @AppStorage("market_analysis_instructions") private var instructions = ""
    @State private var errorMessage: String?
    @State private var showsHolds = false
    @State private var page = 0
    /// Off by default: a run reuses today's research instead of searching the web again
    @State private var searchesAgain = false

    private static var latestAnalysis: FetchDescriptor<AnalysisRecord> {
        var descriptor = FetchDescriptor<AnalysisRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }

    private var isRunning: Bool {
        store.marketAnalysisPhase != nil
    }

    private var hasInvestments: Bool {
        store.investments.contains { $0.category.lowercased() != "cash" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                requestSection
                    .padding(.horizontal)

                if let phase = store.marketAnalysisPhase {
                    runningView(phase)
                } else if let analysis = latest.first {
                    results(analysis)
                } else {
                    ContentUnavailableView(
                        "No Analysis Yet",
                        systemImage: "sparkles",
                        description: Text("Claude researches the latest market news and gives a buy, sell or hold call for each of your investments.")
                    )
                }
            }
            .padding(.top)
            // No banner for a finished analysis while its result is already on screen
            .onAppear { AnalysisNotificationRouter.shared.isShowingMarketAnalysis = true }
            .onDisappear { AnalysisNotificationRouter.shared.isShowingMarketAnalysis = false }
            .navigationTitle("Market Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Analysis Failed",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK") { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Request

    private var requestSection: some View {
        VStack(spacing: 10) {
            TextField("Optional notes for Claude, e.g. I'm saving for a house in 2 years", text: $instructions, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                .disabled(isRunning)
                .accessibilityIdentifier("analysis.instructions")

            // Research is reused within the same day unless the user asks for a fresh web search
            if !isRunning, let research = AnalysisRecord.todaysResearch(in: modelContext) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Search for new market news", isOn: $searchesAgain)
                        .font(.subheadline)
                        .accessibilityIdentifier("analysis.searchAgain")
                    Text(searchesAgain
                         ? "Claude will search the web again for the latest news."
                         : "Today's research from \(research.date.formatted(date: .omitted, time: .shortened)) will be reused — no new web searches, so it costs less.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: run) {
                Label(latest.isEmpty ? "Run Analysis" : "Run New Analysis", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRunning || !hasInvestments)
            .accessibilityIdentifier("analysis.run")
        }
    }

    /// The current step and a short list of the major steps so far, each updated in place.
    private func runningView(_ phase: MarketAnalysisPhase) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                Text(phase.message)
                    .font(.headline)
            }
            if case .unavailable(let reason) = store.marketAnalysisBackground {
                Label {
                    Text("Keep the app open until the analysis finishes — iOS won't let it run in the background this time. \(reason)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("analysis.foregroundOnly")
            } else {
                Text("A deep analysis can take a few minutes. You can close this screen or leave the app — you'll get a notification when it's ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !store.marketAnalysisActivity.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.marketAnalysisActivity) { activity in
                        activityRow(activity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                .animation(.default, value: store.marketAnalysisActivity)
                .accessibilityIdentifier("analysis.activity")
            }
        }
        .padding([.horizontal, .bottom])
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func activityRow(_ activity: AnalysisActivity) -> some View {
        let iconColor: Color = switch activity.kind {
        case .problem: .orange
        case .done: .green
        default: .accentColor
        }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: activity.kind.systemImage)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.text)
                    .font(.subheadline)
                if let detail = activity.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func run() {
        guard store.hasAPIKey else {
            errorMessage = ClaudeFailure.missingKey.message
            return
        }
        // The runner saves the result and notifies the user even if this screen is closed while Claude works
        MarketAnalysisRunner.start(
            store: store,
            context: modelContext,
            instructions: instructions,
            termsExplainedToday: termsExplainedToday(),
            feedback: AnalysisRecord.recentFeedback(in: modelContext),
            earlierResearch: searchesAgain ? nil : AnalysisRecord.todaysResearch(in: modelContext)
        ) { result in
            switch result {
            case .success:
                showsHolds = false
                page = 0
                searchesAgain = false
            case .failure(let failure):
                errorMessage = failure.message
            }
        }
    }

    /// Terms explained by analyses run earlier today, so Claude doesn't explain them again.
    private func termsExplainedToday() -> [String] {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let descriptor = FetchDescriptor<AnalysisRecord>(predicate: #Predicate { $0.date >= startOfDay })
        let records = (try? modelContext.fetch(descriptor)) ?? []
        var seen = Set<String>()
        return records.flatMap(\.explainedTerms).filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Results

    private func results(_ analysis: AnalysisRecord) -> some View {
        let ordered = analysis.orderedRecommendations
        let actionable = ordered.filter { $0.action != .hold }
        let holds = ordered.filter { $0.action == .hold }
        let slides = actionable + (showsHolds ? holds : [])

        return VStack(spacing: 8) {
            TabView(selection: $page) {
                summaryCard(analysis, recommendations: ordered, slideCount: slides.count)
                    .tag(0)
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, recommendation in
                    recommendationCard(recommendation)
                        .tag(index + 1)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .accessibilityIdentifier("analysis.slider")

            if !holds.isEmpty {
                Button {
                    withAnimation {
                        showsHolds.toggle()
                        // Jump to the first hold when showing them; step back if the current hold slide disappears
                        page = showsHolds ? actionable.count + 1 : min(page, actionable.count)
                    }
                } label: {
                    Label(
                        showsHolds ? "Hide Hold Recommendations" : "Show \(holds.count) Hold Recommendation\(holds.count == 1 ? "" : "s")",
                        systemImage: showsHolds ? "eye.slash" : "pause.circle"
                    )
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("analysis.toggleHolds")
            }
        }
        .padding(.bottom)
    }

    private func summaryCard(_ analysis: AnalysisRecord, recommendations: [RecommendationRecord], slideCount: Int) -> some View {
        let counts = RecommendationAction.allCases.compactMap { action -> String? in
            let count = recommendations.filter { $0.action == action }.count
            return count > 0 ? "\(count) \(action.rawValue)" : nil
        }

        return card {
            VStack(alignment: .leading, spacing: 4) {
                Text("Market Summary")
                    .font(.title3.bold())
                Text("Analysed \(analysis.date.formatted(.dateTime.day().month(.wide).year())) at \(analysis.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let researchDate = analysis.researchDate {
                    Label(
                        analysis.reusedResearch
                            ? "Research from \(researchDate.formatted(date: .omitted, time: .shortened)) (reused from an earlier analysis)"
                            : "Research done at the same time",
                        systemImage: analysis.reusedResearch ? "arrow.triangle.2.circlepath" : "magnifyingglass"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            MarkdownText(analysis.summary)

            if !counts.isEmpty {
                Text(counts.joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
            }
            if slideCount > 0 {
                Label("Swipe for recommendations", systemImage: "hand.draw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let notes = analysis.userInstructions {
                Text("Your notes: \(notes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !analysis.sources.isEmpty {
                DisclosureGroup("Sources (\(analysis.sources.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(analysis.sources, id: \.url) { source in
                            if let url = URL(string: source.url) {
                                Link(source.title, destination: url)
                                    .font(.caption)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .font(.subheadline)
            }

            Divider()
            SummaryFeedbackView(analysis: analysis)
        }
    }

    private func recommendationCard(_ recommendation: RecommendationRecord) -> some View {
        card {
            HStack(spacing: 12) {
                InvestmentLogoView(symbol: recommendation.symbol, category: recommendation.category)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recommendation.name)
                        .font(.title3.bold())
                        .lineLimit(2)
                    if let symbol = recommendation.symbol {
                        Text(symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                actionBadge(recommendation.action)
            }

            MarkdownText(recommendation.reason)

            Divider()

            Text("When recommended: \(recommendation.valueGBP.formatted(.currency(code: "GBP").precision(.fractionLength(0)))) · \(String(format: "%.1f%%", recommendation.portfolioPercentage)) of portfolio · target \(String(format: "%.1f%%", recommendation.targetPercentage))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            RecommendationFeedbackView(recommendation: recommendation)
        }
    }

    private func actionBadge(_ action: RecommendationAction) -> some View {
        let color: Color = switch action {
        case .buy: .green
        case .sell: .red
        case .hold: .gray
        }
        return Text(action.rawValue.uppercased())
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color, in: Capsule())
    }

    /// A scrollable slide, with room at the bottom for the page dots.
    private func card(@ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        // Swiping down over the card puts away the feedback keyboard
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 44)
    }
}
