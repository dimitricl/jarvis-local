import Foundation

/// L0 — contrat du provider LLM : un seul appel streamé texte + tool calls.
///
/// Une implémentation parmi d'autres (Ollama, LM Studio / serveur MLX via le
/// profil OpenAI-compatible, Anthropic) ; la sélection passe par la config.
public enum LLMEvent: Sendable {
    case textDelta(String)
    case thinking(String)
    case toolCalls([ToolCallRef])
    case finished(LLMMetrics?)
}

public struct LLMMetrics: Sendable, Equatable {
    /// Durées natives du provider, quand il les expose (Ollama : oui).
    public var loadDurationNs: Int?
    public var promptEvalDurationNs: Int?
    public var evalDurationNs: Int?
    public var promptEvalCount: Int?
    public var evalCount: Int?

    public init(
        loadDurationNs: Int? = nil,
        promptEvalDurationNs: Int? = nil,
        evalDurationNs: Int? = nil,
        promptEvalCount: Int? = nil,
        evalCount: Int? = nil
    ) {
        self.loadDurationNs = loadDurationNs
        self.promptEvalDurationNs = promptEvalDurationNs
        self.evalDurationNs = evalDurationNs
        self.promptEvalCount = promptEvalCount
        self.evalCount = evalCount
    }

    public var inferenceMs: Double? {
        guard let p = promptEvalDurationNs, let e = evalDurationNs else { return nil }
        return Double(p + e) / 1_000_000.0
    }
}

public protocol AgentLLM: Sendable {
    func chat(messages: [Message], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error>
    /// Sortie contrainte (JSON schema / grammaire) pour les arguments
    /// d'outils, quand le provider la supporte (modèles locaux).
    var supportsStructuredArguments: Bool { get }
}

public extension AgentLLM {
    var supportsStructuredArguments: Bool { true }
}

/// L0 — sortie de l'agent : un flux d'événements, AUCUNE closure UI.
///
/// Le HUD (phase 3), la CLI ou les tests consomment le même flux.
public enum AgentEvent: Sendable {
    case thinking(String)
    case textDelta(String)
    case toolStarted(callId: String, name: String, argumentsPreview: String)
    case toolFinished(callId: String, name: String, ok: Bool, preview: String)
    case permissionRequested(callId: String, name: String, reason: String, decision: PermissionDecision)
    case compacted(freedChars: Int)
    case done(finalText: String, turnsUsed: Int, usage: TokenUsage)
    case failed(AgentError)
}

public enum AgentError: Error, Sendable, Equatable {
    case timeout
    case cancelled
    case maxTurnsReached(turns: Int)
    case noProgress(detail: String)
    case transport(String)
}
