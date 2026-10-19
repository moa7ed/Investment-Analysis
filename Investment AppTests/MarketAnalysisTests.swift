//
//  MarketAnalysisTests.swift
//  Investment AppTests
//

import Foundation
import SwiftData
import Testing
@testable import Investment_App

@MainActor
@Suite("Market analysis via Claude")
struct MarketAnalysisTests {
    /// Apple in two accounts, Tesla in one, plus cash (the store creates "Cash" itself).
    private func makePortfolio(http: StubHTTPClient) -> PortfolioStore {
        let store = makeStore(http: http)
        var apple = Investment(name: "Apple", symbol: "AAPL", targetPercentage: 20, currencyCode: "GBP", holdings: [
            Holding(broker: "Trading 212", accountType: "ISA", shares: 3),
            Holding(broker: "Revolut", accountType: "Invest", shares: 1)
        ])
        apple.apiPrice = 100
        var tesla = Investment(name: "Tesla", symbol: "TSLA", targetPercentage: 10, currencyCode: "GBP", holdings: [
            Holding(broker: "Revolut", accountType: "Invest", shares: 2)
        ])
        tesla.apiPrice = 50
        store.investments.append(contentsOf: [apple, tesla])
        if let cash = store.investments.firstIndex(where: { $0.name == "Cash" }) {
            store.investments[cash].holdings = [Holding(broker: "Trading 212", accountType: "ISA", shares: 200)]
        }
        return store
    }

    private func stubAnalysis(_ http: StubHTTPClient, recommendations: [[String: Any]], terms: [String] = []) {
        http.claude { prompt in
            if prompt.contains("Research the latest market news") {
                return .json("Apple beat earnings expectations (Reuters, 16 Oct).")
            }
            if prompt.contains("Act as an experienced financial analyst") {
                return .json(StubHTTPClient.jsonString([
                    "summary": "A calm week.", "recommendations": recommendations, "explainedTerms": terms
                ]))
            }
            return nil
        }
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Researches with web search first, then asks for JSON; both opt into refusal fallback")
    func requestShapes() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [])
        _ = await makePortfolio(http: http).analyseMarket(additionalInstructions: "")

        #expect(http.claudeRequests.count == 2)
        let research = try body(of: http.claudeRequests[0])
        let tool = try #require((research["tools"] as? [[String: Any]])?.first)
        #expect(tool["type"] as? String == "web_search_20260209")
        #expect(research["output_config"] == nil)
        #expect(research["fallbacks"] as? String == "default")
        #expect(research["stream"] as? Bool == true)
        #expect((research["thinking"] as? [String: Any])?["display"] as? String == "summarized")

