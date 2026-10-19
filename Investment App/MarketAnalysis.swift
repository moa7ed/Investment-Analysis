//
//  MarketAnalysis.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import Foundation
import OSLog

/// The step a market analysis is on, shown while it runs.
enum MarketAnalysisPhase {
    /// Claude is searching the web for recent news on the holdings and the market
    case researching
    /// Claude is turning the research into recommendations
    case analysing

    var message: String {
        switch self {
        case .researching: "Researching the latest market news…"
        case .analysing: "Writing recommendations…"
        }
    }
}

/// Whether iOS agreed to keep a running analysis going if the app leaves the screen.
enum MarketAnalysisBackground: Equatable {
    case allowed
    /// With iOS's reason, in plain words
    case unavailable(String)
}

/// One line in the live activity list shown while an analysis runs — one per major step, updated in place.
struct AnalysisActivity: Identifiable, Equatable {
    enum Kind {
        /// Researching the market (web searches)
        case searching
        /// Writing the market summary and recommendations
        case writing
        /// A finished step
        case done
        case problem

        var systemImage: String {
            switch self {
            case .searching: "magnifyingglass"
            case .writing: "pencil"
            case .done: "checkmark.circle.fill"
            case .problem: "exclamationmark.triangle"
            }
        }
    }

    let id: UUID
    let kind: Kind
    var text: String
    var detail: String?
}

/// Turns stream events into a short list of major steps on the store: one research row (search and site
/// counts plus the current search), one writing row, and a row per kind of problem. Claude's thinking and
/// the text it streams aren't shown.
@MainActor
private final class AnalysisActivityRecorder {
    private let store: PortfolioStore
    /// The current step's progress (research, then writing), for the system's background progress UI
    private var stepProgress: Progress?
    /// Units in each step's progress; fine-grained so small, steady advances are possible
    static let stepUnits: Int64 = 10_000
    /// A step never reports more than this until it really finishes
    private static let stepCap: Int64 = 9_500

    private let researchRowID = UUID()
    private let writingRowID = UUID()
    private var searchCount = 0
    private var sites = Set<String>()
    private var latestQuery: String?
    /// True when today's earlier research is reused, so the research row keeps saying so
    private var researchReused = false
    /// Problem rows by message, so a repeated problem (e.g. every search over the limit) shows once
    private var problemRowIDs: [String: UUID] = [:]

    init(store: PortfolioStore, stepProgress: Progress?) {
        self.store = store
        self.stepProgress = stepProgress
        updateResearchRow(done: false)
    }

    /// Shows that today's earlier research is being used instead of a new web search.
    func reuseResearch(from date: Date) {
        researchReused = true
        upsert(AnalysisActivity(
            id: researchRowID,
            kind: .done,
            text: "Using today's research from \(date.formatted(date: .omitted, time: .shortened))",
            detail: "No new web searches this time"
        ))
    }

    /// Marks research done (unless it was reused) and starts the writing step.
    func beginWriting(stepProgress: Progress?) {
        self.stepProgress = stepProgress
        if !researchReused {
            updateResearchRow(done: true)
        }
        upsert(AnalysisActivity(id: writingRowID, kind: .writing, text: "Writing the market summary"))
    }

    /// Moves progress a little every few seconds while the analysis runs. Searches run on Anthropic's servers and
    /// can leave the stream silent for a while; without this the background task would look stuck to iOS.
    private var heartbeat: Task<Void, Never>?

