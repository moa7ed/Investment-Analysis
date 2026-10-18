//
//  AnalysisFeedbackView.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import SwiftUI
import SwiftData

/// Like/dislike and comment for an analysis's market summary. Saved as the user edits; sent with later analyses.
struct SummaryFeedbackView: View {
    @Bindable var analysis: AnalysisRecord

    var body: some View {
        FeedbackControls(
            question: "Was this summary useful?",
            rating: $analysis.summaryRating,
            comment: Binding(
                get: { analysis.summaryComment ?? "" },
                set: { analysis.summaryComment = $0.isEmpty ? nil : $0 }
            )
        )
    }
}

/// Like/dislike and comment for one recommendation. Saved as the user edits; sent with later analyses.
struct RecommendationFeedbackView: View {
    @Bindable var recommendation: RecommendationRecord

    var body: some View {
        FeedbackControls(
            question: "Do you agree with this recommendation?",
            rating: $recommendation.rating,
            comment: Binding(
                get: { recommendation.comment ?? "" },
                set: { recommendation.comment = $0.isEmpty ? nil : $0 }
            )
        )
    }
}

#Preview {
    @Previewable @State var noRating: FeedbackRating?
    @Previewable @State var disliked: FeedbackRating? = .dislike
    @Previewable @State var empty = ""
    @Previewable @State var comment = "I don't want more tech exposure right now."
    VStack(spacing: 32) {
        FeedbackControls(question: "Was this summary useful?", rating: $noRating, comment: $empty)
        FeedbackControls(question: "Do you agree with this recommendation?", rating: $disliked, comment: $comment)
    }
    .padding()
}

/// Thumbs up/down (tap again to clear) and an optional comment, shown once rated or when the user asks to add one.
private struct FeedbackControls: View {
    let question: String
    @Binding var rating: FeedbackRating?
    @Binding var comment: String
    @State private var isAddingComment = false
    @FocusState private var isCommentFocused: Bool

    private var showsComment: Bool {
        rating != nil || isAddingComment || !comment.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(question)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                ratingButton(.like, systemImage: "hand.thumbsup", label: "Like")
                ratingButton(.dislike, systemImage: "hand.thumbsdown", label: "Dislike")
            }

            if showsComment {
                TextField(commentPrompt, text: $comment, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.subheadline)
                    .padding(10)
                    .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .focused($isCommentFocused)
                    .accessibilityIdentifier("feedback.comment")
                Text("Claude takes your feedback into account in future analyses.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add details") {
                    isAddingComment = true
                    isCommentFocused = true
                }
                .font(.caption)
            }
        }
    }

    private var commentPrompt: String {
        switch rating {
        case .dislike: "What was wrong or missing? (optional)"
        case .like: "What was most useful? (optional)"
        case nil: "Your feedback for Claude"
        }
    }

    private func ratingButton(_ value: FeedbackRating, systemImage: String, label: String) -> some View {
        let isSelected = rating == value
        return Button {
            withAnimation(.snappy) {
                rating = isSelected ? nil : value
            }
        } label: {
            Image(systemName: isSelected ? "\(systemImage).fill" : systemImage)
                .font(.title3)
                .foregroundStyle(isSelected ? (value == .like ? Color.green : Color.red) : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}
