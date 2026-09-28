import Foundation
import JarvisKit
import JarvisAgent

/// L2 — permissions déclaratives (`~/.config/jarvis/permissions.json`).
///
/// ```json
/// { "rules": [
///   {"tool": "read_file", "decision": "allow", "reason": "lecture"},
///   {"tool": "bash", "args_contain": "rm -rf", "decision": "deny", "reason": "…"}
/// ]}
/// ```
/// Les règles fichier sont PRÉPENDÉES aux défauts (le fichier gagne).
/// Fichier absent ou illisible = défauts durcis (fail-closed), jamais de
/// plantage : un JSON cassé est signalé et ignoré.
public struct PermissionFileEntry: Sendable, Codable, Equatable {
    public var tool: String
    public var argsContain: String?
    public var decision: PermissionDecision
    public var reason: String

    public init(tool: String, argsContain: String? = nil, decision: PermissionDecision, reason: String) {
        self.tool = tool
        self.argsContain = argsContain
        self.decision = decision
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case tool
        case argsContain = "args_contain"
        case decision
        case reason
    }

    public func asRule() -> PermissionRule {
        PermissionRule(toolGlob: tool, argumentContains: argsContain, decision: decision, reason: reason)
    }
}

public struct PermissionFile: Sendable, Codable, Equatable {
    public var rules: [PermissionFileEntry]

    public init(rules: [PermissionFileEntry] = []) {
        self.rules = rules
    }

    /// Charge + fusionne (fichier d'abord). Ne jette jamais : renvoie les
    /// défauts et le problème éventuel.
    public static func load(from url: URL) -> (engine: PermissionEngine, warning: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (PermissionEngine(), nil)
        }
        do {
            let file = try JSONDecoder().decode(PermissionFile.self, from: Data(contentsOf: url))
            let merged = file.rules.map { $0.asRule() } + PermissionRule.defaults()
            return (PermissionEngine(rules: merged), nil)
        } catch {
            return (PermissionEngine(),
                    "permissions.json illisible (\(error)) : défauts durcis appliqués.")
        }
    }

    public static func defaultURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/jarvis/permissions.json")
    }
}
