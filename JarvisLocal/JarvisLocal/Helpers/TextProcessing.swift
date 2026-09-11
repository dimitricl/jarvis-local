import Foundation

func stripThinking(_ text: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: [.dotMatchesLineSeparators]) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
}
