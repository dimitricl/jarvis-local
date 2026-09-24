import Foundation
import os

/// Observabilité locale, structurée et sans contenu utilisateur.
///
/// Les journaux ne contiennent ni prompt, ni réponse, ni arguments, ni résultat
/// d'outil. Ils servent uniquement à diagnostiquer les latences et les échecs.
enum JarvisObservability {
    private static let turn = Logger(
        subsystem: "com.dimitriclaverie.JarvisLocal",
        category: "conversation-turn"
    )
    private static let tool = Logger(
        subsystem: "com.dimitriclaverie.JarvisLocal",
        category: "tool-execution"
    )

    static func turnStarted() {
        turn.info("turn_started")
    }

    static func turnFinished(outcome: String, startedAt: Date) {
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        turn.info("turn_finished outcome=\(outcome, privacy: .public) duration_ms=\(durationMs, privacy: .public)")
    }

    static func toolStarted(name: String) {
        tool.info("tool_started name=\(name, privacy: .public)")
    }

    static func toolFinished(name: String, outcome: String, startedAt: Date) {
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        tool.info("tool_finished name=\(name, privacy: .public) outcome=\(outcome, privacy: .public) duration_ms=\(durationMs, privacy: .public)")
    }
}
