import Foundation

extension String {
    var escapingForAppleScript: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    var strippedHTML: String {
        self.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func htmlToText(maxLength: Int) -> String {
        var text = self
        text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<br\\s*/>", with: "\n", options: [.regularExpression, .caseInsensitive])
        let blockTags = try! NSRegularExpression(pattern: "</(p|h[1-6]|li|div|tr|blockquote|section|article|td|th)>", options: [.caseInsensitive])
        text = blockTags.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (k, v) in entities { text = text.replacingOccurrences(of: k, with: v) }
        let numericEntity = try! NSRegularExpression(pattern: "&#(\\d+);", options: [])
        let nsText = NSMutableString(string: text)
        var offset = 0
        let matches = numericEntity.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)
            if let codeRange = Range(match.range(at: 1), in: text),
               let code = Int(text[codeRange]),
               let scalar = UnicodeScalar(code) {
                nsText.replaceCharacters(in: fullRange, with: String(scalar))
                offset += String(scalar).count - match.range.length
            }
        }
        text = nsText as String
        text = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 2 }
            .prefix(80)
            .joined(separator: "\n")
        return String(text.prefix(maxLength))
    }
}
