import Foundation

/// Classification pure du Health Check de démarrage (aucun réseau ici).
/// Entrées déjà collectées ailleurs : verdict de la sonde tool-calling
/// (`OllamaService.probeToolCalling`), flags Réglages, présence MCP en ligne.
/// Règles :
/// - `supported` → rien ; `unsupported` → `modelNoTools` (avec le conseil) ;
/// - `unknown` → `ollamaUnreachable` UNIQUEMENT si le message évoque le réseau
///   (injoignable, délai, URL invalide, annulée) — une sonde indéterminée pour
///   une autre raison n'accuse pas le serveur ;
/// - hôte Ollama non local → `ollamaRemote` (avertissement vie privée) ;
/// - MCP activé mais rien en ligne → `mcpOffline` (piste : lancer iMCP / réessayer).
/// Fonction pure — testée sans réseau ni Ollama.
public enum HealthCheck {
    public static func issues(
        toolSupport: ToolCallingSupport,
        mcpEnabled: Bool,
        mcpOnline: Bool?,
        ollamaHostIsLocal: Bool
    ) -> [HealthIssue] {
        var out: [HealthIssue] = []
        switch toolSupport {
        case .supported:
            break
        case .unsupported(let reason):
            out.append(HealthIssue(kind: .modelNoTools, message: reason))
        case .unknown(let reason):
            if isNetworkish(reason) {
                out.append(HealthIssue(
                    kind: .ollamaUnreachable,
                    message: "Ollama semble injoignable (\(reason)) Vérifie qu'il est lancé (`ollama serve`)."
                ))
            }
        }
        if !ollamaHostIsLocal {
            out.append(HealthIssue(
                kind: .ollamaRemote,
                message: "URL Ollama distante : l'historique et les faits sont envoyés hors de ce Mac (souvent en clair)."
            ))
        }
        if mcpEnabled, mcpOnline == false {
            out.append(HealthIssue(
                kind: .mcpOffline,
                message: "MCP activé mais aucun serveur en ligne : lance iMCP (ou renseigne son chemin dans Réglages > MCP) puis réessaie."
            ))
        }
        return out
    }

    /// Heuristique réseau sur le message de sonde : on ne signale injoignable
    /// que sur des indices explicites, jamais sur un doute générique.
    static func isNetworkish(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return r.contains("injoignable") || r.contains("délai") || r.contains("delai")
            || r.contains("timeout") || r.contains("invalide") || r.contains("annulée")
            || r.contains("annulee") || r.contains("url")
    }
}