    func startHeartbeat() {
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.advanceProgress(fraction: 0.002)
            }
        }
    }

    func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    /// Moves the step's progress a fraction of the way to the cap. Each advance is smaller than the last,
    /// so the bar keeps moving however long the step takes, without reaching the end before it's done.
    private func advanceProgress(fraction: Double) {
        guard let stepProgress else { return }
        let remaining = Self.stepCap - stepProgress.completedUnitCount
        guard remaining > 0 else { return }
        stepProgress.completedUnitCount += max(1, Int64(Double(remaining) * fraction))
    }

    func record(_ event: ClaudeStreamEvent) {
        // Every event shows the work is moving; searches count for much more
        if case .toolUse(_, "web_search", _) = event {
            advanceProgress(fraction: 0.05)
        } else {
            advanceProgress(fraction: 0.0005)
        }

        switch event {
        case .toolUse(_, let name, let input) where name == "web_search":
            searchCount += 1
            latestQuery = input["query"] as? String
            updateResearchRow(done: false)

        case .searchResults(_, let results, let errorCode):
            if let errorCode {
                recordProblem(errorCode == "max_uses_exceeded" ? "Reached the search limit" : "A search failed (\(errorCode))")
            } else {
                sites.formUnion(results.compactMap { URL(string: $0.url)?.host()?.replacingOccurrences(of: "www.", with: "") })
                updateResearchRow(done: false)
            }

        case .text(_, let text) where store.marketAnalysisPhase == .analysing:
            // The reply is JSON, so show how far through the recommendations Claude is instead of the text
            let count = text.components(separatedBy: "\"recommendation\"").count - 1
            upsert(AnalysisActivity(
                id: writingRowID,
                kind: .writing,
                text: count > 0 ? "Writing recommendations (\(count) so far)" : "Writing the market summary"
            ))

        default:
            // Thinking, research notes as they're written, and result filtering aren't shown
            break
        }
    }

    private func updateResearchRow(done: Bool) {
        let counts = searchCount == 0
            ? nil
            : "\(searchCount) search\(searchCount == 1 ? "" : "es") · \(sites.count) site\(sites.count == 1 ? "" : "s")"
        if done {
            upsert(AnalysisActivity(id: researchRowID, kind: .done, text: "Researched the market", detail: counts))
        } else {
            let detail = [counts, latestQuery.map { "Now: \($0)" }].compactMap { $0 }.joined(separator: "\n")
            upsert(AnalysisActivity(
                id: researchRowID, kind: .searching, text: "Researching the market", detail: detail.isEmpty ? nil : detail
            ))
        }
    }

    private func recordProblem(_ message: String) {
        guard problemRowIDs[message] == nil else { return }
        let id = UUID()
        problemRowIDs[message] = id
        upsert(AnalysisActivity(id: id, kind: .problem, text: message))
    }

    private func upsert(_ activity: AnalysisActivity) {
        if let index = store.marketAnalysisActivity.firstIndex(where: { $0.id == activity.id }) {
            store.marketAnalysisActivity[index] = activity
        } else {
            store.marketAnalysisActivity.append(activity)
        }
    }
}

enum RecommendationAction: String, Codable, CaseIterable {
    case buy, sell, hold
}

/// A web page Claude cited while researching.
struct AnalysisSource: Codable, Hashable {
    let title: String
    let url: String
}

/// An investment as it stood when the analysis ran, saved with its recommendation so later reviews
/// can compare the advice against what happened next.
struct InvestmentSnapshot {
    let id: UUID
    let name: String
    let symbol: String?
    let category: String
    let price: Double?
    let currencyCode: String
    let valueGBP: Double
    let portfolioPercentage: Double
    let targetPercentage: Double
}

/// The result of one market analysis run.
struct MarketAnalysis {
    struct Recommendation {
        let investment: InvestmentSnapshot
        let action: RecommendationAction
        let reason: String
    }

    let date: Date
    let summary: String
    let recommendations: [Recommendation]
    /// Terms Claude explained in plain words, so later runs the same day don't explain them again
    let explainedTerms: [String]
    let sources: [AnalysisSource]
    let userInstructions: String?
    let portfolioValueGBP: Double
    /// The web research the recommendations were based on, saved so later runs the same day can reuse it
    let researchNotes: String
    /// When that research was done; earlier than `date` when it was reused from an earlier run
    let researchDate: Date
}

/// Research saved from an earlier run today, reused instead of searching the web again.
struct EarlierResearch {
    let notes: String
    let sources: [AnalysisSource]
    let date: Date
}

extension PortfolioStore {
    /// Web searches allowed per research request (the tool's `max_uses`); Claude is told this budget in the prompt.
    /// At $10 per 1,000 searches, a full budget is about $0.50 plus the tokens for reading the results.
    private static let maxResearchSearches = 50

