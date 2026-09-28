import Foundation
import JarvisKit

/// L3 — états visibles du HUD (pastille + panneau).
///
/// idle = invisible. Chaque autre état a son visuel (couleur, animation,
/// texte) : l'utilisateur sait toujours ce que fait l'agent sans ouvrir de
/// fenêtre. Machine à états pure et testée (`reduce`).
public enum HUDState: Sendable, Equatable {
    case idle
    case listening(level: Double)
    case transcribing(text: String)
    case thinking
    case acting(tool: String, target: String)
    case confirming(tool: String, reason: String, callId: String)
    case speaking(text: String)
    case done(summary: String)
    /// Serveur injoignable : UNE ligne + bouton réessayer (état normal).
    case unreachable(host: String)
    /// Modèle en chargement : durée écoulée visible, jamais de spinner muet.
    case loading(elapsed: Double)
    /// Contexte saturé : compaction en cours.
    case compacting

    public var isVisible: Bool {
        self != .idle
    }

    /// Pastille : libellé court sempre lisible.
    public var pill: String {
        switch self {
        case .idle: return ""
        case .listening: return "● écoute"
        case .transcribing(let t): return String(t.prefix(40))
        case .thinking: return "… réflexion"
        case .acting(let tool, let target):
            let short = target.isEmpty ? "" : " \(String(target.prefix(24)))"
            return "⚙ \(tool)\(short)"
        case .confirming(let tool, _, _): return "? \(tool)"
        case .speaking: return "♪ parole"
        case .done: return "✓ terminé"
        case .unreachable: return "⚠ serveur injoignable"
        case .loading(let e): return "… chargement \(Int(e)) s"
        case .compacting: return "… compaction"
        }
    }
}

public enum HUDAction: Sendable {
    case showListening
    case audioLevel(Double)
    case showTranscript(String)
    case agentEvent(AgentEvent)
    case connection(ConnectionState)
    case confirmAnswered(callId: String, allowed: Bool, always: Bool)
    case dismiss
    case interrupted
}

/// État de connexion (monitor → HUD). Timeouts distincts côté provider :
/// connexion court, premier token long, inter-tokens court.
public enum ConnectionState: Sendable, Equatable {
    case unknown
    case online(rttMs: Double, modelResident: Bool)
    case loadingModel(elapsed: Double)
    case unreachable(host: String)

    public var hudState: HUDState? {
        switch self {
        case .unknown: return nil
        case .online: return nil
        case .loadingModel(let e): return .loading(elapsed: e)
        case .unreachable(let h): return .unreachable(host: h)
        }
    }
}

public enum HUDReduce {
    /// Transition pure. Les événements agent priment sur la connexion, sauf
    /// `unreachable` qui s'affiche dès qu'aucun run n'est en cours.
    public static func reduce(state: HUDState, action: HUDAction, runActive: Bool) -> HUDState {
        switch action {
        case .showListening:
            return .listening(level: 0)
        case .audioLevel(let l):
            if case .listening = state { return .listening(level: l) }
            return state
        case .showTranscript(let t):
            return .transcribing(text: t)
        case .agentEvent(let event):
            return agentState(event)
        case .connection(let conn):
            if runActive { return state }
            return conn.hudState ?? .idle
        case .confirmAnswered:
            return .thinking
        case .dismiss:
            return .idle
        case .interrupted:
            return .idle
        }
    }

    public static func agentState(_ event: AgentEvent) -> HUDState {
        switch event {
        case .thinking: return .thinking
        case .textDelta: return .thinking
        case .toolStarted(_, let name, let preview):
            return .acting(tool: name, target: preview)
        case .toolFinished: return .thinking
        case .permissionRequested(let callId, let name, let reason, let decision):
            if decision == .deny { return .thinking }
            return .confirming(tool: name, reason: reason, callId: callId)
        case .compacted: return .compacting
        case .done(let text, _, _): return .done(summary: String(text.prefix(120)))
        case .failed: return .idle
        }
    }
}
