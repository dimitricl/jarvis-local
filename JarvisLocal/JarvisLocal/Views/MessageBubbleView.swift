import SwiftUI

struct MessageBubbleView: View {
    let text: String
    let role: String
    var isStreaming = false
    let timestamp: String?

    init(message: Message) {
        self.text = message.content
        self.role = message.role
        self.isStreaming = false
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        self.timestamp = f.string(from: message.createdAt)
    }

    init(text: String, role: String, isStreaming: Bool = false) {
        self.text = text
        self.role = role
        self.isStreaming = isStreaming
        self.timestamp = nil
    }

    var body: some View {
        HStack(spacing: 0) {
            if role == "user" { Spacer(minLength: 60) }
            if role == "user" {
                userBubble
            } else {
                assistantBubble
            }
            if role == "assistant" { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 8)
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(text)
                .font(.body)
                .padding(10)
                .background(Color.blue.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .foregroundColor(.primary)
            if let ts = timestamp {
                Text(ts).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 2) {
            richTextContent
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if let ts = timestamp {
                HStack(spacing: 4) {
                    Text(ts).font(.caption2).foregroundStyle(.tertiary)
                    Button(action: copyText) {
                        Image(systemName: "doc.on.doc").font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
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
    private var richTextContent: some View {
        let blocks = parseBlocks(text)
        if blocks.isEmpty {
            Text(text).font(.body)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock) -> some View {
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
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 6)
        }
    }

    /// Split raw text into semantic blocks separated by blank lines.
    private func parseBlocks(_ raw: String) -> [ContentBlock] {
        var t = raw
        t = t.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
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
            let bulletRegex = try! NSRegularExpression(pattern: "^\\s*[-*]\\s+")
            let numberRegex = try! NSRegularExpression(pattern: "^\\s*\\d+\\.\\s+")
            let headingRegex = try! NSRegularExpression(pattern: "^(#{1,3})\\s+")

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
    private func renderInline(_ text: String) -> Text {
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
            ("\\*([^*]+)\\*", .italic),
        ]

        for (pattern, style) in transformations {
            var newSegments: [Segment] = []
            for seg in segments {
                if seg.style != .normal {
                    newSegments.append(seg)
                    continue
                }
                let regex = try! NSRegularExpression(pattern: pattern)
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

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
