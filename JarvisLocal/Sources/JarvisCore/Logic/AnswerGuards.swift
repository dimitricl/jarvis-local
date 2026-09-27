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

    /// Détecte quand le modèle recopie la liste des outils du prompt système
    /// (« • search_web → … (requis: query) ») ou décrit un appel en texte
    /// (`search_web(query="…")`, `get_weather city: Paris`) au lieu d'émettre
    /// un tool_call. `knownTools` affine la forme nue (ligne commençant par un
    /// vrai nom d'outil). Fonction pure.
    public static func isToolListEcho(_ finalText: String, knownTools: Set<String> = []) -> Bool {
        let lines = finalText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let echoLines = lines.filter { $0.contains("→") && $0.contains("(requis:") }
        // Pseudo-appel texte (`search_web(query="…")`) : la récupération
        // l'exécute d'abord ; ici, filet pour l'inconnu ou l'inparsable.
        let callLines = lines.filter {
            $0.range(of: "^[a-z][a-z0-9_]*\\([^)]*=.*\\)$", options: .regularExpression) != nil
        }
        // Forme nue (`get_weather city: Paris`) : ligne commençant par un nom
        // d'outil connu suivi d'arguments `k: v` / `k = v`.
        let bareLines = lines.filter { line in
            guard let space = line.firstIndex(of: " ") else { return false }
            let name = String(line[..<space])
            guard knownTools.contains(name) else { return false }
            let rest = String(line[line.index(after: space)...])
            return rest.contains(":") || rest.contains("=")
        }
        let echoCount = echoLines.count + callLines.count + bareLines.count
        if echoCount >= 2 { return true }
        if echoCount == 1 && finalText.count < 600 { return true }
        return false
    }

    public static func shouldNotifyTurnFinished(startedAt: Date, isActive: Bool, now: Date = Date(), threshold: TimeInterval = 8) -> Bool {
        !isActive && now.timeIntervalSince(startedAt) > threshold
    }
}
