//
//  MarkdownText.swift
//  IrisLivePrototype
//
//  Hermes writes its results in Markdown. SwiftUI's Text only understands
//  inline Markdown, so this renders the block structure (headings, lists,
//  quotes, code fences, rules, tables) and lets AttributedString handle the
//  inline spans (bold, italic, code, links). Small on purpose: no dependency.
//

import SwiftUI

struct MarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownBlock.inline(text))
                .font(level <= 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            Text(MarkdownBlock.inline(text))
                .font(.body).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                Text(MarkdownBlock.inline(text))
                    .font(.body).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.5)).frame(width: 3)
                Text(MarkdownBlock.inline(text))
                    .font(.body).italic().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.callout.monospaced()).padding(12)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }
}

enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case listItem(marker: String, indent: Int, text: String)
    case quote(String)
    case code(String)
    case rule

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        var table: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        func flushTable() {
            // Tables stay aligned as monospaced text; phones are too narrow for a grid.
            if !table.isEmpty { blocks.append(.code(table.joined(separator: "\n"))); table = [] }
        }

        for rawLine in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if trimmed.hasPrefix("```") { blocks.append(.code(open.joined(separator: "\n"))); code = nil }
                else { open.append(rawLine); code = open }
                continue
            }
            if trimmed.hasPrefix("```") { flushParagraph(); flushTable(); code = []; continue }
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1 {
                flushParagraph()
                let cells = trimmed.dropFirst().dropLast()
                if !cells.allSatisfy({ "-: |".contains($0) }) { table.append(String(trimmed)) }
                continue
            }
            flushTable()
            if trimmed.isEmpty { flushParagraph(); continue }
            if trimmed.count >= 3, Set(trimmed.filter { $0 != " " }).isSubset(of: ["-"]) || Set(trimmed.filter { $0 != " " }).isSubset(of: ["*"]) || Set(trimmed.filter { $0 != " " }).isSubset(of: ["_"]) {
                flushParagraph(); blocks.append(.rule); continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let rest = trimmed.dropFirst(level)
                if level <= 6, rest.hasPrefix(" ") {
                    flushParagraph()
                    blocks.append(.heading(level, rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
                continue
            }
            let indent = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if let first = trimmed.first, "-*+•".contains(first), trimmed.dropFirst().hasPrefix(" ") {
                flushParagraph()
                var text = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                var marker = "•"
                if text.hasPrefix("[ ] ") { marker = "☐"; text = String(text.dropFirst(4)) }
                else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text = String(text.dropFirst(4)) }
                blocks.append(.listItem(marker: marker, indent: min(indent, 4), text: text))
                continue
            }
            let digits = trimmed.prefix(while: { $0.isNumber })
            if !digits.isEmpty, digits.count <= 3 {
                let after = trimmed.dropFirst(digits.count)
                if (after.hasPrefix(". ") || after.hasPrefix(") ")) {
                    flushParagraph()
                    blocks.append(.listItem(marker: "\(digits).", indent: min(indent, 4),
                                            text: after.dropFirst(2).trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            paragraph.append(trimmed)
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flushParagraph(); flushTable()
        return blocks
    }
}
