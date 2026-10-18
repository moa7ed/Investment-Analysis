//
//  RecommendationHistory.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import Foundation
import SwiftData

/// One market analysis run, kept so recommendations can be reviewed against later performance.
@Model
final class AnalysisRecord {
    var date: Date
    var summary: String
    /// The user's notes sent with this run, if any
    var userInstructions: String?
    var explainedTerms: [String]
    var sources: [AnalysisSource]
    var model: String
    /// Whole-portfolio value (including cash) when the analysis ran
    var portfolioValueGBP: Double
    @Relationship(deleteRule: .cascade, inverse: \RecommendationRecord.analysis)
    var recommendations: [RecommendationRecord]
    /// The user's like/dislike of the summary ("like" / "dislike"), sent with later analyses
    var summaryRatingRawValue: String?
    var summaryComment: String?

    init(
        date: Date,
        summary: String,
        userInstructions: String?,
        explainedTerms: [String],
        sources: [AnalysisSource],
        model: String,
        portfolioValueGBP: Double,
        recommendations: [RecommendationRecord]
    ) {
        self.date = date
        self.summary = summary
        self.userInstructions = userInstructions
        self.explainedTerms = explainedTerms
        self.sources = sources
        self.model = model
        self.portfolioValueGBP = portfolioValueGBP
        self.recommendations = recommendations
    }

    convenience init(_ analysis: MarketAnalysis) {
        self.init(
            date: analysis.date,
            summary: analysis.summary,
            userInstructions: analysis.userInstructions,
            explainedTerms: analysis.explainedTerms,
            sources: analysis.sources,
            model: ClaudeAPI.model,
            portfolioValueGBP: analysis.portfolioValueGBP,
            recommendations: analysis.recommendations.enumerated().map { RecommendationRecord($1, date: analysis.date, order: $0) }
        )
    }

    /// Recommendations in the order Claude gave them (SwiftData doesn't keep relationship order).
    var orderedRecommendations: [RecommendationRecord] {
        recommendations.sorted { $0.order < $1.order }
    }

    var summaryRating: FeedbackRating? {
        get { summaryRatingRawValue.flatMap(FeedbackRating.init) }
        set { summaryRatingRawValue = newValue?.rawValue }
    }

    /// Feedback the user left on the latest analyses, newest first, for Claude to take into account next time.
    static func recentFeedback(in context: ModelContext, analyses: Int = 20, limit: Int = 30) -> [AnalysisFeedback] {
        var descriptor = FetchDescriptor<AnalysisRecord>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = analyses
        let records = (try? context.fetch(descriptor)) ?? []

        let feedback = records.flatMap { record -> [AnalysisFeedback] in
            var items: [AnalysisFeedback] = []
            if let summary = AnalysisFeedback(
                date: record.date, subject: .summary(record.summary),
                rating: record.summaryRating, comment: record.summaryComment
            ) {
                items.append(summary)
            }
            for recommendation in record.orderedRecommendations {
                if let item = AnalysisFeedback(
                    date: record.date,
                    subject: .recommendation(
                        name: recommendation.name, symbol: recommendation.symbol,
                        action: recommendation.action, reason: recommendation.reason
                    ),
                    rating: recommendation.rating, comment: recommendation.comment
                ) {
                    items.append(item)
                }
            }
            return items
        }
        return Array(feedback.prefix(limit))
    }
}

enum FeedbackRating: String {
    case like, dislike
}

/// One piece of user feedback on an earlier analysis, as sent to Claude.
struct AnalysisFeedback {
    enum Subject {
        /// The market summary, with what it said
        case summary(String)
        /// A recommendation, with what was recommended and why
        case recommendation(name: String, symbol: String?, action: RecommendationAction, reason: String)
    }

    let date: Date
    let subject: Subject
    let rating: FeedbackRating?
    /// Trimmed; nil if the user didn't write anything
    let comment: String?

    /// Nil when there's no rating and no comment, so empty feedback is never sent.
    init?(date: Date, subject: Subject, rating: FeedbackRating?, comment: String?) {
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = trimmed?.isEmpty == false ? trimmed : nil
        guard rating != nil || comment != nil else { return nil }
        self.date = date
        self.subject = subject
        self.rating = rating
        self.comment = comment
    }
}

/// Claude's call on one investment, with the investment's state at the time.
@Model
final class RecommendationRecord {
    /// The investment's stable ID, so history follows it through renames (kept if it's later deleted)
    var investmentID: UUID
    var name: String
    var symbol: String?
    var category: String
    /// Stored as the raw value ("buy", "sell", "hold") so it can be used in queries
    var actionRawValue: String
    var reason: String
    var date: Date
    /// Price per unit in `currencyCode` when recommended (nil if there was no price)
    var price: Double?
    var currencyCode: String
    var valueGBP: Double
    var portfolioPercentage: Double
    var targetPercentage: Double
    /// Position in Claude's answer
    var order: Int
    var analysis: AnalysisRecord?
    /// The user's like/dislike ("like" / "dislike"), sent with later analyses
    var ratingRawValue: String?
    var comment: String?

    var action: RecommendationAction {
        RecommendationAction(rawValue: actionRawValue) ?? .hold
    }

    var rating: FeedbackRating? {
        get { ratingRawValue.flatMap(FeedbackRating.init) }
        set { ratingRawValue = newValue?.rawValue }
    }

    init(_ recommendation: MarketAnalysis.Recommendation, date: Date, order: Int) {
        let investment = recommendation.investment
        self.investmentID = investment.id
        self.name = investment.name
        self.symbol = investment.symbol
        self.category = investment.category
        self.actionRawValue = recommendation.action.rawValue
        self.reason = recommendation.reason
        self.date = date
        self.price = investment.price
        self.currencyCode = investment.currencyCode
        self.valueGBP = investment.valueGBP
        self.portfolioPercentage = investment.portfolioPercentage
        self.targetPercentage = investment.targetPercentage
        self.order = order
    }
}
