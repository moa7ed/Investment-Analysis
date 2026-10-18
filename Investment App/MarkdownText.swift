//
//  MarkdownText.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import SwiftUI

/// Renders the small Markdown subset Claude is asked for: "#" headings, "- " / "1. " lists, and paragraphs,
/// with **bold**, *italics* and [links] inside them. SwiftUI's `Text` alone only handles the inline part.
/// Plain text (e.g. analyses saved before Markdown was requested) renders as ordinary paragraphs.
struct MarkdownText: View {
    let markdown: String

    init(_ markdown: String) {
        self.markdown = markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(Self.inline(text))
                .font(.headline)
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let text, let level):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(Self.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 16)
        }
    }

    /// Bold, italics, code spans and links; falls back to the raw text if it isn't valid Markdown.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

#Preview {
    ScrollView {
        MarkdownText("""
        Markets were **mixed** this week as the US central bank (its equivalent of the Bank of England) held rates.

        ### Biggest mover
        **Apple** rose 6% after iPhone sales beat forecasts ([Reuters](https://reuters.com)).

        ### Worth considering
        - **UK gilts** (government bonds) — yields look *attractive*
        - Healthcare, which tends to hold up when growth slows
          - especially large drug makers
        1. First numbered point
        2. Second numbered point
        """)
        .padding()
    }
}

/// One block-level element of the Markdown.
enum MarkdownBlock: Equatable {
    case heading(String)
    case paragraph(String)
    /// `marker` is "•" for bullets or e.g. "2." for numbered items; `level` is the nesting depth
    case listItem(marker: String, text: String, level: Int)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // Consecutive plain lines form one paragraph
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count
            let level = min(indent / 2, 3)

            if line.isEmpty {
                flushParagraph()
            } else if let heading = headingText(line) {
                flushParagraph()
                blocks.append(.heading(heading))
            } else if let bullet = ["- ", "* ", "• "].first(where: line.hasPrefix) {
                flushParagraph()
                blocks.append(.listItem(marker: "•", text: String(line.dropFirst(bullet.count)), level: level))
            } else if let (number, text) = numberedItem(line) {
                flushParagraph()
                blocks.append(.listItem(marker: "\(number).", text: text, level: level))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    /// "### Title" → "Title" (any level from # to ######).
    private static func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
    }

    /// "2. Text" → (2, "Text").
    private static func numberedItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }
}
