import Foundation

/// Mise en forme des résultats web avec Source URL obligatoire (auditabilité :
/// avant, le modèle ne POUVAIT pas citer ses sources, cf. cas iPhone 18 Pro).
/// Déplacée à l'identique depuis WebSearchService : fonction pure.
/// WebSearchService et ToolService ne conservent que des forwarders pour
/// ne pas casser leurs call-sites de tests.
public enum SearchResultFormatter {
    public static func format(_ results: [(title: String, href: String, text: String?)]) -> String {
        var out = ""
        for r in results {
            out += "--- \(r.title) ---\nSource : \(r.href)\n"
            if let t = r.text { out += "Contenu : \(t)\n" }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
