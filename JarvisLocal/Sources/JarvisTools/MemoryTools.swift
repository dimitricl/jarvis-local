import Foundation
import JarvisKit
import JarvisAgent

/// L2 — mémoire et recettes : `remember` + `skill`.
///
/// `remember` écrit via un `RememberStore` injecté (en-mémoire en eval,
/// SQLite v0.9.1 en phase 4 — jamais de succès mensonger : l'erreur DB
/// remonte au modèle). `skill` charge des recettes Markdown à la demande
/// (`~/.config/jarvis/skills/*.md`), qui remplacent les 30 outils métier
/// spécialisés.
public protocol RememberStore: Sendable {
    func remember(fact: String) async throws
    func facts() async -> [String]
}

public actor InMemoryRememberStore: RememberStore {
    private var stored: [String] = []

    public init() {}

    public func remember(fact: String) async throws {
        stored.append(fact)
    }

    public func facts() async -> [String] { stored }
}

public struct SkillsLoader: Sendable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func skillNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".md") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    public func content(name: String) -> String? {
        let safe = name.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: ".", with: "")
        guard !safe.isEmpty else { return nil }
        let url = directory.appendingPathComponent(safe + ".md")
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

public enum MemoryTools {
    public static func remember(store: any RememberStore) -> ToolDefinition {
        ToolDefinition(
            name: "remember",
            description: "Mémorise un fait durable sur l'utilisateur.",
            parameters: WorkspaceTools.stringParams(["fact": "fait à retenir"])
        ) { args, _ in
            guard let fact = args["fact"].string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fact.isEmpty
            else {
                return .failure(code: "bad_args", message: "Paramètre 'fact' manquant.", hint: "Relis le schéma.")
            }
            do {
                try await store.remember(fact: fact)
                return .success(JSONValue("Mémorisé : \(fact)"))
            } catch {
                return .failure(code: "store_error", message: "Mémorisation impossible : \(error).",
                                hint: "Ne prétends pas avoir mémorisé : réessaie ou conclus.")
            }
        }
    }

    public static func skill(loader: SkillsLoader) -> ToolDefinition {
        ToolDefinition(
            name: "skill",
            description: "Charge une recette nommée (savoir-faire métier) : list ou read.",
            parameters: WorkspaceTools.stringParams(["action": "list ou read", "name": "nom (pour read)"])
        ) { args, _ in
            let action = args["action"].string?.lowercased() ?? "list"
            if action == "list" {
                let names = loader.skillNames()
                if names.isEmpty {
                    return .failure(code: "no_skills", message: "Aucune recette installée.",
                                    hint: "Procède avec les outils généraux.")
                }
                return .success(JSONValue("Recettes : " + names.joined(separator: ", ")))
            }
            guard let name = args["name"].string, !name.isEmpty,
                  let content = loader.content(name: name)
            else {
                return .failure(code: "not_found", message: "Recette inconnue.",
                                hint: "Liste avec action=list.")
            }
            return .success(JSONValue(String(content.prefix(3000))))
        }
    }
}
