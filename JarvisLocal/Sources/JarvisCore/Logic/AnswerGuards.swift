import Foundation

/// Gardes de réponse du tour de conversation, extraites à l'identique
/// depuis AppViewModel (fonctions pures). Le ViewModel garde des
/// forwarders pour les call-sites existants et les tests.
public enum AnswerGuards {
    public static func shouldContinueAfterTruncation(truncated: Bool, used: Int, max: Int = 2) -> Bool {
        truncated && used < max
    }

    public static func shouldRetryVacuousAnswer(finalText: String, hasWebSources: Bool, used: Int, max: Int = 1, minChars: Int = 300) -> Bool {
        guard hasWebSources, used < max else { return false }
        let t = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < minChars && !t.contains("http") { return true }
        if isSourcesOnlyAnswer(finalText) { return true }
        return false
    }

    public static func isRefusalAnswer(_ finalText: String) -> Bool {
        let t = finalText.lowercased()
        let markers = [
            "je ne peux pas", "je ne suis pas en mesure", "je ne suis pas capable",
            "je n'ai pas la capacité", "je n'ai pas les capacités",
            "dépasse mes capacités", "dépassent mes capacités",
            "m'est impossible", "il m'est impossible", "hors de ma portée"
        ]
        return markers.contains(where: t.contains)
    }

    public static func isSourcesOnlyAnswer(_ finalText: String, minChars: Int = 100) -> Bool {
        let remainder = finalText.components(separatedBy: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t != "Sources :" else { return nil }
            if t.hasPrefix("- http") { return nil }
            let noURLs = t.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return noURLs.isEmpty ? nil : noURLs
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.count < minChars
    }

    public static func shouldNotifyTurnFinished(startedAt: Date, isActive: Bool, now: Date = Date(), threshold: TimeInterval = 8) -> Bool {
        !isActive && now.timeIntervalSince(startedAt) > threshold
    }
}
