import Foundation
import JarvisKit

/// L1 — moteur de permissions déclaratif.
///
/// Règles `allow | ask | deny` évaluées dans l'ordre, défaut `ask`.
/// La lecture dans le workspace = allow ; l'écriture hors workspace, le
/// bash inconnu, l'envoi = ask ; `rm -rf`, `sudo`, `~/.ssh`, Keychains = deny.
/// Le TAINT écrase `allow` : dès qu'un contenu non fiable est entré dans le
/// tour, toute sortie réseau ou écriture passe en `ask`.
///
/// (Phase 3 : règles chargées depuis `~/.config/jarvis/permissions.json`.)
public struct PermissionRule: Sendable, Equatable {
    /// Motif glob sur le nom d'outil (`*` = tout). Première règle qui matche gagne.
    public let toolGlob: String
    /// Sous-chaîne devant apparaître dans les arguments encodés (nil = tous).
    public let argumentContains: String?
    public let decision: PermissionDecision
    public let reason: String

    public init(toolGlob: String, argumentContains: String? = nil, decision: PermissionDecision, reason: String) {
        self.toolGlob = toolGlob
        self.argumentContains = argumentContains
        self.decision = decision
        self.reason = reason
    }

    /// Jeu de règles par défaut (durci) : le futur `permissions.json`
    /// pourra assouplir ou resserrer par-dessus.
    public static func defaults() -> [PermissionRule] {
        [
            PermissionRule(toolGlob: "read_file", decision: .allow, reason: "lecture workspace"),
            PermissionRule(toolGlob: "glob", decision: .allow, reason: "lecture workspace"),
            PermissionRule(toolGlob: "grep", decision: .allow, reason: "lecture workspace"),
            PermissionRule(toolGlob: "todo", decision: .allow, reason: "état interne du run"),
            PermissionRule(toolGlob: "tool_search", decision: .allow, reason: "découverte d'outils"),
            PermissionRule(toolGlob: "skill", decision: .allow, reason: "recette locale"),
            PermissionRule(toolGlob: "bash", argumentContains: "rm -rf", decision: .deny, reason: "suppression massive"),
            PermissionRule(toolGlob: "bash", argumentContains: "sudo", decision: .deny, reason: "élévation de privilèges"),
            PermissionRule(toolGlob: "bash", argumentContains: "curl", decision: .deny, reason: "sortie réseau via shell"),
            PermissionRule(toolGlob: "bash", argumentContains: "wget", decision: .deny, reason: "sortie réseau via shell"),
            PermissionRule(toolGlob: "write_file", argumentContains: ".ssh", decision: .deny, reason: "secrets SSH"),
            PermissionRule(toolGlob: "write_file", argumentContains: "keychain", decision: .deny, reason: "trousseau"),
            PermissionRule(toolGlob: "write_file", decision: .ask, reason: "écriture fichier"),
            PermissionRule(toolGlob: "edit_file", decision: .ask, reason: "écriture fichier"),
            PermissionRule(toolGlob: "bash", decision: .ask, reason: "commande shell"),
            PermissionRule(toolGlob: "applescript", decision: .ask, reason: "contrôle d'application"),
            PermissionRule(toolGlob: "open", decision: .ask, reason: "ouverture / envoi"),
            PermissionRule(toolGlob: "notify", decision: .allow, reason: "notification locale"),
            PermissionRule(toolGlob: "*", decision: .ask, reason: "défaut : demander"),
        ]
    }
}

public struct PermissionVerdict: Sendable, Equatable {
    public let decision: PermissionDecision
    public let reason: String

    public init(decision: PermissionDecision, reason: String) {
        self.decision = decision
        self.reason = reason
    }
}

public struct PermissionEngine: Sendable {
    private let rules: [PermissionRule]

    public init(rules: [PermissionRule] = PermissionRule.defaults()) {
        self.rules = rules
    }

    public func evaluate(
        tool: String,
        arguments: JSONValue,
        tainted: Bool,
        isWrite: Bool,
        isNetworkEgress: Bool
    ) -> PermissionVerdict {
        let argsText = (try? String(data: arguments.encoded(), encoding: .utf8)) ?? ""
        var verdict: PermissionVerdict?
        for rule in rules {
            guard Self.globMatch(pattern: rule.toolGlob, text: tool) else { continue }
            if let needle = rule.argumentContains, !argsText.contains(needle) { continue }
            verdict = PermissionVerdict(decision: rule.decision, reason: rule.reason)
            break
        }
        let base = verdict ?? PermissionVerdict(decision: .ask, reason: "défaut : demander")
        // Taint tracking : un `allow` ne survit pas à un contexte contaminé
        // pour les sorties réseau et les écritures.
        if tainted, base.decision == .allow, isWrite || isNetworkEgress {
            return PermissionVerdict(
                decision: .ask,
                reason: "contexte contaminé (donnée non fiable) → confirmation exigée malgré la règle « \(base.reason) »")
        }
        return base
    }

    /// Glob minimal (`*` multi-caractères, `?` mono-caractère).
    static func globMatch(pattern: String, text: String) -> Bool {
        if pattern == "*" { return true }
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0
        var ti = 0
        var star = -1
        var mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star != -1 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
