//
//  MarketAnalysis.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import Foundation

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

/// One line in the live activity list shown while an analysis runs.
struct AnalysisActivity: Identifiable, Equatable {
    enum Kind {
        case thinking, searching, filtering, results, writing, problem

        var systemImage: String {
            switch self {
            case .thinking: "brain"
            case .searching: "magnifyingglass"
            case .filtering: "line.3.horizontal.decrease"
            case .results: "doc.text.magnifyingglass"
            case .writing: "pencil"
            case .problem: "exclamationmark.triangle"
            }
        }
    }

    let id: UUID
    let kind: Kind
    var text: String
    var detail: String?
}

/// Turns stream events into activity rows on the store: one row per search, result and thought,
/// with consecutive text blocks (citations split Claude's writing into many) merged into one row.
@MainActor
private final class AnalysisActivityRecorder {
    private let store: PortfolioStore
    /// Advanced once per web search, for the system's background progress UI
    private let searchProgress: Progress?
    private var phase = MarketAnalysisPhase.researching
    /// The row being written to, and the text of earlier blocks already in it
    private var writing: (rowID: UUID, blockID: UUID, earlierText: String, blockText: String)?
    /// Rows keep at most this much of Claude's writing; the view shows the latest part
    private static let maxRowText = 400

    init(store: PortfolioStore, searchProgress: Progress?) {
        self.store = store
        self.searchProgress = searchProgress
    }

    func begin(_ phase: MarketAnalysisPhase) {
        self.phase = phase
        writing = nil
    }

    func record(_ event: ClaudeStreamEvent) {
        switch event {
        case .text(let blockID, let text):
            recordWriting(blockID: blockID, text: text)
            return
        case .thinking(let id, let text):
            let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return }
            upsert(AnalysisActivity(id: id, kind: .thinking, text: String(summary.suffix(Self.maxRowText))))
        case .toolUse(let id, let name, let input):
            if name == "web_search" {
                upsert(AnalysisActivity(id: id, kind: .searching, text: "Searching: \(input["query"] as? String ?? "the web")"))
                if let searchProgress, searchProgress.completedUnitCount < searchProgress.totalUnitCount {
                    searchProgress.completedUnitCount += 1
                }
            } else if store.marketAnalysisActivity.last?.kind != .filtering {
                // Searches run inside a code sandbox that filters their results
                upsert(AnalysisActivity(id: id, kind: .filtering, text: "Filtering search results"))
            }
        case .searchResults(let id, let results, let errorCode):
            if let errorCode {
                let text = errorCode == "max_uses_exceeded" ? "Reached the search limit" : "A search failed (\(errorCode))"
                upsert(AnalysisActivity(id: id, kind: .problem, text: text))
            } else {
                var seen = Set<String>()
                let sites = results
                    .compactMap { URL(string: $0.url)?.host()?.replacingOccurrences(of: "www.", with: "") }
                    .filter { seen.insert($0).inserted }
                upsert(AnalysisActivity(
                    id: id,
                    kind: .results,
                    text: "Found \(results.count) result\(results.count == 1 ? "" : "s")",
                    detail: sites.isEmpty ? nil : sites.prefix(4).joined(separator: ", ")
                ))
            }
        }
        writing = nil
    }

    private func recordWriting(blockID: UUID, text: String) {
        if phase == .analysing {
            // The reply is JSON, so show how far through the recommendations Claude is instead of the raw text
            let count = text.components(separatedBy: "\"recommendation\"").count - 1
            let status = count > 0 ? "Writing recommendations (\(count) so far)" : "Writing the market summary"
            let rowID = writing?.rowID ?? UUID()
            writing = (rowID, blockID, "", text)
            upsert(AnalysisActivity(id: rowID, kind: .writing, text: status))
            return
        }

        var row = writing ?? (rowID: UUID(), blockID: blockID, earlierText: "", blockText: "")
        if row.blockID != blockID {
            // A new block straight after the last one continues the same row
            row = (row.rowID, blockID, row.earlierText + row.blockText, "")
        }
        row.blockText = text
        writing = row

        let full = (row.earlierText + row.blockText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return }
        upsert(AnalysisActivity(id: row.rowID, kind: .writing, text: String(full.suffix(Self.maxRowText))))
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
}

