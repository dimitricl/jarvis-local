import Foundation
import JarvisKit

/// L3 — état de la fenêtre de chat : conversation multi-tours avec mémoire.
///
/// Séparé du HUD (`HUDState`) : le chat accumule les messages, le HUD affiche
/// l'état courant du run. La mémoire inter-prompts vient de la reprise de
/// transcript (`resumeFrom`, chaînée via `AgentHost.lastTranscriptID`).
/// Réduction pure et testée (`ChatReduce`), comme `HUDReduce`.
public enum ChatRole: String, Sendable, Equatable {
    case user
    case assistant
    case note
}

public struct ChatMessage: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var role: ChatRole
    public var text: String

    public init(id: UUID = UUID(), role: ChatRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// Confirmation d'outil en attente côté chat (miroir de `pendingConfirm`,
/// affiché par `ChatView` au lieu du HUD).
public struct ChatConfirm: Sendable, Equatable {
    public var tool: String
    public var reason: String

    public init(tool: String, reason: String) {
        self.tool = tool
        self.reason = reason
    }
}

public enum ChatReduce {
    /// Envoi : bulle user + bulle assistant vide (remplie au streaming).
    public static func send(messages: [ChatMessage], text: String) -> [ChatMessage] {
        messages + [ChatMessage(role: .user, text: text), ChatMessage(role: .assistant, text: "")]
    }

    /// Un événement agent fait avancer les messages (pur, testé).
    public static func apply(messages: [ChatMessage], event: AgentEvent) -> [ChatMessage] {
        var out = messages
        switch event {
        case .textDelta(let d):
            if out.last?.role == .assistant {
                out[out.count - 1].text += d
            } else {
                out.append(ChatMessage(role: .assistant, text: d))
            }
        case .thinking:
            break
        case .toolStarted(_, let name, let preview):
            out.append(ChatMessage(role: .note, text: "⚙ \(name) \(preview.prefix(80))"))
        case .toolFinished:
            break
        case .permissionRequested(_, let name, _, let decision):
            if decision == .ask {
                out.append(ChatMessage(role: .note, text: "? \(name) : confirmation demandée"))
            }
        case .compacted:
            break
        case .done(let text, _, _):
            if out.last?.role == .assistant {
                out[out.count - 1].text = text
            } else {
                out.append(ChatMessage(role: .assistant, text: text))
            }
        case .failed(let err):
            dropTrailingEmptyAssistant(&out)
            out.append(ChatMessage(role: .note, text: "⚠ " + brief(err)))
        }
        return out
    }

    private static func dropTrailingEmptyAssistant(_ messages: inout [ChatMessage]) {
        if messages.last?.role == .assistant, messages.last?.text.isEmpty == true {
            messages.removeLast()
        }
    }

    static func brief(_ err: AgentError) -> String {
        switch err {
        case .cancelled: return "interrompu"
        case .timeout: return "délai dépassé"
        case .maxTurnsReached(let t): return "sans conclusion après \(t) tours"
        case .noProgress(let d): return d
        case .transport(let d): return String(d.prefix(160))
        }
    }
}
