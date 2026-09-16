import SwiftUI

/// Rendu markdown-lite d'un message assistant (paragraphes, listes, titres, code).
/// Extraite de MessageBubbleView (phase 0) : `Equatable` sur le seul `text` pour
/// que SwiftUI SAUTE la réévaluation quand le texte n'a pas changé.
///
/// Pourquoi : chaque delta de streaming réévalue `ChatView.body`, donc chaque
/// `MessageBubbleView` — et `parseBlocks`/`renderInline` relançaient ~7 regex par
/// message figé et par update. Avec l'égalité sur le texte, seules les bulles
/// dont le contenu bouge (le stream en cours) sont re-rendues.
struct AssistantRichText: View, Equatable {
    let text: String

    static func == (lhs: AssistantRichText, rhs: AssistantRichText) -> Bool {
        lhs.text == rhs.text
    }

    var body: some View {
        let blocks = Self.parseBlocks(text)
        if blocks.isEmpty {
            Text(text).font(.body)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    Self.blockView(block)
                }
            }
        }
    }

    /// A semantic block of content.
    private enum ContentBlock {
        case paragraph(String)
        case list(items: [(prefix: String, content: String)], ordered: Bool)
        case heading(String, level: Int)
        case code(String)
    }

    @ViewBuilder
    private static func blockView(_ block: ContentBlock) -> some View {
        switch block {
        case .paragraph(let text):
            renderInline(text)
                .font(.body)
                .padding(.bottom, 6)

        case .heading(let text, _):
            renderInline(text)
                .font(.title3).fontWeight(.semibold)
                .padding(.bottom, 4)

        case .list(let items, _):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 4) {
                        Text(item.prefix)
                            .font(.body)
                        renderInline(item.content)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.bottom, 6)

        case .code(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(JarvisTheme.textPrimary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(JarvisTheme.panelElevated)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 6)
        }
    }

    /// Split raw text into semantic blocks separated by blank lines.
    private static func parseBlocks(_ rawText: String) -> [ContentBlock] {
        var t = rawText
        if let rx = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: [.dotMatchesLineSeparators]) {
            t = rx.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        t = t.trimmingCharacters(in: .newlines)
        // Collapse multiple blank lines into one
        while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }

        let rawBlocks = t.components(separatedBy: "\n\n")
        var result: [ContentBlock] = []
        var inCode = false
        var codeBuffer: [String] = []

        for block in rawBlocks {
            let lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard !lines.isEmpty else { continue }

            // Code fences
            if lines.first?.hasPrefix("```") == true {
                if inCode {
                    let codeBlock = codeBuffer.joined(separator: "\n")
                    if !codeBlock.isEmpty { result.append(.code(codeBlock)) }
                    codeBuffer.removeAll()
                    inCode = false
                } else {
                    inCode = true
                    let remaining = lines[0].dropFirst(3).trimmingCharacters(in: .whitespaces)
                    if !remaining.isEmpty { codeBuffer.append(String(remaining)) }
                    codeBuffer.append(contentsOf: lines.dropFirst())
                }
                continue
            }
            if inCode {
                codeBuffer.append(contentsOf: lines)
                continue
            }

            // Check if this block is a list (every line starts with -, *, or digit.)
            let bulletRegex = (try? NSRegularExpression(pattern: "^\\s*[-*]\\s+")) ?? NSRegularExpression()
            let numberRegex = (try? NSRegularExpression(pattern: "^\\s*\\d+\\.\\s+")) ?? NSRegularExpression()
            let headingRegex = (try? NSRegularExpression(pattern: "^(#{1,3})\\s+")) ?? NSRegularExpression()

            let allBullet = lines.allSatisfy { line in
                bulletRegex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
            }
            let allNumbered = lines.allSatisfy { line in
                numberRegex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
            }

            if allBullet || allNumbered {
                var items: [(String, String)] = []
                for line in lines {
                    if allBullet, let range = line.range(of: "^\\s*[-*]\\s+", options: .regularExpression) {
                        let prefix = String(repeating: " ", count: line.prefix(while: { $0 == " " }).count) + "•"
                        items.append((prefix, String(line[range.upperBound...])))
                    } else if allNumbered, let range = line.range(of: "^\\s*\\d+\\.\\s+", options: .regularExpression) {
                        let number = line[range.lowerBound..<line.index(before: range.upperBound)].trimmingCharacters(in: .whitespaces)
                        items.append((number, String(line[range.upperBound...])))
                    }
                }
                if !items.isEmpty {
                    result.append(.list(items: items, ordered: allNumbered))
                }
                continue
            }

            // Heading
            if lines.count == 1, let hMatch = headingRegex.firstMatch(in: lines[0], range: NSRange(location: 0, length: lines[0].utf16.count)) {
                let hashRange = Range(hMatch.range(at: 1), in: lines[0])!
                let level = lines[0][hashRange].count
                let contentRange = Range(hMatch.range(at: 0), in: lines[0])!
                let content = String(lines[0][contentRange.upperBound...])
                result.append(.heading(content, level: level))
                continue
            }

            // Paragraph (may span multiple lines)
            let paragraphText = lines.joined(separator: " ")
            result.append(.paragraph(paragraphText))
        }

        // Flush remaining code buffer
        if inCode && !codeBuffer.isEmpty {
            result.append(.code(codeBuffer.joined(separator: "\n")))
        }

        return result
    }

    /// Render inline markdown: **bold**, *italic*, `code`.
    private static func renderInline(_ text: String) -> Text {
        typealias Segment = (text: String, style: InlineStyle)
        enum InlineStyle {
            case normal
            case bold
            case italic
            case code
        }

        // Tokenize: process **bold**, *italic*, `code` sequentially
        var segments: [Segment] = [(text, .normal)]
        let transformations: [(pattern: String, style: InlineStyle)] = [
            ("`([^`]+)`", .code),
            ("\\*\\*([^*]+)\\*\\*", .bold),
            ("\\*([^*]+)\\*", .italic)
        ]

        for (pattern, style) in transformations {
            var newSegments: [Segment] = []
            for seg in segments {
                if seg.style != .normal {
                    newSegments.append(seg)
                    continue
                }
                guard let regex = try? NSRegularExpression(pattern: pattern) else { newSegments.append(seg); continue }
                let nsRange = NSRange(seg.text.startIndex..., in: seg.text)
                var lastEnd = seg.text.startIndex
                for match in regex.matches(in: seg.text, range: nsRange) {
                    let matchRange = Range(match.range, in: seg.text)!
                    let innerRange = Range(match.range(at: 1), in: seg.text)!

                    // Text before the match
                    if lastEnd < matchRange.lowerBound {
                        newSegments.append((String(seg.text[lastEnd..<matchRange.lowerBound]), .normal))
                    }

                    newSegments.append((String(seg.text[innerRange]), style))
                    lastEnd = matchRange.upperBound
                }
                // Remaining text after last match
                if lastEnd < seg.text.endIndex {
                    newSegments.append((String(seg.text[lastEnd...]), .normal))
                }
            }
            segments = newSegments
        }

        var result = Text("")
        for seg in segments {
            switch seg.style {
            case .normal: result = result + Text(seg.text)
            case .bold:   result = result + Text(seg.text).fontWeight(.bold)
            case .italic: result = result + Text(seg.text).italic()
            case .code:   result = result + Text(seg.text).font(.system(.body, design: .monospaced)).foregroundColor(.secondary)
            }
        }
        return result
    }
}
