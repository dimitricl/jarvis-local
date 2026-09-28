import Foundation
import JarvisKit
import JarvisAgent
import JarvisServices
import JarvisCore

/// L2 — outils MCP en citoyens de première classe.
///
/// `MCPToolSource` : tout fournisseur d'outils distants (vrai provider iMCP
/// ou fake de tests). L'adaptateur les convertit en `ToolDefinition`
/// NON-noyau (`isCore = false`, découverte via `tool_search`), à contenu
/// NON FIABLE (`producesUntrustedContent = true` : page lue par MCP, comme
/// tout contenu externe, contamine le tour).
public struct MCPToolInfo: Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONValue
    public let sensitive: Bool

    public init(name: String, description: String, parameters: JSONValue, sensitive: Bool = true) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.sensitive = sensitive
    }
}

public protocol MCPToolSource: Sendable {
    func isOnline() async -> Bool
    func tools() async -> [MCPToolInfo]
    func call(tool name: String, args: JSONValue) async throws -> String
}

public enum MCPToolsAdapter {
    public static func definitions(source: any MCPToolSource) -> [ToolDefinition] {
        // La découverte est synchrone côté registre : les outils MCP sont
        // résolus au premier appel (cache), pas à la construction.
        let box = MCPToolBox(source: source)
        return [ToolDefinition(
            name: "mcp_refresh",
            description: "Recharge la liste des outils MCP distants.",
            parameters: .object(["type": .string("object"), "properties": .object([:])]),
            isCore: false
        ) { _, _ in
            let tools = await box.refresh()
            if tools.isEmpty {
                return .failure(code: "offline", message: "Aucun serveur MCP en ligne.",
                                hint: "Procède avec les outils natifs.")
            }
            return .success(JSONValue("Outils MCP : " + tools.map { $0.name }.sorted().joined(separator: ", ")))
        }]
    }

    /// Convertit des infos déjà découvertes (appelées après `mcp_refresh` ou
    /// fournies par l'hôte) en définitions exécutables.
    public static func definitions(tools: [MCPToolInfo], source: any MCPToolSource) -> [ToolDefinition] {
        tools.map { info in
            ToolDefinition(
                name: info.name,
                description: info.description,
                parameters: info.parameters,
                isCore: false,
                isNetworkEgress: true,
                isWrite: info.sensitive,
                producesUntrustedContent: true
            ) { args, _ in
                do {
                    let out = try await source.call(tool: info.name, args: args)
                    return .success(JSONValue(out))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    return .failure(code: "mcp_error", message: "Outil MCP en échec : \(error).",
                                    hint: "Replie-toi sur l'équivalent natif ou conclus.")
                }
            }
        }
    }
}

private struct MCPToolBox: Sendable {
    let source: any MCPToolSource

    func refresh() async -> [MCPToolInfo] {
        await source.tools()
    }
}

/// Source live : le provider iMCP existant (JarvisServices), ponté en JSON
/// (le `[String: Any]` ne traverse pas les frontières Swift 6).
public struct LiveMCPToolSource: MCPToolSource {
    private let provider: MCPToolProvider

    public init(provider: MCPToolProvider) {
        self.provider = provider
    }

    public func isOnline() async -> Bool {
        await provider.isOnline()
    }

    public func tools() async -> [MCPToolInfo] {
        await provider.toolDefs().map { def in
            var properties: [String: JSONValue] = [:]
            for (k, v) in def.function.parameters.properties {
                properties[k] = .object([
                    "type": .string(v.type),
                    "description": .string(v.description ?? ""),
                ])
            }
            return MCPToolInfo(
                name: def.function.name,
                description: def.function.description,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(properties),
                    "required": .array(def.function.parameters.required.map { .string($0) }),
                ]))
        }
    }

    public func call(tool name: String, args: JSONValue) async throws -> String {
        let data = try args.encoded()
        return try await provider.callJSON(
            tool: name, argsJSON: String(data: data, encoding: .utf8) ?? "{}")
    }
}

public struct FakeMCPToolSource: MCPToolSource {
    public var toolsList: [MCPToolInfo]
    public var handler: @Sendable (String, JSONValue) async throws -> String

    public init(
        tools: [MCPToolInfo] = [],
        handler: @Sendable @escaping (String, JSONValue) async throws -> String = { name, _ in "MCP \(name) (simulé)." }
    ) {
        self.toolsList = tools
        self.handler = handler
    }

    public func isOnline() async -> Bool { true }

    public func tools() async -> [MCPToolInfo] { toolsList }

    public func call(tool name: String, args: JSONValue) async throws -> String {
        try await handler(name, args)
    }
}
