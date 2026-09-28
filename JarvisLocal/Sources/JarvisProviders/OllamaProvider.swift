import Foundation
import JarvisKit

/// L1 — configuration d'un provider Ollama / OpenAI-compatible distant.
///
/// Aucun hôte en dur : l'endpoint vient de la config (réglages, argv, env).
/// Le trafic est en HTTP clair UNIQUEMENT vers un hôte local, la plage
/// Tailscale `100.64.0.0/10` ou un nom MagicDNS (`*.ts.net`) ; tout autre
/// hôte exige HTTPS. Jeton optionnel (reverse proxy) via `authToken`,
/// renseigné depuis le Keychain en phase 3 — jamais dans le repo.
public struct OllamaConfig: Sendable {
    public var baseURL: String
    public var model: String
    public var numCtx: Int
    public var temperature: Double
    public var connectTimeout: Double
    public var requestTimeout: Double
    public var authToken: String?
    /// Premier token : long (chargement à froid du modèle distant).
    public var firstTokenTimeout: Double
    /// Entre deux tokens : court (un trou = incident réseau).
    public var interTokenTimeout: Double

    public init(
        baseURL: String,
        model: String,
        numCtx: Int = 16384,
        temperature: Double = 0.2,
        connectTimeout: Double = 3,
        requestTimeout: Double = 300,
        firstTokenTimeout: Double = 180,
        interTokenTimeout: Double = 30,
        authToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.numCtx = numCtx
        self.temperature = temperature
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.firstTokenTimeout = firstTokenTimeout
        self.interTokenTimeout = interTokenTimeout
        self.authToken = authToken
    }

    public func validatedBaseURL() throws -> URL {
        try OllamaHostPolicy.validateBaseURL(baseURL)
    }
}

public enum OllamaHostPolicy {
    public enum ValidationError: Error, Sendable, Equatable {
        case empty
        case malformed(String)
        case insecureRemoteHost(host: String)
    }

    public static func validateBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            throw ValidationError.malformed(raw)
        }
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw ValidationError.malformed(raw)
        }
        if scheme == "http", !isInsecureAllowed(host: host.lowercased()) {
            throw ValidationError.insecureRemoteHost(host: host)
        }
        return url
    }

    public static func isInsecureAllowed(host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "127",
           parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return true }
        if host.hasSuffix(".ts.net") { return true }
        let octets = parts.compactMap { Int($0) }
        if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return true }
        return false
    }
}

/// L1 — provider Ollama via `/v1/chat/completions` (OpenAI-compatible,
/// stream + tools).
///
/// Pourquoi `/v1` et pas l'API native `/api/chat` : en streaming (`stream`
/// + `tools`), `/api/chat` renvoie vide pour gemma4 sur ce serveur (ni texte
/// ni `tool_calls`, constaté en live 2026-09-28) alors que `/v1` streamé
/// fonctionne — c'est aussi le chemin éprouvé par l'app v0.9.1.
public struct OllamaProvider: AgentLLM {
    private let config: OllamaConfig
    private let base: URL

    public init(config: OllamaConfig) throws {
        self.config = config
        self.base = try config.validatedBaseURL()
    }

    public func chat(messages: [Message], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        let config = self.config
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let token = config.authToken, !token.isEmpty {
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    req.timeoutInterval = config.connectTimeout
                    req.httpBody = try OllamaProvider.requestBody(
                        model: config.model, messages: messages, tools: tools,
                        numCtx: config.numCtx, temperature: config.temperature)

                    let session = OllamaProvider.session(requestTimeout: config.requestTimeout)
                    let (bytes, resp) = try await session.bytes(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        throw OllamaProviderError.badStatus
                    }

                    // Watchdog : premier token long (chargement à froid),
                    // inter-tokens court. Un timeout n'est jamais silencieux :
                    // il termine le stream en erreur explicite.
                    let activity = StreamActivity()
                    await activity.mark()
                    let watchdog = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            let idle = await activity.idleSeconds()
                            let limit = await activity.seenFirst ? config.interTokenTimeout : config.firstTokenTimeout
                            if idle > limit {
                                let first = !(await activity.seenFirst)
                                await activity.trip()
                                continuation.finish(throwing: OllamaProviderError.stalled(
                                    first: first, idleSeconds: idle))
                                return
                            }
                        }
                    }
                    defer { watchdog.cancel() }

