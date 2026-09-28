import Foundation
import JarvisKit

/// L1 — contexte d'exécution d'un outil (envoyé au handler, jamais au modèle).
public struct ToolCallContext: Sendable {
    /// true dès qu'un contenu non fiable est entré dans le tour (web, mail…).
    public var tainted: Bool
    public var workspace: String?
    public var runId: UUID

    public init(tainted: Bool = false, workspace: String? = nil, runId: UUID = UUID()) {
        self.tainted = tainted
        self.workspace = workspace
        self.runId = runId
    }
}

/// L1 — définition d'outil : schéma (compté au budget) + handler typé.
///
/// Le handler ne jette que pour les pannes d'infrastructure ; les échecs
/// métier sont des `ToolResult.failure` structurés.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONValue
    /// Outil du noyau exposé par défaut (les autres passent par `tool_search`).
    public let isCore: Bool
    /// Sortie réseau (taint → `ask` même si une règle dit `allow`).
    public let isNetworkEgress: Bool
    /// Écriture / envoi (permission + audit).
    public let isWrite: Bool
    /// Le résultat est un contenu NON FIABLE (web, mail…) : contamine le tour.
    public let producesUntrustedContent: Bool
    public let execute: @Sendable (JSONValue, ToolCallContext) async throws -> ToolResult

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        isCore: Bool = true,
        isNetworkEgress: Bool = false,
        isWrite: Bool = false,
        producesUntrustedContent: Bool = false,
        execute: @Sendable @escaping (JSONValue, ToolCallContext) async throws -> ToolResult
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.isCore = isCore
        self.isNetworkEgress = isNetworkEgress
        self.isWrite = isWrite
        self.producesUntrustedContent = producesUntrustedContent
        self.execute = execute
    }

    public var spec: ToolSpec {
        ToolSpec(name: name, description: description, parameters: parameters)
    }
}

/// L1 — registre : le modèle ne voit que le noyau par défaut.
///
/// Les outils étendus (MCP, skills) sont chargés à la demande via l'outil
/// `tool_search`, dont le handler interroge ce registre. Le budget de
/// contexte est explicite : `coreSchemasChars` est mesurable.
public struct ToolRegistry: Sendable {
    private let definitions: [String: ToolDefinition]

    public init(definitions: [ToolDefinition] = []) {
        var map: [String: ToolDefinition] = [:]
        for d in definitions { map[d.name] = d }
        self.definitions = map
    }

    public func definition(named name: String) -> ToolDefinition? {
        definitions[name]
    }

    public var toolNames: [String] {
        definitions.keys.sorted()
    }

    /// Schémas du noyau (+ `tool_search` si des outils étendus existent).
    public func coreSpecs() -> [ToolSpec] {
        var specs = definitions.values.filter { $0.isCore }.map { $0.spec }
        if definitions.values.contains(where: { !$0.isCore }) {
            specs.append(ToolSpec(
                name: "tool_search",
                description: "Recherche un outil étendu par mot-clé et expose son schéma.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["query": .object([
                        "type": .string("string"),
                        "description": .string("mot-clé"),
                    ])]),
                    "required": .array([.string("query")]),
                ])
            ))
        }
        return specs.sorted { $0.name < $1.name }
    }

    /// Recherche textuelle simple (nom + description) pour `tool_search`.
    public func search(query: String) -> [ToolSpec] {
        let q = query.lowercased()
        return definitions.values
            .filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
            .map { $0.spec }
            .sorted { $0.name < $1.name }
    }
}