        let analysis = try body(of: http.claudeRequests[1])
        let format = (analysis["output_config"] as? [String: Any])?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        #expect(analysis["tools"] == nil)
        #expect(analysis["fallbacks"] as? String == "default")
        #expect(analysis["stream"] as? Bool == true)
        for request in http.claudeRequests {
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == ClaudeAPI.fallbackBeta)
        }
    }

    @Test("The analyst prompt has holdings per account, cash, UK tax rules, targets and the research")
    func promptContents() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [])
        _ = await makePortfolio(http: http).analyseMarket(additionalInstructions: "", termsExplainedToday: ["the Fed"])

        let prompt = try #require(http.claudePrompts.last)
        #expect(prompt.contains("1. Apple (AAPL)"))
        #expect(prompt.contains("2. Tesla (TSLA)"))
        #expect(prompt.contains("Trading 212 ISA 3 (£300)"))
        #expect(prompt.contains("Revolut Invest 1 (£100)"))
        #expect(prompt.contains("57.14% → 20.00%"))
        #expect(!prompt.contains("Sources consulted"), "Sources aren't sent twice")
        #expect(prompt.contains("reason for a hold: one short bullet"))
        #expect(prompt.contains("Uninvested cash:"))
        #expect(!prompt.contains("3. Cash"), "Cash isn't rated")
        #expect(prompt.contains("Capital Gains Tax"))
        #expect(prompt.contains("ISA"))
        #expect(prompt.contains("don't have to add up to exactly 100%"))
        #expect(prompt.contains("matching current to target is only one factor"))
        #expect(prompt.contains("even though that widens the gap"))
        #expect(prompt.contains("rendered as Markdown"))
        #expect(prompt.contains("Morningstar"))
        #expect(prompt.contains("Apple beat earnings expectations"))
        #expect(prompt.contains("don't explain these again): the Fed"))
        #expect(!prompt.contains("Additional instructions"))
    }

    @Test("The user's notes are sent only when not blank")
    func userNotes() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [])
        let store = makePortfolio(http: http)

        _ = await store.analyseMarket(additionalInstructions: "  I'm saving for a house  ")
        let withNotes = try #require(http.claudePrompts.last)
        #expect(withNotes.contains("Additional instructions from me: I'm saving for a house"))

        _ = await store.analyseMarket(additionalInstructions: "   ")
        let withoutNotes = try #require(http.claudePrompts.last)
        #expect(!withoutNotes.contains("Additional instructions"))
    }

    @Test("Recommendations map to the numbered investments; unknown numbers and repeats are dropped")
    func mapsRecommendations() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [
            ["investment": 2, "recommendation": "sell", "reason": "Over target."],
            ["investment": 1, "recommendation": "buy", "reason": "Under target."],
            ["investment": 1, "recommendation": "hold", "reason": "Duplicate."],
            ["investment": 9, "recommendation": "buy", "reason": "Unknown."]
        ], terms: ["ISA"])
        let store = makePortfolio(http: http)

        let analysis = try await store.analyseMarket(additionalInstructions: "").get()
        #expect(analysis.summary == "A calm week.")
        #expect(analysis.recommendations.map(\.investment.name) == ["Tesla", "Apple"])
        #expect(analysis.recommendations.map(\.action) == [.sell, .buy])
        #expect(analysis.recommendations[1].investment.id == store.investment(named: "Apple")?.id)
        // Apple £400 of a £700 portfolio (Apple 400 + Tesla 100 + cash 200)
        #expect(abs(analysis.recommendations[1].investment.portfolioPercentage - 400.0 / 700 * 100) < 0.001)
        #expect(analysis.explainedTerms == ["ISA"])
        #expect(analysis.userInstructions == nil)
        #expect(store.marketAnalysisPhase == nil)
    }

    @Test("A paused research turn is resumed by sending the paused content back")
    func resumesPausedResearch() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [])
        let calls = Counter()
        http.on { request in
            guard StubHTTPClient.promptText(of: request).contains("Research the latest market news") else { return nil }
            let first = calls.increment() == 1
            let reply: [String: Any] = first
                ? ["content": [["type": "text", "text": "Searching. "], ["type": "server_tool_use", "id": "srv_1", "name": "web_search", "input": ["query": "AAPL"]]], "stop_reason": "pause_turn"]
                : ["content": [["type": "text", "text": "Apple is up.", "citations": [["type": "web_search_result_location", "url": "https://reuters.com/a", "title": "Reuters"]]]], "stop_reason": "end_turn"]
            return (200, try! JSONSerialization.data(withJSONObject: reply))
        }

        let analysis = try await makePortfolio(http: http).analyseMarket(additionalInstructions: "").get()
        #expect(analysis.sources == [AnalysisSource(title: "Reuters", url: "https://reuters.com/a")])

        let resumed = try body(of: http.claudeRequests[1])
        let messages = try #require(resumed["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[1]["role"] as? String == "assistant")
        #expect((messages[1]["content"] as? [[String: Any]])?.last?["id"] as? String == "srv_1")
        let analystPrompt = try #require(http.claudePrompts.last)
        #expect(analystPrompt.contains("Searching. Apple is up."))
    }

    @Test("Feedback on earlier analyses is collected, newest first, skipping anything not rated or commented")
    func collectsFeedback() throws {
        let container = try ModelContainer(for: AnalysisRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let snapshot = InvestmentSnapshot(
            id: UUID(), name: "Apple", symbol: "AAPL", category: "Stock", price: 100,
            currencyCode: "GBP", valueGBP: 400, portfolioPercentage: 50, targetPercentage: 20
        )
        func record(daysAgo: Double, summary: String) -> AnalysisRecord {
            let date = Date(timeIntervalSinceNow: -daysAgo * 86_400)
            return AnalysisRecord(MarketAnalysis(
                date: date, summary: summary,
                recommendations: [.init(investment: snapshot, action: .buy, reason: "Strong iPhone sales.")],
                explainedTerms: [], sources: [], userInstructions: nil, portfolioValueGBP: 800,
                researchNotes: "Notes", researchDate: date
            ))
        }
        let older = record(daysAgo: 2, summary: "Old summary")
        older.summaryRating = .like
        let newer = record(daysAgo: 1, summary: "New summary")
        newer.orderedRecommendations[0].rating = .dislike
        newer.orderedRecommendations[0].comment = "  Too much tech already  "
        let untouched = record(daysAgo: 0, summary: "No feedback")
        [older, newer, untouched].forEach(context.insert)

        let feedback = AnalysisRecord.recentFeedback(in: context)
        #expect(feedback.count == 2)
        #expect(feedback[0].rating == .dislike)
        #expect(feedback[0].comment == "Too much tech already")
        #expect(feedback[1].rating == .like)
        #expect(feedback[1].comment == nil)
    }

    @Test("Feedback is quoted in the analyst prompt with what Claude said, and left out when there is none")
    func feedbackInPrompt() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [])
        let store = makePortfolio(http: http)

        _ = await store.analyseMarket(additionalInstructions: "")
        let withoutFeedback = try #require(http.claudePrompts.last)
        #expect(!withoutFeedback.contains("My feedback on your earlier analyses"))

        let feedback = try #require(AnalysisFeedback(
            date: .now,
            subject: .recommendation(name: "Apple", symbol: "AAPL", action: .buy, reason: "- **Strong** iPhone sales\n- Below target"),
            rating: .dislike, comment: "Too much tech already"
        ))
        _ = await store.analyseMarket(additionalInstructions: "", feedback: [feedback])
        let prompt = try #require(http.claudePrompts.last)
        #expect(prompt.contains("My feedback on your earlier analyses"))
        #expect(prompt.contains("I disliked your buy recommendation for Apple (AAPL) — my comment: \"Too much tech already\""))
        #expect(prompt.contains("Your reason was: \"- **Strong** iPhone sales - Below target\""))
        #expect(prompt.contains("isn't an instruction to reverse a call"))
    }

    @Test("Today's earlier research is reused without searching, and Claude is told when it was gathered")
    func reusesEarlierResearch() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [])
        let earlier = EarlierResearch(
            notes: "Apple fell 3% (Reuters, 18 Oct).", sources: [AnalysisSource(title: "Reuters", url: "https://reuters.com/a")],
            date: Date(timeIntervalSinceNow: -3 * 3600)
        )

        let analysis = try await makePortfolio(http: http).analyseMarket(additionalInstructions: "", earlierResearch: earlier).get()
        #expect(http.claudeRequests.count == 1, "Only the analysis request; no web research")
        let prompt = try #require(http.claudePrompts.last)
        #expect(prompt.contains("Apple fell 3%"))
        #expect(prompt.contains("earlier today at \(earlier.date.formatted(date: .omitted, time: .shortened)) and not refreshed"))
        #expect(analysis.researchDate == earlier.date)
        #expect(analysis.sources == earlier.sources)
    }

    @Test("Research requests use medium effort and prompt caching; the analysis request doesn't")
    func researchRequestSettings() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [])
        _ = await makePortfolio(http: http).analyseMarket(additionalInstructions: "")

        let research = try body(of: http.claudeRequests[0])
        #expect((research["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect((research["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        let analysis = try body(of: http.claudeRequests[1])
        #expect((analysis["output_config"] as? [String: Any])?["effort"] == nil)
    }

    @Test("A real event stream is rebuilt into notes and shown as live activity")
    func streamsActivity() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [])
        // Raw server-sent events for the research request: a thought, a search, its results, then cited notes
        let events: [[String: Any]] = [
            ["type": "message_start", "message": ["content": []]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Start with Apple."]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "server_tool_use", "id": "srv_1", "name": "web_search", "input": [:]]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"query\": \"Apple earnings\"}"]],
            ["type": "content_block_stop", "index": 1],
            ["type": "content_block_start", "index": 2, "content_block": ["type": "web_search_tool_result", "tool_use_id": "srv_1", "content": [
                ["type": "web_search_result", "url": "https://www.reuters.com/a", "title": "Reuters", "encrypted_content": "e"]
            ]]],
            ["type": "content_block_stop", "index": 2],
            ["type": "content_block_start", "index": 3, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 3, "delta": ["type": "text_delta", "text": "Apple beat "]],
            ["type": "content_block_stop", "index": 3],
            ["type": "content_block_start", "index": 4, "content_block": ["type": "text", "text": ""]],
            ["type": "content_block_delta", "index": 4, "delta": ["type": "citations_delta", "citation": ["type": "web_search_result_location", "url": "https://www.reuters.com/a", "title": "Reuters"]]],
            ["type": "content_block_delta", "index": 4, "delta": ["type": "text_delta", "text": "estimates."]],
            ["type": "content_block_stop", "index": 4],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"]],
            ["type": "message_stop"]
        ]
        let sse = events.map { "data: \(StubHTTPClient.jsonString($0))" }.joined(separator: "\n\n")
        http.on { request in
            StubHTTPClient.promptText(of: request).contains("Research the latest market news") ? (200, Data(sse.utf8)) : nil
        }
        let store = makePortfolio(http: http)

        let analysis = try await store.analyseMarket(additionalInstructions: "").get()
        #expect(analysis.sources == [AnalysisSource(title: "Reuters", url: "https://www.reuters.com/a")])
        let analystPrompt = try #require(http.claudePrompts.last)
        #expect(analystPrompt.contains("Apple beat estimates."))

        // Only the major steps: research (with counts) marked done, then writing; no thinking or streamed text
        let activity = store.marketAnalysisActivity
        #expect(activity.map(\.kind) == [.done, .writing])
        #expect(activity[0].text == "Researched the market")
        #expect(activity[0].detail == "1 search · 1 site")
        #expect(activity[1].text.hasPrefix("Writing"))
    }

    @Test("A stream that ends before message_stop fails")
    func truncatedStream() async {
        let http = StubHTTPClient()
        let partial = "data: {\"type\":\"message_start\",\"message\":{\"content\":[]}}\n\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"Half\"}}"
        http.on { _ in (200, Data(partial.utf8)) }
        let result = await makePortfolio(http: http).analyseMarket(additionalInstructions: "")
        #expect(throws: ClaudeFailure.during(
            step: "Researching the market", .network("The connection closed before Claude finished replying.")
        )) { try result.get() }
    }

    @Test("Failures say which step failed and why", arguments: [
        (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"web search is not enabled"}}"#,
         "Researching the market failed. Claude API error (400): web search is not enabled"),
        (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
         "Researching the market failed. Claude is overloaded right now. Try again in a few minutes. (Overloaded)")
    ])
    func failureMessages(status: Int, body: String, expected: String) async throws {
        let http = StubHTTPClient()
        http.on { _ in (status, Data(body.utf8)) }
        let result = await makePortfolio(http: http).analyseMarket(additionalInstructions: "")
        guard case .failure(let failure) = result else {
            Issue.record("Expected a failure")
            return
        }
        #expect(failure.message == expected)
    }

    @Test("An analysis reply in the wrong format names the problem")
    func malformedAnalysis() async throws {
        let http = StubHTTPClient()
        http.claude { prompt in
            if prompt.contains("Research the latest market news") { return .json("Notes.") }
            if prompt.contains("Act as an experienced financial analyst") {
                return .json(#"{"summary": "Hi", "recommendations": [{"investment": 1, "recommendation": "buy"}], "explainedTerms": []}"#)
            }
            return nil
        }
        let result = await makePortfolio(http: http).analyseMarket(additionalInstructions: "")
        guard case .failure(let failure) = result else {
            Issue.record("Expected a failure")
            return
        }
        #expect(failure.message.hasPrefix("Writing recommendations failed."))
        #expect(failure.message.contains("missing field 'reason' in recommendations[0]"))
    }

    @Test("The prompt pins down the response format, including the exact number of recommendations")
    func responseFormatInPrompt() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [])
        _ = await makePortfolio(http: http).analyseMarket(additionalInstructions: "Be brief")

        let prompt = try #require(http.claudePrompts.last)
        #expect(prompt.contains("must be a single JSON object with exactly these three fields"))
        #expect(prompt.contains("exactly 2 items, one for each numbered investment"))
        #expect(prompt.contains(#"exactly "buy", "sell" or "hold", in lowercase"#))
        // The reminder comes after the user's notes
        let notes = try #require(prompt.range(of: "Additional instructions from me: Be brief"))
        let reminder = try #require(prompt.range(of: "Reply with the JSON object only"))
        #expect(notes.upperBound <= reminder.lowerBound)

        let body = try body(of: try #require(http.claudeRequests.last))
        let schema = (body["output_config"] as? [String: Any])?["format"] as? [String: Any]
        let properties = ((schema?["schema"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        let recommendations = properties["recommendations"] as? [String: Any]
        #expect((recommendations?["description"] as? String)?.contains("1 to 2") == true)
    }

    @Test("A failed research step stops before the analysis request")
    func researchFailure() async {
        let http = StubHTTPClient()
        http.claude { _ in .refusal }
        let result = await makePortfolio(http: http).analyseMarket(additionalInstructions: "")
        #expect(throws: ClaudeFailure.during(step: "Researching the market", .refused)) { try result.get() }
        #expect(http.claudeRequests.count == 1)
    }

    @Test("Without an API key nothing is sent")
    func missingKey() async {
        let http = StubHTTPClient()
        let store = makeStore(http: http, apiKey: nil)
        let result = await store.analyseMarket(additionalInstructions: "")
        #expect(throws: ClaudeFailure.missingKey) { try result.get() }
        #expect(http.claudeRequests.isEmpty)
    }

    @Test("An analysis is saved with each recommendation and the investment's state at the time")
    func savesHistory() async throws {
        let http = StubHTTPClient()
        stubAnalysis(http, recommendations: [
            ["investment": 2, "recommendation": "sell", "reason": "Over target."],
            ["investment": 1, "recommendation": "buy", "reason": "Under target."]
        ])
        let store = makePortfolio(http: http)
        let analysis = try await store.analyseMarket(additionalInstructions: "Prefer ISA").get()

        let container = try ModelContainer(for: AnalysisRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(AnalysisRecord(analysis))
        try container.mainContext.save()

        let saved = try #require(try container.mainContext.fetch(FetchDescriptor<AnalysisRecord>()).first)
        #expect(saved.userInstructions == "Prefer ISA")
        #expect(saved.orderedRecommendations.map(\.name) == ["Tesla", "Apple"])
        let apple = saved.orderedRecommendations[1]
        #expect(apple.action == .buy)
        #expect(apple.price == 100)
        #expect(apple.valueGBP == 400)
        #expect(apple.targetPercentage == 20)
        #expect(apple.investmentID == store.investment(named: "Apple")?.id)
    }
}

/// A thread-safe call counter for stub handlers.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.withLock { value += 1; return value }
    }
}
