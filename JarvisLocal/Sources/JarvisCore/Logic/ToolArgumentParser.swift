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

    /// Récupère les pseudo-appels texte (`search_web(query="…")`, un par ligne)
    /// qu'un modèle écrit AU LIEU d'émettre un tool_call : l'appelant les
    /// exécute comme de vrais appels plutôt que de relancer le modèle (cas réel
    /// récurrent). Seuls les noms présents dans `knownTools` sont retenus
    /// (jamais d'exécution sur identifiant inventé) ; les outils sensibles
    /// passent toujours par la confirmation normale en aval.
    public static func extractPseudoCalls(from text: String, knownTools: Set<String>) -> [ToolCall] {
        var out: [ToolCall] = []
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("• ") { line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("- ") { line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            guard let call = parsePseudoCall(line: line, knownTools: knownTools)
                ?? parseBareCall(line: line, knownTools: knownTools) else { continue }
            out.append(call)
        }
        return out
    }

    private static func parsePseudoCall(line: String, knownTools: Set<String>) -> ToolCall? {
        guard let open = line.firstIndex(of: "("), line.hasSuffix(")"), open != line.startIndex else { return nil }
        let name = String(line[..<open]).trimmingCharacters(in: .whitespaces)
        guard name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil,
              knownTools.contains(name) else { return nil }
        let inner = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return makeCall(name: name, args: [:])
        } else if let json = parse(trimmed) {
            return makeCall(name: name, args: json)
        } else if let kv = parseKeyValueArgs(trimmed), !kv.isEmpty {
            return makeCall(name: name, args: kv)
        } else {
            return nil
        }
    }

    /// Forme sans parenthèses (`get_weather city: Paris`, enseignée par les
    /// exemples du prompt) : `nom k: v, k2 = v2`. Exige des arguments non
    /// vides — un nom seul en prose n'est jamais exécuté.
    private static func parseBareCall(line: String, knownTools: Set<String>) -> ToolCall? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let name = String(line[..<space])
        guard name.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil,
              knownTools.contains(name) else { return nil }
        let rest = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, let args = parseKeyValueArgs(rest), !args.isEmpty else { return nil }
        return makeCall(name: name, args: args)
    }

    private static func makeCall(name: String, args: [String: Any]) -> ToolCall {
        let jsonString: String
        if let data = try? JSONSerialization.data(withJSONObject: args),
           let str = String(data: data, encoding: .utf8) {
            jsonString = str
        } else {
            jsonString = "{}"
        }
        return ToolCall(id: UUID().uuidString, type: "function",
                        function: ToolCallFunction(name: name, arguments: jsonString))
    }

    /// Parse `k="v", k2='v2', n=3` (ou `k: v` sans parenthèses) en dictionnaire.
    /// Nil si inexploitable (sans séparateur, clé invalide, guillemet non
    /// fermé). Séparateur : le premier `=`, sinon le premier `:`.
    private static func parseKeyValueArgs(_ s: String) -> [String: Any]? {
        var parts: [String] = []
        var cur = ""
        var quote: Character?
        for ch in s {
            if let q = quote {
                cur.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                cur.append(ch)
            } else if ch == "," {
                parts.append(cur); cur = ""
            } else {
                cur.append(ch)
            }
        }
        if quote != nil { return nil }
        parts.append(cur)
        var out: [String: Any] = [:]
        for part in parts {
            let sep: String.Index?
            if let eq = part.firstIndex(of: "=") { sep = eq }
            else if let col = part.firstIndex(of: ":") { sep = col }
            else { return nil }
            guard let split = sep else { return nil }
            let key = String(part[..<split]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return nil }
            var value = String(part[part.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
                || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2)
                || (value.hasPrefix("“") && value.hasSuffix("”") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
                out[key] = value
            } else if let i = Int(value) {
                out[key] = i
            } else if let d = Double(value) {
                out[key] = d
            } else if value == "true" {
                out[key] = true
            } else if value == "false" {
                out[key] = false
            } else {
                out[key] = value
            }
        }
        return out
    }
}
