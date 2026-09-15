import Foundation

public func stripThinking(_ text: String) -> String {
    // Fast path : sans bloc <think>, pas de regex sur toute la chaîne.
    // Critique en streaming où cette fonction est appelée à chaque delta sur le
    // contenu accumulé complet (coût O(n²) sinon).
    guard text.contains("<think") else { return text }
    guard let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: [.dotMatchesLineSeparators]) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
}