    /// Researches recent market news with web search, then asks Claude, acting as a financial analyst,
    /// for a buy/sell/hold recommendation on every investment (Cash is described but not rated).
    /// - Parameters:
    ///   - additionalInstructions: The user's optional notes; left out of the prompt entirely when blank.
    ///   - termsExplainedToday: Terms earlier analyses today already explained, so they aren't explained again.
    ///   - feedback: The user's likes, dislikes and comments on earlier analyses, newest first.
    ///   - earlierResearch: Today's research from an earlier run; when set, the web isn't searched again and
    ///     Claude is told when the notes were gathered.
    ///   - progress: One unit for research and one for writing, each advanced steadily as Claude streams,
    ///     for the system's background progress UI.
    func analyseMarket(
        additionalInstructions: String,
        termsExplainedToday: [String] = [],
        feedback: [AnalysisFeedback] = [],
        earlierResearch: EarlierResearch? = nil,
        progress: Progress? = nil
    ) async -> Result<MarketAnalysis, ClaudeFailure> {
        guard hasAPIKey else { return .failure(.missingKey) }

        let date = Date()
        let instructions = additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        // Captured up front: Claude replies by list number, and prices may refresh while it works
        let snapshots = analysisSnapshots()
        let portfolio = analysisPortfolioDescription(snapshots)
        let totalValue = investments.reduce(0) { $0 + unfilteredValueInGBP($1) }

        marketAnalysisPhase = .researching
        marketAnalysisActivity = []
        defer { marketAnalysisPhase = nil }

        // Research and writing are one unit each of the overall progress. Each moves on every streamed event
        // (more per search), so iOS sees steady progress and doesn't treat the background task as stuck.
        let researchProgress = progress.map {
            Progress(totalUnitCount: AnalysisActivityRecorder.stepUnits, parent: $0, pendingUnitCount: 1)
        }
        let recorder = AnalysisActivityRecorder(store: self, stepProgress: researchProgress)
        recorder.startHeartbeat()
        defer { recorder.stopHeartbeat() }

        let research: ClaudeAPI.Research
        let researchDate: Date
        if let earlierResearch {
            // Today's research already exists: reuse it instead of searching (and paying for) the web again
            research = ClaudeAPI.Research(notes: earlierResearch.notes, sources: earlierResearch.sources)
            researchDate = earlierResearch.date
            recorder.reuseResearch(from: earlierResearch.date)
            ClaudeLog.logger.info("Reusing research from \(earlierResearch.date.formatted(), privacy: .public)")
        } else {
            switch await ClaudeAPI.research(
                researchPrompt(snapshots, date: date), maxSearches: Self.maxResearchSearches,
                http: http, apiKey: claudeAPIKey, onEvent: recorder.record
            ) {
            case .success(let value): research = value
            case .failure(let failure):
                ClaudeLog.logger.error("Market analysis failed while researching: \(failure.message, privacy: .public)")
                return .failure(.during(step: "Researching the market", failure))
            }
            researchDate = date
            ClaudeLog.logger.info("Research done: \(research.notes.count, privacy: .public) characters of notes, \(research.sources.count, privacy: .public) sources")
        }
        researchProgress?.completedUnitCount = AnalysisActivityRecorder.stepUnits

        marketAnalysisPhase = .analysing
        let writingProgress = progress.map {
            Progress(totalUnitCount: AnalysisActivityRecorder.stepUnits, parent: $0, pendingUnitCount: 1)
        }
        recorder.beginWriting(stepProgress: writingProgress)
        defer { writingProgress?.completedUnitCount = AnalysisActivityRecorder.stepUnits }

        struct Response: Decodable {
            let summary: String
            let recommendations: [Item]
            let explainedTerms: [String]
            struct Item: Decodable {
                let investment: Int
                let recommendation: RecommendationAction
                let reason: String
            }
        }
        // The API enforces this schema (structured outputs); descriptions repeat the prompt's rules per field
        let schema = ClaudeAPI.object([
            "summary": [
                "type": "string",
                "description": "Short market analysis in Markdown (### sections, bullets, bold), as the prompt describes."
            ],
            "recommendations": [
                "type": "array",
                "description": "Exactly one item per numbered investment (1 to \(snapshots.count)), in list order.",
                "items": ClaudeAPI.object([
                    "investment": [
                        "type": "integer",
                        "description": "The investment's list number, from 1 to \(snapshots.count)."
                    ],
                    "recommendation": [
                        "type": "string",
                        "enum": RecommendationAction.allCases.map(\.rawValue),
                        "description": "buy, sell or hold, in lowercase."
                    ],
                    "reason": [
                        "type": "string",
                        "description": "Markdown bullets, deciding factor in bold first: two to four for buy or sell, one for hold."
                    ]
                ])
            ],
            "explainedTerms": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Terms explained in plain words in this response, as written; empty if none."
            ]
        ])

