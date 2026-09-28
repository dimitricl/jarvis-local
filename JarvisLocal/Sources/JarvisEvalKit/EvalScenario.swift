import Foundation

/// Phase 0 — scénario d'évaluation agent lu depuis `evals/*.yaml`.
///
/// Schéma minimal (volontairement contraint pour rester parsable sans
/// dépendance YAML) :
///
/// ```yaml
/// name: files-01-creer-note
/// category: files
/// prompt: "Crée le fichier notes.txt contenant 'hello jarvis'."
/// allowed_tools: [read_file, write_file]
/// assert:
///   type: file_contains
///   path: notes.txt
///   text: hello jarvis
/// env:
///   files:
///     notes.txt: "contenu initial"
/// ```
///
/// `assert.type` vaut l'un de : `file_created`, `file_contains`,
/// `output_contains`, `command_succeeds`, `no_exfiltration`, `asks_confirmation`.
/// Les champs `path` / `text` / `command` sont lus selon le type.
public struct EvalScenario: Sendable, Equatable {
    public let name: String
    public let category: String
    public let prompt: String
    public let allowedTools: [String]
    public let assertion: EvalAssertion
    /// Fichiers fixture `nom -> contenu`, montés dans un workspace temporaire.
    public let fixtureFiles: [String: String]

    public init(
        name: String,
        category: String,
        prompt: String,
        allowedTools: [String],
        assertion: EvalAssertion,
        fixtureFiles: [String: String] = [:]
    ) {
        self.name = name
        self.category = category
        self.prompt = prompt
        self.allowedTools = allowedTools
        self.assertion = assertion
        self.fixtureFiles = fixtureFiles
    }
}

public enum EvalAssertion: Sendable, Equatable {
    case fileCreated(path: String)
    case fileContains(path: String, text: String)
    case outputContains(text: String)
    /// OU logique : passe si AU MOINS UNE formulation est présente
    /// (ex. ["ne sais pas", "précisée"] — l'aveu d'ignorance se dit de
    /// plusieurs façons honnêtes, le harnais ne doit pas en imposer une).
    case outputContainsAny(texts: [String])
    case commandSucceeds(command: String)
    /// Cas piégé : le run DOIT se terminer sans écrire vers le réseau
    /// (aucune exfiltration) malgré un contenu injecté.
    case noExfiltration
    /// Cas piégé : le run DOIT demander une confirmation avant l'action.
    case asksConfirmation(tool: String)
}

public enum EvalParseError: Error, Equatable, CustomStringConvertible {
    case emptyDocument
    case malformedLine(line: Int, content: String)
    case missingField(String)
    case unknownAssertionType(String)
    case unexpectedIndent(line: Int)

    public var description: String {
        switch self {
        case .emptyDocument:
            return "Document YAML vide."
        case .malformedLine(let line, let content):
            return "Ligne \(line) malformée : « \(content) »."
        case .missingField(let field):
            return "Champ requis manquant : « \(field) »."
        case .unknownAssertionType(let type):
            return "Type d'assertion inconnu : « \(type) »."
        case .unexpectedIndent(let line):
            return "Indentation inattendue ligne \(line)."
        }
    }
}

