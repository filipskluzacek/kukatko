import SwiftUI

/// Small block-level Markdown renderer (headings, lists, code, quotes) on top of SwiftUI's inline Markdown.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for b: Block) -> some View {
        switch b {
        case .heading(let level, let s):
            inline(s)
                .font(.system(size: level <= 2 ? 15 : 13.5, weight: .semibold))
                .padding(.top, 4)
        case .paragraph(let s):
            inline(s).font(.system(size: 13.5)).lineSpacing(2.5)
        case .bullet(let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•").font(.system(size: 13.5)).foregroundStyle(.secondary)
                inline(s).font(.system(size: 13.5)).lineSpacing(2.5)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").font(.system(size: 13.5).monospacedDigit()).foregroundStyle(.secondary)
                inline(s).font(.system(size: 13.5)).lineSpacing(2.5)
            }
        case .quote(let s):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                inline(s).font(.system(size: 13.5)).foregroundStyle(.secondary)
            }
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s).font(.system(size: 12, design: .monospaced)).padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, Int)
        case numbered(Int, String)
        case quote(String)
        case code(String)
        case rule
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var code: [String]? = nil

        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: " "))); para = [] }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { blocks.append(.code(c.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { flush(); continue }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let rest = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6 && !rest.isEmpty { flush(); blocks.append(.heading(level, rest)); continue }
            }
            if line == "---" || line == "***" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                let indent = raw.prefix(while: { $0 == " " }).count / 2
                blocks.append(.bullet(line.dropFirst(2).trimmingCharacters(in: .whitespaces), min(indent, 3)))
                continue
            }
            if let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]), line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.numbered(n, line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
                continue
            }
            if line.hasPrefix("> ") { flush(); blocks.append(.quote(String(line.dropFirst(2)))); continue }
            para.append(line)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