extension PortfolioStore {
    /// Web searches allowed while researching; enough to cover a dozen or so holdings plus the macro picture.
    private static let maxResearchSearches = 20

    /// Researches recent market news with web search, then asks Claude, acting as a financial analyst,
    /// for a buy/sell/hold recommendation on every investment (Cash is described but not rated).
    /// - Parameters:
    ///   - additionalInstructions: The user's optional notes; left out of the prompt entirely when blank.
    ///   - termsExplainedToday: Terms earlier analyses today already explained, so they aren't explained again.
    ///   - feedback: The user's likes, dislikes and comments on earlier analyses, newest first.
    ///   - progress: Advanced by one unit after each request (research, then analysis), for the system's background progress UI.
    func analyseMarket(
        additionalInstructions: String,
        termsExplainedToday: [String] = [],
        feedback: [AnalysisFeedback] = [],
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

        // Research is one unit of the overall progress, filled in a little per web search
        let searchProgress = progress.map {
            Progress(totalUnitCount: Int64(Self.maxResearchSearches), parent: $0, pendingUnitCount: 1)
        }
        let recorder = AnalysisActivityRecorder(store: self, searchProgress: searchProgress)

        let research: ClaudeAPI.Research
        switch await ClaudeAPI.research(
            researchPrompt(snapshots, date: date), maxSearches: Self.maxResearchSearches,
            http: http, apiKey: claudeAPIKey, onEvent: recorder.record
        ) {
        case .success(let value): research = value
        case .failure(let failure): return .failure(failure)
        }
        searchProgress?.completedUnitCount = Int64(Self.maxResearchSearches)

        marketAnalysisPhase = .analysing
        recorder.begin(.analysing)
        defer { progress?.completedUnitCount += 1 }

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
        let schema = ClaudeAPI.object([
            "summary": ["type": "string"],
            "recommendations": [
                "type": "array",
                "items": ClaudeAPI.object([
                    "investment": ["type": "integer"],
                    "recommendation": ["type": "string", "enum": RecommendationAction.allCases.map(\.rawValue)],
                    "reason": ["type": "string"]
                ])
            ],
            "explainedTerms": ["type": "array", "items": ["type": "string"]]
        ])

        let prompt = analysisPrompt(
            portfolio: portfolio, research: research, date: date,
            instructions: instructions, termsExplainedToday: termsExplainedToday, feedback: feedback
        )
        let result = await ClaudeAPI.streamJSON(
            [["type": "text", "text": prompt]], schema: schema, as: Response.self,
            maxTokens: 32000, http: http, apiKey: claudeAPIKey, onEvent: recorder.record
        )

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
                portfolioValueGBP: totalValue
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

        let investmentLines = snapshots.enumerated().map { index, snapshot -> String in
            guard let investment = byID[snapshot.id] else { return "" }
            let price: String = switch priceStatus(for: investment) {
            case .live: snapshot.price.map { "\($0) \(snapshot.currencyCode)" } ?? "unknown"
            case .manual: snapshot.price.map { "\($0) \(snapshot.currencyCode) (entered manually)" } ?? "value entered manually"
            case .noLivePrice: "no live price (value may be out of date)"
            }
            return """
            \(index + 1). \(snapshot.name) (\(snapshot.symbol ?? "no symbol")) — \(snapshot.category), sector: \(investment.sectorOrDefault)
               Value: \(Self.gbp(snapshot.valueGBP)) (\(Self.percent(snapshot.portfolioPercentage)) of portfolio) · \
            Target: \(Self.percent(snapshot.targetPercentage)) · Price: \(price)
               Holdings: \(holdingsDescription(investment, valueGBP: snapshot.valueGBP))
            """
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

        Investments:
        \(investmentLines.isEmpty ? "(none)" : investmentLines.joined(separator: "\n"))

        Uninvested cash:
        \(cashLines.isEmpty ? "(none)" : cashLines.joined(separator: "\n"))
        """
    }

    /// e.g. "Trading 212 ISA: 5 units (£750); Revolut Invest: 2 units (£300)"
    private func holdingsDescription(_ investment: Investment, valueGBP: Double) -> String {
        guard !investment.holdings.isEmpty else { return "(no holdings recorded)" }
        let total = investment.totalShares
        return investment.holdings.map { holding in
            let value = total > 0 ? valueGBP * holding.shares / total : 0
            return "\(holding.broker) \(holding.accountType): \(holding.shares.formatted()) units (\(Self.gbp(value)))"
        }.joined(separator: "; ")
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
        Spend more of your searches on the larger positions.

        Write concise, factual notes grouped by holding, then macro, then areas outside the portfolio. \
        Give the date and source of each point. Don't make recommendations — just report what you found.

        Holdings (largest first):
        \(holdings.isEmpty ? "(none)" : holdings)
        """
    }

    /// The analyst prompt: portfolio, research notes, and the rules for the recommendations.
    private func analysisPrompt(
        portfolio: String,
        research: ClaudeAPI.Research,
        date: Date,
        instructions: String,
        termsExplainedToday: [String],
        feedback: [AnalysisFeedback]
    ) -> String {
        let sources = research.sources.map { "- \($0.title) — \($0.url)" }.joined(separator: "\n")
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
        - Base your view on the research notes below, gathered from the web today. Rely on reputable sources (major \
        bank research notes, Morningstar, TipRanks/MarketBeat aggregated consensus) and name the source when a point \
        rests on it. Don't invent facts, figures or sources that aren't in the notes.

        How to write:
        - I'm not a finance professional. Never use a financial or economic term or acronym without briefly explaining \
        it in plain words the first time it appears in your response, even common-sounding ones — but don't over-explain. \
        Examples of the level expected:
          - "the Fed" → "the US central bank (its equivalent of the Bank of England)"
          - "rate hike" → "raised interest rates", plus one clause on what that generally means (borrowing gets more \
        expensive, which tends to cool inflation but also cool stock and gold prices)\(alreadyExplained)

        What to return:
        - summary: a short analysis (a few sentences) of the last few days in the market — the news that matters for my \
        portfolio (regulatory rulings, litigation, M&A, product launches, guidance changes, macro data releases) and \
        upcoming or recent company-specific events. Explain how this affects my portfolio (the biggest mover, the most \
        important portfolio-related news, any earnings) and which areas outside my portfolio I should start considering.
        - recommendations: exactly one per numbered investment below. "investment" is its list number, \
        "recommendation" is buy, sell or hold, and "reason" briefly summarises why.
        - explainedTerms: every term or acronym you explained in plain words in this response, as you wrote it (e.g. "the Fed").

        Formatting (summary and reason are shown on phone-sized cards, rendered as Markdown):
        - Use only this Markdown: **bold**, *italics*, bullet lists ("- "), "### " headings, and [links](https://…) to sources.
        - No tables, code blocks, images, or headings above "###".
        - summary: open with one or two plain sentences on the overall picture, then short "### " sections such as \
        "### Biggest mover", "### Portfolio news", "### Earnings" and "### Worth considering", each with a sentence or \
        a few short bullets. Leave out sections with nothing to say.
        - reason: two to four short bullets, with the deciding factor in **bold** first. If the recommendation goes \
        against the target gap, give that its own bullet.
        - Keep it concise. Bold the few words that matter most, not whole sentences.

        \(Self.feedbackSection(feedback))My portfolio:
        \(portfolio)

        Research notes:
        \(research.notes)

        Sources consulted:
        \(sources.isEmpty ? "(none listed)" : sources)
        """

        if !instructions.isEmpty {
            prompt += "\n\nAdditional instructions from me: \(instructions)"
        }
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
    private static func excerpt(_ text: String, maxLength: Int = 300) -> String {
        let flattened = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.count > maxLength ? String(flattened.prefix(maxLength)) + "…" : flattened
    }
}
