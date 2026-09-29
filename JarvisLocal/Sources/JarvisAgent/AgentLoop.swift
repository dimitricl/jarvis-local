import Foundation
import JarvisKit

/// L1 — boucle d'agent headless.
///
/// `while !done { llm.stream → tool_calls? → permission → execute
/// (parallèle) → append }`. Arrêt sur absence d'appel d'outil, limite de
/// tours configurable (défaut 30, pas 5), timeout global, annulation propre.
/// Sortie = `AsyncStream<AgentEvent>`, aucune closure UI.
public actor AgentLoop {
    public struct Config: Sendable {
        public var maxTurns: Int
        /// Échéance globale VÉRIFIÉE ENTRE LES TOURS (+ timeout transport du
        /// provider en backstop d'un tour muet). Un tour unique très lent peut
        /// la dépasser : le provider borne chaque appel (300 s par défaut).
        public var timeoutSeconds: Double?
        public var resultTruncationBytes: Int
        /// Répétitions identiques en échec avant `noProgress` (anti-boucle minimale).
        public var maxIdenticalRepeats: Int
        /// Messages récents gardés tels quels à la compaction.
        public var keepRecentMessages: Int
        /// Expose les outils étendus directement (harnais d'eval : mesure la
        /// capacité, pas la découverte via `tool_search`).
        public var exposeExtendedTools: Bool

        public init(
            maxTurns: Int = 30,
            timeoutSeconds: Double? = 600,
            resultTruncationBytes: Int = 4000,
            maxIdenticalRepeats: Int = 3,
            keepRecentMessages: Int = 6,
            exposeExtendedTools: Bool = false
        ) {
            self.maxTurns = maxTurns
            self.timeoutSeconds = timeoutSeconds
            self.resultTruncationBytes = resultTruncationBytes
            self.maxIdenticalRepeats = maxIdenticalRepeats
            self.keepRecentMessages = keepRecentMessages
            self.exposeExtendedTools = exposeExtendedTools
        }
    }

    private let llm: any AgentLLM
    private let registry: ToolRegistry
    private let permissions: PermissionEngine
    private var estimator: TokenEstimator
    private let realContextLength: @Sendable () async -> Int?
    private let transcripts: (any TranscriptStore)?
    private let todos: TodoStore?
    private let config: Config
    private let profile: AgentProfile
    /// Décision de confirmation (`ask`) : le HUD (phase 3) branche le vrai
    /// dialogue inline ; défaut fail-closed (refus).
    private let confirm: @Sendable (ToolCallRef, String) async -> Bool

    private var worker: Task<Void, Never>?
    /// Transcript du dernier run (remonté pour la reprise multi-tours).
    private var lastID: UUID?

    public init(
        llm: any AgentLLM,
        registry: ToolRegistry,
        permissions: PermissionEngine = PermissionEngine(),
        estimator: TokenEstimator = TokenEstimator(),
        realContextLength: @Sendable @escaping () async -> Int?,
        transcripts: (any TranscriptStore)? = nil,
        todos: TodoStore? = nil,
        config: Config = Config(),
        profile: AgentProfile = AgentProfile(),
        confirm: @Sendable @escaping (ToolCallRef, String) async -> Bool = { _, _ in false }
    ) {
        self.llm = llm
        self.registry = registry
        self.permissions = permissions
        self.estimator = estimator
        self.realContextLength = realContextLength
        self.transcripts = transcripts
        self.todos = todos
        self.config = config
        self.profile = profile
        self.confirm = confirm
    }

    /// Demande l'arrêt du run en cours. Granularité : le prochain événement
    /// LLM (quasi-immédiat en streaming réel, où les deltas pleuvent) ou le
    /// prochain point de contrôle de la boucle ; le timeout transport borne
    /// un provider muet. Émet `failed(.cancelled)`.
    public func cancel() {
        worker?.cancel()
    }

    public func run(prompt: String, resumeFrom transcriptId: UUID? = nil) -> AsyncStream<AgentEvent> {        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        worker?.cancel()
        worker = Task {
            await self.execute(prompt: prompt, resumeFrom: transcriptId, continuation: continuation)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancelWorker() }
        }
        return stream
    }

    /// ID du transcript du dernier run (nil si aucun) : permet au coordinator
    /// de chaîner les runs en reprise (`resumeFrom`) pour une vraie conversation.
    public func lastTranscriptID() -> UUID? { lastID }

    private func saveTranscript(_ transcript: Transcript) async {
        try? await transcripts?.save(transcript)
    }

    private func cancelWorker() {
        worker?.cancel()
        worker = nil
    }

    // MARK: - Boucle

    private func execute(
        prompt: String,
        resumeFrom transcriptId: UUID?,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        func emit(_ event: AgentEvent) { continuation.yield(event) }

        var transcript: Transcript
        if let id = transcriptId,
           let loaded = try? await transcripts?.load(id: id) {
            transcript = loaded
            transcript.append(Message(role: .user, content: prompt))
        } else {
            transcript = Transcript(model: "agent", messages: [
                Message(role: .system, content: AgentPrompts.system(profile: profile)),
                Message(role: .user, content: prompt),
            ])
            if let id = transcriptId { transcript.id = id }
        }
        lastID = transcript.id
        await saveTranscript(transcript)

        var tainted = transcript.messages.contains { $0.role == .tool }
        // Approximation prudente : un transcript repris avec des résultats
        // d'outils (potentiellement web) repart contaminé.
        var turns = 0
        var totalPromptTokens = 0
        var calibrated = false
        var lastFailureSignature: String?
        var lastFailureCount = 0
        var planReminded = false

        do {
            try await turnLoop(
                transcript: &transcript, tainted: &tainted, turns: &turns,
                totalPromptTokens: &totalPromptTokens, calibrated: &calibrated,
                lastFailureSignature: &lastFailureSignature,
                lastFailureCount: &lastFailureCount,
                planReminded: &planReminded,
                deadline: config.timeoutSeconds.map { Date().addingTimeInterval($0) },
                emit: emit)
        } catch is CancellationError {
            emit(.failed(.cancelled))
        } catch TimeoutError.timedOut {
            emit(.failed(.timeout))
        } catch {
            emit(.failed(.transport("\(error)")))
        }
        continuation.finish()
        worker = nil
    }

    private func turnLoop(
        transcript: inout Transcript,
        tainted: inout Bool,
        turns: inout Int,
        totalPromptTokens: inout Int,
        calibrated: inout Bool,
        lastFailureSignature: inout String?,
        lastFailureCount: inout Int,
        planReminded: inout Bool,
        deadline: Date?,
        emit: (AgentEvent) -> Void
    ) async throws {
        let compactor = Compactor(keepRecentMessages: config.keepRecentMessages)
        // Échecs transport consécutifs (pas de `continue` aveugle : voir catch).
        var transportFailures = 0

        while turns < config.maxTurns {
            try Task.checkCancellation()
            if let deadline, Date() > deadline { throw TimeoutError.timedOut }
            turns += 1
            let schemas = registry.coreSpecs(exposeExtended: config.exposeExtendedTools)

            // Compaction par résumé quand > 75 % du contexte RÉEL.
            let realLength = await realContextLength()
            var estimate = estimator.estimate(messages: transcript.messages, schemas: schemas)
            if ContextBudget.needsCompaction(estimatedTokens: estimate, realContextLength: realLength) {
                emit(.thinking("Contexte saturé, je résume l'historique…"))
                let todoSummary = await todos?.openSummary()
                let compacted = try await compactor.compact(
                    messages: transcript.messages, todoSummary: todoSummary, llm: llm)
                transcript.messages = compacted.messages
                await saveTranscript(transcript)
                emit(.compacted(freedChars: compacted.freedChars))
            } else if !planReminded,
                      ContextBudget.needsPlanReminder(estimatedTokens: estimate, realContextLength: realLength),
                      let summary = await todos?.openSummary() {
                planReminded = true
                transcript.append(Message(role: .user, content: "[rappel] " + summary))
                await saveTranscript(transcript)
            }

            // Appel modèle streamé.
            let promptChars = transcript.messages.reduce(0) { $0 + $1.approxChars }
                + schemas.reduce(0) { $0 + $1.approxChars }
            var text = ""
            var calls: [ToolCallRef] = []
            var metrics: LLMMetrics?
            do {
                for try await event in llm.chat(messages: transcript.messages, tools: schemas) {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let d):
                        text += d
                        emit(.textDelta(d))
                    case .thinking(let t):
                        emit(.thinking(t))
                    case .toolCalls(let c):
                        calls += c
                    case .finished(let m):
                        metrics = m
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Discipline anti-spirale : rejouer immédiatement à chaque tour
                // une panne transport (serveur saturé, modèle en chargement)
                // pilonne le serveur au lieu de le laisser récupérer —
                // constaté en réel : 30 tours « badStatus » qui s'auto-entretiennent.
                // Backoff 2 s × n, puis échec explicite après 3 échecs
                // consécutifs ; le compteur repart à zéro dès qu'un tour aboutit.
                transportFailures += 1
                guard transportFailures < 3 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(transportFailures) * 2_000_000_000)
                // UNE réparation : l'erreur structurée repart au tour suivant
                // via l'historique, le modèle s'adapte au lieu de subir.
                transcript.append(Message(role: .assistant, content: text.isEmpty ? nil : text))
                transcript.append(Message(role: .user, content: "[erreur transport : \(error). Réessaie ou conclus.]"))
                await saveTranscript(transcript)
                continue
            }
            transportFailures = 0
            // `for-await` sur un AsyncThrowingStream se termine en SILENCE
            // (nil) quand la tâche est annulée : convertir explicitement,
            // sinon l'annulation ressemble à une fin de stream normale.
            try Task.checkCancellation()
            if let m = metrics, let n = m.promptEvalCount {
                estimator.calibrate(promptChars: promptChars, promptTokens: n)
                totalPromptTokens += n
                calibrated = true
            }

            if calls.isEmpty {
                transcript.append(Message(role: .assistant, content: text))
                await saveTranscript(transcript)
                emit(.done(finalText: text, turnsUsed: turns,
                           usage: TokenUsage(promptTokens: totalPromptTokens, calibrated: calibrated)))
                return
            }

            transcript.append(Message(
                role: .assistant,
                content: text.isEmpty ? nil : text,
                toolCalls: calls))
            await saveTranscript(transcript)

            // Permissions (séquentiel, pas cher), puis exécution en parallèle.
            struct ApprovedCall: Sendable {
                let call: ToolCallRef
                let definition: ToolDefinition
            }
            var approved: [ApprovedCall] = []
            var refusedResults: [(ToolCallRef, ToolResult)] = []
            for call in calls {
                emit(.toolStarted(callId: call.id, name: call.name,
                                  argumentsPreview: call.arguments.preview()))
                guard let def = registry.definition(named: call.name) else {
                    refusedResults.append((call, .failure(
                        code: "not_allowed",
                        message: "Outil '\(call.name)' inconnu ou hors périmètre.",
                        hint: "N'utilise que les outils listés.")))
                    continue
                }
                let verdict = permissions.evaluate(
                    tool: call.name, arguments: call.arguments,
                    tainted: tainted, isWrite: def.isWrite, isNetworkEgress: def.isNetworkEgress)
                switch verdict.decision {
                case .allow:
                    approved.append(ApprovedCall(call: call, definition: def))
                case .ask:
                    emit(.permissionRequested(callId: call.id, name: call.name,
                                              reason: verdict.reason, decision: .ask))
                    if await confirm(call, verdict.reason) {
                        approved.append(ApprovedCall(call: call, definition: def))
                    } else {
                        refusedResults.append((call, .failure(
                            code: "denied",
                            message: "Action refusée (confirmation).",
                            hint: "Explique ce qui est bloqué et propose une alternative.")))
                    }
                case .deny:
                    emit(.permissionRequested(callId: call.id, name: call.name,
                                              reason: verdict.reason, decision: .deny))
                    refusedResults.append((call, .failure(
                        code: "denied",
                        message: "Action interdite par la politique : \(verdict.reason).",
                        hint: "Propose une alternative sûre au lieu de réessayer.")))
                }
            }

            // Exécution parallèle des appels approuvés (indépendants par
            // construction du batch : même tour, arguments déjà figés).
            let context = ToolCallContext(tainted: tainted)
            let truncation = config.resultTruncationBytes
            let executed: [(ToolCallRef, ToolResult, Bool)] = await withTaskGroup(
                of: (ToolCallRef, ToolResult, Bool).self,
                returning: [(ToolCallRef, ToolResult, Bool)].self
            ) { group in
                for item in approved {
                    group.addTask {
                        let result: ToolResult
                        do {
                            result = try await item.definition.execute(item.call.arguments, context)
                        } catch {
                            result = .failure(
                                code: "executor_error",
                                message: "Panne d'exécution : \(error).",
                                hint: "Signale la panne et conclus sans réessayer à l'identique.")
                        }
                        return (item.call, result, item.definition.producesUntrustedContent && result.ok)
                    }
                }
                var out: [(ToolCallRef, ToolResult, Bool)] = []
                for await r in group { out.append(r) }
                // Ordre déterministe : celui du batch modèle.
                let order = calls.map { $0.id }
                return out.sorted {
                    (order.firstIndex(of: $0.0.id) ?? 0) < (order.firstIndex(of: $1.0.id) ?? 0)
                }
            }

            // Append ordonné : refus puis exécutions, dans l'ordre du batch.
            var allResults: [(ToolCallRef, ToolResult)] =
                refusedResults + executed.map { ($0.0, $0.1) }
            let order = calls.map { $0.id }
            allResults.sort { (order.firstIndex(of: $0.0.id) ?? 0) < (order.firstIndex(of: $1.0.id) ?? 0) }
            for (call, result) in allResults {
                let text = (try? String(data: result.toJSON().encoded(), encoding: .utf8)) ?? "{\"ok\": false}"
                transcript.append(Message(
                    role: .tool,
                    content: TranscriptTrimming.truncateResult(text, limitBytes: truncation),
                    toolCallId: call.id,
                    name: call.name))
                emit(.toolFinished(callId: call.id, name: call.name, ok: result.ok,
                                   preview: text.prefix(200).description))
                // Garde anti-boucle minimale : même échec 3× → stop explicite.
                let signature = "\(call.name)#" + ((try? String(data: call.arguments.encoded(), encoding: .utf8)) ?? "")
                if !result.ok, signature == lastFailureSignature {
                    lastFailureCount += 1
                    if lastFailureCount >= config.maxIdenticalRepeats {
                        await saveTranscript(transcript)
                        emit(.failed(.noProgress(detail: "« \(call.name) » en échec \(lastFailureCount)× à l'identique.")))
                        return
                    }
                } else if !result.ok {
                    lastFailureSignature = signature
                    lastFailureCount = 1
                } else {
                    lastFailureSignature = nil
                    lastFailureCount = 0
                }
            }
            if executed.contains(where: { $0.2 }) { tainted = true }
            await saveTranscript(transcript)
        }

        emit(.failed(.maxTurnsReached(turns: turns)))
    }
}

private enum TimeoutError: Error {
    case timedOut
}