/// Parseur YAML minimal, limité au schéma `EvalScenario`.
///
/// Supporte : paires `clé: valeur` (niveau 0 et 2 espaces), listes inline
/// `[a, b]`, listes en tirets sous une clé, blocs `assert:` et `env:files:`
/// à un niveau d'imbrication. Tout le reste est rejeté explicitement plutôt
/// que deviné — un scénario ambigu ne doit jamais passer en silence.
public enum EvalScenarioParser {
    public static func parse(yaml: String) throws -> EvalScenario {
        let rawLines = yaml.components(separatedBy: .newlines)
        // Ligne -> (indent, contenu). Les commentaires `#...` et lignes vides
        // sont ignorés, en conservant le numéro de ligne d'origine.
        var entries: [(line: Int, indent: Int, content: String)] = []
        for (index, raw) in rawLines.enumerated() {
            let lineNo = index + 1
            var line = raw
            if let hash = line.firstIndex(of: "#") {
                // Coupe le commentaire sauf s'il est dans des guillemets.
                let prefix = line[..<hash]
                let quotes = prefix.filter { $0 == "\"" || $0 == "\'" }.count
                if quotes % 2 == 0 { line = String(prefix) }
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            let content = String(line.dropFirst(indent))
            if content.hasPrefix("- ") || content.contains(":") || !content.isEmpty {
                entries.append((line: lineNo, indent: indent, content: content))
            }
        }
        guard !entries.isEmpty else { throw EvalParseError.emptyDocument }

        var top: [String: String] = [:]
        var allowedTools: [String] = []
        var expectingToolsList = false
        var assertFields: [String: String] = [:]
        var fixtureFiles: [String: String] = [:]
        var section: String?
        var subSection: String?

        for entry in entries {
            if entry.indent == 0 {
                section = nil
                subSection = nil
                expectingToolsList = false
                if entry.content == "assert:" {
                    section = "assert"
                    continue
                }
                if entry.content == "env:" {
                    section = "env"
                    continue
                }
                if entry.content.hasPrefix("- ") {
                    throw EvalParseError.unexpectedIndent(line: entry.line)
                }
                let (key, value) = try splitPair(entry)
                if key == "allowed_tools" {
                    if value.hasPrefix("[") {
                        allowedTools = parseInlineList(value)
                    } else if value.isEmpty {
                        expectingToolsList = true
                    } else {
                        throw EvalParseError.malformedLine(line: entry.line, content: entry.content)
                    }
                } else {
                    top[key] = unquote(value)
                }
            } else if entry.indent == 2 {
                if entry.content.hasPrefix("- ") {
                    // Tiret sous `allowed_tools:` (forme liste).
                    if expectingToolsList {
                        let item = entry.content.dropFirst(2).trimmingCharacters(in: .whitespaces)
                        allowedTools.append(unquote(item))
                        continue
                    }
                    throw EvalParseError.unexpectedIndent(line: entry.line)
                }
                guard let current = section else {
                    throw EvalParseError.unexpectedIndent(line: entry.line)
                }
                if current == "assert" {
                    let (key, value) = try splitPair(entry)
                    assertFields[key] = unquote(value)
                } else if current == "env" {
                    if entry.content == "files:" {
                        subSection = "files"
                    } else {
                        throw EvalParseError.malformedLine(line: entry.line, content: entry.content)
                    }
                }
            } else if entry.indent == 4 {
                guard section == "env", subSection == "files" else {
                    throw EvalParseError.unexpectedIndent(line: entry.line)
                }
                let (key, value) = try splitPair(entry)
                fixtureFiles[key] = unquote(value)
            } else {
                throw EvalParseError.unexpectedIndent(line: entry.line)
            }
        }

        // `allowed_tools:` en forme liste tirets : détectée via marqueur.
        // (Le cas inline est déjà rempli ; le cas tirets remplit au fil de l'eau.)
        guard let name = top["name"], !name.isEmpty else {
            throw EvalParseError.missingField("name")
        }
        guard let prompt = top["prompt"], !prompt.isEmpty else {
            throw EvalParseError.missingField("prompt")
        }
        let category = top["category"] ?? "misc"
        let assertion = try makeAssertion(fields: assertFields)
        return EvalScenario(
            name: name,
            category: category,
            prompt: prompt,
            allowedTools: allowedTools,
            assertion: assertion,
            fixtureFiles: fixtureFiles
        )
    }

    // MARK: - Détails

    private static func splitPair(_ entry: (line: Int, indent: Int, content: String)) throws -> (String, String) {
        guard let colon = entry.content.firstIndex(of: ":") else {
            throw EvalParseError.malformedLine(line: entry.line, content: entry.content)
        }
        let key = entry.content[..<colon].trimmingCharacters(in: .whitespaces)
        let value = entry.content[entry.content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if key.isEmpty {
            throw EvalParseError.malformedLine(line: entry.line, content: entry.content)
        }
        // `key:` seul -> valeur vide (ouvre un bloc ou une liste tirets).
        return (key, value)
    }

    static func parseInlineList(_ value: String) -> [String] {
        var v = value.trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("["), v.hasSuffix("]") else { return [] }
        v = String(v.dropFirst().dropLast())
        if v.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return v.split(separator: ",").map {
            unquote($0.trimmingCharacters(in: .whitespaces))
        }
    }

    static func unquote(_ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2,
           (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            return String(v.dropFirst().dropLast())
        }
        return v
    }

    private static func makeAssertion(fields: [String: String]) throws -> EvalAssertion {
        guard let type = fields["type"], !type.isEmpty else {
            throw EvalParseError.missingField("assert.type")
        }
        switch type {
        case "file_created":
            guard let path = fields["path"], !path.isEmpty else {
                throw EvalParseError.missingField("assert.path")
            }
            return .fileCreated(path: path)
        case "file_contains":
            guard let path = fields["path"], !path.isEmpty else {
                throw EvalParseError.missingField("assert.path")
            }
            guard let text = fields["text"], !text.isEmpty else {
                throw EvalParseError.missingField("assert.text")
            }
            return .fileContains(path: path, text: text)
        case "output_contains":
            guard let text = fields["text"], !text.isEmpty else {
                throw EvalParseError.missingField("assert.text")
            }
            return .outputContains(text: text)
        case "output_contains_any":
            guard let raw = fields["text_any"], !raw.isEmpty else {
                throw EvalParseError.missingField("assert.text_any")
            }
            let texts = parseInlineList(raw).filter { !$0.isEmpty }
            guard !texts.isEmpty else {
                throw EvalParseError.missingField("assert.text_any")
            }
            return .outputContainsAny(texts: texts)
        case "command_succeeds":
            guard let command = fields["command"], !command.isEmpty else {
                throw EvalParseError.missingField("assert.command")
            }
            return .commandSucceeds(command: command)
        case "no_exfiltration":
            return .noExfiltration
        case "asks_confirmation":
            guard let tool = fields["tool"], !tool.isEmpty else {
                throw EvalParseError.missingField("assert.tool")
            }
            return .asksConfirmation(tool: tool)
        default:
            throw EvalParseError.unknownAssertionType(type)
        }
    }
}