                    var state = OllamaProvider.SseState()
                    var metrics: LLMMetrics?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if await activity.isTripped() { return }
                        let emitted = OllamaProvider.applySSELine(line, state: &state, metrics: &metrics)
                        if !emitted.textDeltas.isEmpty || emitted.finished {
                            await activity.mark()
                        }
                        for text in emitted.textDeltas { continuation.yield(.textDelta(text)) }
                        if emitted.finished { break }
                    }
                    watchdog.cancel()
                    if await activity.isTripped() { return }
                    if !state.calls.isEmpty { continuation.yield(.toolCalls(state.calls)) }
                    continuation.yield(.finished(metrics))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Pur et testé sans réseau

    static func session(requestTimeout: Double) -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: c)
    }

    static func requestBody(
        model: String,
        messages: [Message],
        tools: [ToolSpec],
        numCtx: Int,
        temperature: Double
    ) throws -> Data {
        var encoded: [[String: Any]] = []
        for m in messages {
            switch m.role {
            case .system, .user:
                encoded.append(["role": m.role.rawValue, "content": m.content ?? ""])
            case .assistant:
                var d: [String: Any] = ["role": "assistant"]
                if let c = m.content { d["content"] = c }
                if let tc = m.toolCalls, !tc.isEmpty {
                    d["tool_calls"] = tc.map { t in
                        ["id": t.id, "type": "function",
                         "function": [
                            "name": t.name,
                            "arguments": String(data: (try? t.arguments.encoded()) ?? Data("{}".utf8),
                                                encoding: .utf8) ?? "{}",
                         ]]
                    }
                }
                encoded.append(d)
            case .tool:
                encoded.append([
                    "role": "tool",
                    "content": m.content ?? "",
                    "tool_call_id": m.toolCallId ?? "",
                ])
            }
        }
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": encoded,
            "options": ["temperature": temperature, "num_ctx": numCtx] as [String: Any],
            // gemma4 est thinking : sans ça, 20-30 s de raisonnement invisible
            // par tour (mesuré 32 s → 4 s sur un simple bonjour).
            "reasoning_effort": "none",
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { t in
                ["type": "function",
                 "function": ["name": t.name, "description": t.description,
                              "parameters": t.parameters.toAny()]]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// État d'accumulation des fragments `tool_calls` (arrivent en morceaux).
    struct SseState: Sendable {
        var fragments: [Int: (id: String, name: String, arguments: String)] = [:]
        var calls: [ToolCallRef] = []
    }

    struct SseEmitted: Sendable {
        var textDeltas: [String] = []
        var finished = false
    }

    /// Applique une ligne SSE (`data: {...}` / `data: [DONE]`), pur et testé.
    /// Les fragments `tool_calls` sont accumulés par index ; le nom complet
    /// renvoyé à chaque chunk par certains serveurs n'est pas dupliqué.
    static func applySSELine(
        _ line: String,
        state: inout SseState,
        metrics: inout LLMMetrics?
    ) -> SseEmitted {
        var out = SseEmitted()
        guard line.hasPrefix("data: ") else { return out }
        let payload = String(line.dropFirst(6))
        if payload == "[DONE]" {
            out.finished = true
            return out
        }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return out }
        if let usage = json["usage"] as? [String: Any] {
            metrics = LLMMetrics(
                promptEvalCount: usage["prompt_tokens"] as? Int,
                evalCount: usage["completion_tokens"] as? Int)
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first
        else { return out }
        if let reason = first["finish_reason"] as? String, !reason.isEmpty {
            out.finished = true
        }
        guard let delta = first["delta"] as? [String: Any] else {
            // Chunk final : vide le accumulateur en appels complets.
            if out.finished { state.calls = flushFragments(state.fragments) }
            return out
        }
        if let content = delta["content"] as? String, !content.isEmpty {
            out.textDeltas.append(content)
        }
        if let rawCalls = delta["tool_calls"] as? [[String: Any]] {
            for tc in rawCalls {
                let idx = tc["index"] as? Int ?? 0
                var entry = state.fragments[idx] ?? (id: "", name: "", arguments: "")
                if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                if let function = tc["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty,
                       entry.name.isEmpty || !entry.name.contains(name) {
                        entry.name += name
                    }
                    if let args = function["arguments"] as? String { entry.arguments += args }
                }
                state.fragments[idx] = entry
            }
        }
        if out.finished { state.calls = flushFragments(state.fragments) }
        return out
    }

    static func flushFragments(_ fragments: [Int: (id: String, name: String, arguments: String)]) -> [ToolCallRef] {
        fragments.sorted { $0.key < $1.key }.compactMap { _, v in
            guard !v.name.isEmpty else { return nil }
            let args: JSONValue
            if v.arguments.isEmpty {
                args = .object([:])
            } else if let data = v.arguments.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) {
                args = (try? JSONValue(jsonObject: obj)) ?? .object([:])
            } else {
                // UNE réparation : JSON invalide → objet vide + le modèle
                // reçoit l'échec structuré et corrige au tour suivant.
                args = .object(["_unparseable": .string(v.arguments)])
            }
            return ToolCallRef(
                id: v.id.isEmpty ? UUID().uuidString : v.id,
                name: v.name,
                arguments: args)
        }
    }
}

public enum OllamaProviderError: Error, Sendable, Equatable {
    case badStatus
    case invalidResponse
    /// Stream muet : `first` = aucun premier token (chargement à froid
    /// probable), sinon trou inter-tokens. `idleSeconds` = durée constatée.
    case stalled(first: Bool, idleSeconds: Double)
}

/// Activité du stream pour le watchdog (acteur : partagé entre la boucle de
/// lecture et la tâche de surveillance).
actor StreamActivity {
    private var last: Date
    private(set) var seenFirst = false
    private var tripped = false

    init() {
        self.last = Date()
    }

    func mark() {
        last = Date()
        seenFirst = true
    }

    func trip() {
        tripped = true
    }

    func isTripped() -> Bool { tripped }

    func idleSeconds() -> Double {
        Date().timeIntervalSince(last)
    }
}
