import Foundation

/// Parse des arguments d'un tool call avec réparations des erreurs courantes des petits
/// modèles (virgule traînante, clôture markdown, guillemets typographiques, double
/// encodage). Déplacé à l'identique depuis AppViewModel : fonction pure, consommée
/// par le ViewModel (qui garde un forwarder `parseToolArguments`) et, après
/// découpage, directement par les tests UI.
public enum ToolArgumentParser {
    public static func parse(_ raw: String) -> [String: Any]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return [:] }

        // Clôtures markdown ```json ... ``` que certains modèles ajoutent
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "^```[a-zA-Z]*\\s*", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\s*```\\s*$", with: "", options: .regularExpression)
        }
        // Guillemets typographiques (souvent introduits par le français)
        s = s.replacingOccurrences(of: "[“”„]", with: "\"")
        s = s.replacingOccurrences(of: "’", with: "'")

        func parse(_ str: String) -> [String: Any]? {
            guard let data = str.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }

        func noTrailingCommas(_ str: String) -> String {
            str.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        }

        guard var obj = parse(s) ?? parse(noTrailingCommas(s)) else { return nil }

        // Certains modèles double-encodent les arguments : {"app": "{\"app\": \"X\"}"}.
        // Si une valeur est elle-même un objet JSON, on fusionne ses clés (sans écraser).
        var merged: [String: Any] = [:]
        for (_, value) in obj {
            if let str = value as? String, str.hasPrefix("{"), let inner = parse(str) {
                for (k, v) in inner { merged[k] = v }
            }
        }
        for (k, v) in merged where obj[k] == nil {
            obj[k] = v
        }
        return obj
    }
}
