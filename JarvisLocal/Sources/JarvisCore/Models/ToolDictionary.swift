import Foundation

/// Sérialisation d'une définition d'outil vers le format attendu par l'endpoint
/// OpenAI-compatible (`{type,function:{name,description,parameters}}`).
/// Déplacée à l'identique depuis OllamaService.swift : pure, sur type Core.
public extension ToolDef {
    var dictionary: [String: Any] {
        [
            "type": type,
            "function": [
                "name": function.name,
                "description": function.description,
                "parameters": [
                    "type": function.parameters.type,
                    "properties": function.parameters.properties.mapValues { ["type": $0.type, "description": $0.description ?? ""] },
                    "required": function.parameters.required
                ] as [String: Any]
            ] as [String: Any]
        ]
    }
}
