import Foundation

/// Plafond de contexte + réduction d'historique. Déplacé à l'identique depuis
/// OllamaService : logique 100 % pure (aucun réseau, aucun état), consommée par
/// AppViewModel (JarvisUI) qui ne doit plus passer par le type OllamaService.
/// OllamaService ne conserve que des forwarders vers ces implémentations pour
/// ne pas casser ses call-sites de tests.
public enum ContextTrimming {
    /// ~4 caractères/token, même heuristique que l'ancien prototype TS.
    public static let charsPerToken = 4
    /// Tokens réservés : génération (maxTokens) + prompt système, définitions
    /// de tools, overhead.
    public static let reservedTokens = 1500
    /// Plancher : évite un budget absurde quand numCtx est petit et maxTokens grand.
    public static let minChars = 4000
    /// Seuil au-delà duquel UN message "tool" est tronqué (passe 1 du trim) :
    /// les résultats search_web/read_url sont les principaux gonfleurs d'historique.
    public static let maxToolMessageChars = 3000

    /// Budget en caractères pour l'historique COMPLET envoyé au modèle (prompt système +
    /// conversation + résultats de tools), dérivé de num_ctx. Sans lui, Ollama tronque
    /// silencieusement le DÉBUT du contexte (dont le prompt système) sans aucune erreur.
    public static func historyCharBudget(numCtx: Int, maxTokens: Int) -> Int {
        let usableTokens = numCtx - maxTokens - reservedTokens
        return max(minChars, usableTokens * charsPerToken)
    }

    /// Réduit un historique sous maxChars en dégrandant le moins utile d'abord. Passe 1 :
    /// tronque les contenus "tool" volumineux les plus anciens (avec marqueur explicite).
    /// Passe 2 : résume d'une ligne les "tool" restants (message + tool_call_id GARDÉS
    /// pour ne pas casser l'appariement appel ↔ résultat côté backend). Passe 3 :
    /// supprime les messages les plus anciens (prompt système et queue de 2 intouchables).
    /// Puis réparation d'appariement systématique (dropOrphanedToolLinkage).
    public static func trimMessagesForContext(_ messages: [OllamaMessage], maxChars: Int) -> [OllamaMessage] {
        guard !messages.isEmpty else { return messages }
        var out = messages
        func totalChars() -> Int { out.reduce(0) { $0 + ($1.content?.count ?? 0) } }
        if totalChars() > maxChars {
            // Queue intouchable : les résultats frais du tour en cours.
            let keepTail = min(2, out.count)

            // Passe 1 — tronque les "tool" volumineux, plus anciens d'abord (hors queue).
            for i in out.indices where out[i].role == "tool" && i < out.count - keepTail {
                guard let content = out[i].content, content.count > maxToolMessageChars else { continue }
                out[i].content = String(content.prefix(maxToolMessageChars))
                    + "\n…[extrait tronqué : \(content.count) caractères d'origine, réduit à \(maxToolMessageChars) pour tenir dans la fenêtre de contexte]"
                if totalChars() <= maxChars { break }
            }

            // Passe 2 — résume d'une ligne les "tool" restants (hors queue).
            if totalChars() > maxChars {
                for i in out.indices where out[i].role == "tool" && i < out.count - keepTail {
                    guard let content = out[i].content,
                          !content.hasPrefix("[résultat d'outil ancien omis") else { continue }
                    out[i].content = "[résultat d'outil ancien omis pour tenir dans la fenêtre de contexte (\(content.count) caractères)] : \(content.prefix(200))"
                    if totalChars() <= maxChars { break }
                }
            }

            // Passe 3 — dernier recours : supprime les plus anciens, en gardant
            // le prompt système initial et au moins 10 messages au total.
            if totalChars() > maxChars {
                let minKeep = min(10, out.count)
                var idx = out.startIndex
                if out[idx].role == "system" { idx = out.index(after: idx) }
                while totalChars() > maxChars && out.count > minKeep && idx < out.count - keepTail {
                    out.remove(at: idx)
                }
            }
        }
        return dropOrphanedToolLinkage(out)
    }

    /// Réparation d'appariement appel ↔ résultat. Retire avec sa paire manquante :
    /// - un message "tool" dont l'appel parent a disparu est retiré ;
    /// - un tool_call sans message "tool" est retiré de son message assistant, et le
    ///   message lui-même est retiré s'il devient vide (ni texte ni appels restants).
    public static func dropOrphanedToolLinkage(_ messages: [OllamaMessage]) -> [OllamaMessage] {
        let calledIds = Set(messages.filter { $0.role == "assistant" }
            .flatMap { $0.toolCalls?.map { $0.id } ?? [] })
        let answeredIds = Set(messages.filter { $0.role == "tool" }.compactMap { $0.toolCallId })
        return messages.compactMap { msg in
            if msg.role == "tool" {
                guard let tcid = msg.toolCallId, calledIds.contains(tcid) else { return nil }
                return msg
            }
            var msg = msg
            if let calls = msg.toolCalls, !calls.isEmpty {
                let kept = calls.filter { answeredIds.contains($0.id) }
                if kept.isEmpty, msg.content?.isEmpty ?? true {
                    return nil
                }
                msg.toolCalls = kept.isEmpty ? nil : kept
            }
            return msg
        }
    }
}
