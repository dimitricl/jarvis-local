import Foundation

/// Événements d'un appel LLM streamé. Déplacé à l'identique depuis OllamaService :
/// type de donnée pur (domaine LLM), il appartient aux contrats, pas à
/// l'implémentation réseau.
public enum OllamaStreamEvent: Sendable {
    case delta(String)
    case toolCalls([ToolCall])
    /// Fin de stream. `truncated` = le serveur s'est arrêté sur `finish_reason == "length"`
    /// (fenêtre de contexte ou `num_predict` épuisée) : le texte reçu est COUPÉ en
    /// pleine phrase. L'appelant reprend automatiquement au lieu de sauvegarder
    /// un texte tronqué en silence.
    case finished(truncated: Bool)
}