        let prompt = analysisPrompt(
            portfolio: portfolio, research: research, researchDate: researchDate, date: date,
            investmentCount: snapshots.count,
            instructions: instructions, termsExplainedToday: termsExplainedToday, feedback: feedback
        )
        let result = await ClaudeAPI.streamJSON(
            [["type": "text", "text": prompt]], schema: schema, as: Response.self,
            maxTokens: 32000, http: http, apiKey: claudeAPIKey, onEvent: recorder.record
        )
        .mapError { failure -> ClaudeFailure in
            ClaudeLog.logger.error("Market analysis failed while writing recommendations: \(failure.message, privacy: .public)")
            return .during(step: "Writing recommendations", failure)
        }

        if case .success(let response) = result {
            let returned = Set(response.recommendations.map(\.investment))
            let missing = snapshots.indices.map { $0 + 1 }.filter { !returned.contains($0) }
            if !missing.isEmpty {
                ClaudeLog.logger.notice("Claude left out investments \(missing.map(String.init).joined(separator: ", "), privacy: .public)")
            }
        }

        return result.map { response in
            // One recommendation per investment; unknown list numbers and repeats are dropped
            var seen = Set<Int>()
            let recommendations = response.recommendations.compactMap { item -> MarketAnalysis.Recommendation? in
                guard snapshots.indices.contains(item.investment - 1), seen.insert(item.investment).inserted else { return nil }
                return MarketAnalysis.Recommendation(
                    investment: snapshots[item.investment - 1],
                    action: item.recommendation,
                    reason: item.reason
                )
            }
            return MarketAnalysis(
                date: date,
                summary: response.summary,
                recommendations: recommendations,
                explainedTerms: response.explainedTerms,
                sources: research.sources,
                userInstructions: instructions.isEmpty ? nil : instructions,
                portfolioValueGBP: totalValue,
                researchNotes: research.notes,
                researchDate: researchDate
            )
        }
    }

    // MARK: - Portfolio Description

    /// GBP value of the whole investment, ignoring the home page's broker/type filter.
    private func unfilteredValueInGBP(_ investment: Investment) -> Double {
        investment.totalValue * (exchangeRates[investment.currencyCode] ?? 1.0)
    }

    private func isCash(_ investment: Investment) -> Bool {
        investment.category.lowercased() == "cash"
    }

    /// Every non-cash investment, numbered by position, as it stands now.
    private func analysisSnapshots() -> [InvestmentSnapshot] {
        let total = investments.reduce(0) { $0 + unfilteredValueInGBP($1) }
        return investments.filter { !isCash($0) }.map { investment in
            let value = unfilteredValueInGBP(investment)
            return InvestmentSnapshot(
                id: investment.id,
                name: investment.name,
                symbol: investment.symbol,
                category: investment.category,
                price: investment.effectivePrice,
                currencyCode: investment.currencyCode,
                valueGBP: value,
                portfolioPercentage: total > 0 ? value / total * 100 : 0,
                targetPercentage: investment.targetPercentage
            )
        }
    }

    private static func gbp(_ value: Double) -> String {
        value.formatted(.currency(code: "GBP").precision(.fractionLength(0)))
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    /// The numbered investments with their holdings per broker and account type, then cash per account.
    private func analysisPortfolioDescription(_ snapshots: [InvestmentSnapshot]) -> String {
        let total = investments.reduce(0) { $0 + unfilteredValueInGBP($1) }
        let byID = Dictionary(uniqueKeysWithValues: investments.map { ($0.id, $0) })

        // One compact line per investment; the legend above the list explains the fields once
        let investmentLines = snapshots.enumerated().map { index, snapshot -> String in
            guard let investment = byID[snapshot.id] else { return "" }
            let price: String = switch priceStatus(for: investment) {
            case .live: snapshot.price.map { "\(Self.compact($0)) \(snapshot.currencyCode)" } ?? "price unknown"
            case .manual: snapshot.price.map { "\(Self.compact($0)) \(snapshot.currencyCode) (manual)" } ?? "manual value"
            case .noLivePrice: "no live price"
            }
            return "\(index + 1). \(snapshot.name) (\(snapshot.symbol ?? "—")) | \(snapshot.category) | "
                + "\(investment.sectorOrDefault) | \(Self.gbp(snapshot.valueGBP)) | "
                + "\(Self.percent(snapshot.portfolioPercentage)) → \(Self.percent(snapshot.targetPercentage)) | "
                + "\(price) | \(holdingsDescription(investment, valueGBP: snapshot.valueGBP))"
        }

        let cashLines = investments.filter(isCash).flatMap { cash in
            let value = unfilteredValueInGBP(cash)
            return cash.holdings.map { holding in
                let share = cash.totalShares > 0 ? holding.shares / cash.totalShares : 0
                return "- \(holding.broker) \(holding.accountType): \(Self.gbp(value * share))"
            }
        }

        return """
        Total value: \(Self.gbp(total))

        Investments — number. name (symbol) | category | sector | value in GBP | current % of portfolio → target % \
        | price | holdings per broker and account type (units, GBP value):
        \(investmentLines.isEmpty ? "(none)" : investmentLines.joined(separator: "\n"))

        Uninvested cash:
        \(cashLines.isEmpty ? "(none)" : cashLines.joined(separator: "\n"))
        """
    }

    /// e.g. "Trading 212 ISA 5 (£750); Revolut Invest 2.5 (£300)"
    private func holdingsDescription(_ investment: Investment, valueGBP: Double) -> String {
        guard !investment.holdings.isEmpty else { return "no holdings recorded" }
        let total = investment.totalShares
        return investment.holdings.map { holding in
            let value = total > 0 ? valueGBP * holding.shares / total : 0
            return "\(holding.broker) \(holding.accountType) \(Self.compact(holding.shares)) (\(Self.gbp(value)))"
        }.joined(separator: "; ")
    }

    /// A number with up to 6 significant digits, e.g. 12.80484953 → "12.8048", 22785946.54 → "22785900".
    private static func compact(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(1...6)).grouping(.never))
    }

    // MARK: - Prompts

    private static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    /// Asks Claude to gather recent news with web search, without recommending anything yet.
    private func researchPrompt(_ snapshots: [InvestmentSnapshot], date: Date) -> String {
        let holdings = snapshots
            .sorted { $0.valueGBP > $1.valueGBP }
            .map { "- \($0.name) (\($0.symbol ?? "no symbol")), \($0.category) — \(Self.percent($0.portfolioPercentage)) of portfolio" }
            .joined(separator: "\n")

        return """
        Today is \(Self.longDate(date)). I'm a UK-based investor. Research the latest market news for my portfolio, \
        so that an analyst can make buy/sell/hold recommendations from your notes.

        Use web search. Focus on the last few days, and include upcoming events. For each holding below, find:
        - Asset-specific news: regulatory rulings, litigation, M&A, product launches, guidance changes, earnings results
        - Upcoming company-specific events: earnings dates, product launches, regulatory decisions, litigation outcomes
        - The current analyst consensus (rating and average price target) and notable recent upgrades or downgrades
        - Notable recent price moves

        Also cover:
        - The macro backdrop relevant to these holdings: central bank decisions (especially the Bank of England and the \
        US Federal Reserve), inflation and jobs data, and any UK changes affecting ISAs or Capital Gains Tax
        - Two or three areas outside this portfolio that are worth considering now

        Rely on reputable sources: major bank research notes, Morningstar, TipRanks/MarketBeat aggregated consensus, \
        established financial news (Reuters, Bloomberg, Financial Times, CNBC) and company filings. \
        You have a budget of \(Self.maxResearchSearches) web searches for this research; any beyond that will fail. \
        Plan them across the \(snapshots.count) holdings and the macro picture: use broad searches that cover several \
        holdings at once (e.g. sector or index news), give the larger positions their own searches, and stop once \
        you have enough — you don't have to use the whole budget.

        Write compact, factual bullet notes — they're read by an analyst, not shown to me, so skip introductions, \
        summaries and repetition. Group them by holding, then macro, then areas outside the portfolio. Use about \
        40–80 words per holding, more only for genuinely major news; for a holding with nothing material, write just \
        "no material news". Give the date and source of each point (e.g. "Reuters, 16 Oct"). Don't make \
        recommendations — just report what you found.

        Holdings (largest first):
        \(holdings.isEmpty ? "(none)" : holdings)
        """
    }

    /// The analyst prompt: portfolio, research notes, and the rules for the recommendations.
    private func analysisPrompt(
        portfolio: String,
        research: ClaudeAPI.Research,
        researchDate: Date,
        date: Date,
        investmentCount: Int,
        instructions: String,
        termsExplainedToday: [String],
        feedback: [AnalysisFeedback]
    ) -> String {
        // Reused research is from earlier today; say when, so Claude weighs how fresh it is
        let isReused = date.timeIntervalSince(researchDate) > 60
        let researchTime = researchDate.formatted(date: .omitted, time: .shortened)
        let researchSource = isReused
            ? "gathered from the web earlier today at \(researchTime) and not refreshed for this analysis — news after \(researchTime) isn't covered"
            : "gathered from the web today"
        let alreadyExplained = termsExplainedToday.isEmpty
            ? ""
            : "\n  Terms already explained to me earlier today (don't explain these again): \(termsExplainedToday.joined(separator: ", "))"

        var prompt = """
        Today is \(Self.longDate(date)). Act as an experienced financial analyst. Do a deep investment analysis of my \
        portfolio and give your best recommendation for each investment I hold.

        About me and how to judge:
        - I'm a UK investor. Take UK rules into account, especially ISA accounts (no Capital Gains Tax or income tax \
        on what's held inside them) versus taxable accounts ("Invest" and "General"), where selling at a profit can \
        trigger Capital Gains Tax. Where it matters, say which account to act in.
        - Consider my whole portfolio: concentration, diversification, and the uninvested cash I have per account.
        - Each investment has a target allocation, but matching current to target is only one factor, not the goal. \
        For each investment, form your view from the market analysis and your own financial judgement, and weigh the \
        gap between its current and target weight alongside that — never let the gap decide on its own. The two can \
        conflict: an investment below its target can still be a hold, or even a sell, if its outlook is poor, and one \
        above its target can still be a buy if its outlook is strong, even though that widens the gap. When your \
        recommendation goes against the target gap, say so briefly in the reason.
        - My targets don't have to add up to exactly 100%. Ignore that and give directional buy/sell/hold guidance regardless.
        - Base your view on the research notes below, \(researchSource). Rely on reputable sources (major \
        bank research notes, Morningstar, TipRanks/MarketBeat aggregated consensus) and name the source when a point \
        rests on it. Don't invent facts, figures or sources that aren't in the notes.

        How to write:
        - I'm not a finance professional. Never use a financial or economic term or acronym without briefly explaining \
        it in plain words the first time it appears in your response, even common-sounding ones — but don't over-explain. \
        Examples of the level expected:
          - "the Fed" → "the US central bank (its equivalent of the Bank of England)"
          - "rate hike" → "raised interest rates", plus one clause on what that generally means (borrowing gets more \
        expensive, which tends to cool inflation but also cool stock and gold prices)\(alreadyExplained)

        Response format — your reply is read by an app, so it must be a single JSON object with exactly these three \
        fields and nothing before or after it:
        - "summary" (string): a short analysis (a few sentences) of the last few days in the market — the news that \
        matters for my portfolio (regulatory rulings, litigation, M&A, product launches, guidance changes, macro data \
        releases) and upcoming or recent company-specific events. Explain how this affects my portfolio (the biggest \
        mover, the most important portfolio-related news, any earnings) and which areas outside my portfolio I should \
        start considering.
        - "recommendations" (array): exactly \(investmentCount) items, one for each numbered investment below, in list \
        order. Each item has:
          - "investment" (integer): the investment's list number, from 1 to \(investmentCount). Only numbers from the \
        list — uninvested cash isn't numbered and gets no recommendation.
          - "recommendation" (string): exactly "buy", "sell" or "hold", in lowercase.
          - "reason" (string): why, briefly.
        - "explainedTerms" (array of strings): every term or acronym you explained in plain words in this response, \
        as you wrote it (e.g. "the Fed"). Use an empty array if you explained none.
        Line breaks inside the Markdown text are part of the JSON string, written as \\n.

        Formatting (summary and reason are shown on phone-sized cards, rendered as Markdown):
        - Use only this Markdown: **bold**, *italics*, bullet lists ("- "), "### " headings, and [links](https://…) to sources.
        - No tables, code blocks, images, or headings above "###".
        - summary: open with one or two plain sentences on the overall picture, then short "### " sections such as \
        "### Biggest mover", "### Portfolio news", "### Earnings" and "### Worth considering", each with a sentence or \
        a few short bullets. Leave out sections with nothing to say.
        - reason for a buy or sell: two to four short bullets, with the deciding factor in **bold** first. If the \
        recommendation goes against the target gap, give that its own bullet.
        - reason for a hold: one short bullet with the deciding factor in **bold** — holds are hidden unless I ask \
        for them, so keep these brief.
        - Keep it concise. Bold the few words that matter most, not whole sentences.

        \(Self.feedbackSection(feedback))My portfolio:
        \(portfolio)

        Research notes (\(isReused ? "from \(researchTime) today" : "from today")):
        \(research.notes)
        """

        if !instructions.isEmpty {
            prompt += "\n\nAdditional instructions from me: \(instructions)"
        }
        // Last, after the long data and any notes, so the format holds whatever came before
        prompt += """


        Reply with the JSON object only: "summary", "recommendations" (exactly \(investmentCount) items, numbers 1 to \
        \(investmentCount)) and "explainedTerms".
        """
        return prompt
    }

    /// The user's feedback on earlier analyses, quoting what Claude said so it knows what was liked or disliked.
    /// Empty when there's no feedback; otherwise ends with a blank line.
    private static func feedbackSection(_ feedback: [AnalysisFeedback]) -> String {
        guard !feedback.isEmpty else { return "" }

        let lines = feedback.map { item -> String in
            let date = item.date.formatted(.dateTime.day().month(.abbreviated).year())
            let reaction = switch item.rating {
            case .like: "liked"
            case .dislike: "disliked"
            case nil: "commented on"
            }
            let comment = item.comment.map { " — my comment: \"\($0)\"" } ?? ""
            switch item.subject {
            case .summary(let summary):
                return "- \(date): I \(reaction) your market summary\(comment). You had written: \"\(excerpt(summary))\""
            case .recommendation(let name, let symbol, let action, let reason):
                let investment = symbol.map { "\(name) (\($0))" } ?? name
                return "- \(date): I \(reaction) your \(action.rawValue) recommendation for \(investment)\(comment). " +
                    "Your reason was: \"\(excerpt(reason))\""
            }
        }

        return """
        My feedback on your earlier analyses (newest first). Use it to make this analysis more useful to me: keep \
        doing what I liked, avoid what I disliked, and take my comments into account where they still apply. A \
        dislike isn't an instruction to reverse a call — if the evidence still supports it, keep it and address my \
        concern in the reason.
        \(lines.joined(separator: "\n"))


        """
    }

    /// A single-line, shortened quote of earlier Markdown output.
    private static func excerpt(_ text: String, maxLength: Int = 150) -> String {
        let flattened = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.count > maxLength ? String(flattened.prefix(maxLength)) + "…" : flattened
    }
}
