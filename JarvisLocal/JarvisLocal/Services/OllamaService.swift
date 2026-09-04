import Foundation

enum OllamaStreamEvent {
    case delta(String)
    case toolCalls([ToolCall])
}

extension TimeInterval {
    static let minRetryDelay: TimeInterval = 1
    static let maxRetryDelay: TimeInterval = 60
}

func retryDelay(for attempt: Int) -> TimeInterval {
    let base = 1.5
    let delay = pow(base, Double(attempt)) * 0.5
    return min(delay, TimeInterval.maxRetryDelay)
}

final class OllamaService: @unchecked Sendable {
    static let shared = OllamaService()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    private init() {}

    /// NOTE : `internal` pour les tests
    func makeURL() -> URL? {
        let s = Settings.shared.ollamaURL
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if s.hasSuffix("/chat/completions") { return URL(string: s) }
        return URL(string: "\(s)/v1/chat/completions")
    }

    /// URL de base du serveur Ollama, sans le suffixe /v1/chat/completions éventuel.
    /// Sert pour l'API native (/api/generate) que l'endpoint OpenAI /v1 ne couvre pas.
    private func makeBaseURL() -> URL? {
        var s = Settings.shared.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        for suffix in ["/v1/chat/completions", "/v1", "/"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }
        return URL(string: s)
    }

    /// Charge (ou recharge) le modèle dans la mémoire du serveur et prolonge sa durée de rétention.
    ///
    /// Contexte : l'app passe par /v1/chat/completions qui NE supporte PAS keep_alive — après
    /// 5 min d'inactivité Ollama décharge le modèle, et le premier message suivant met ~20-25s
    /// (chargement à froid) au lieu de ~0.5s. L'API native /api/generate, elle, accepte keep_alive :
    /// un ping avec prompt vide charge le modèle et repousse l'expiration. Appelé périodiquement
    /// par startKeepAlive(), ça garantit une latence constante.
    @discardableResult
    func warmUp(model: String, keepAlive: String = "15m") async -> Bool {
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            guard let base = makeBaseURL() else { return false }
            var req = URLRequest(url: base.appendingPathComponent("api/generate"))
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model,
                "prompt": "",
                "keep_alive": keepAlive,
                "options": ["num_predict": 1]
            ] as [String: Any])
            do {
                let (_, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    if attempt < maxRetries - 1 {
                        try? await Task.sleep(nanoseconds: UInt64(retryDelay(for: attempt) * 1_000_000_000))
                        continue
                    }
                    return false
                }
                return true
            } catch {
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(retryDelay(for: attempt) * 1_000_000_000))
                    continue
                }
                return false
            }
        }
        return false
    }

    /// Boucle de fond qui maintient le modèle chargé sur le serveur. Démarre par un warm-up
    /// immédiat (supprime les ~20s de chargement à froid au premier message), puis re-ping
    /// toutes les 4 minutes — sous la fenêtre de 5 min par défaut d'Ollama.
    private var keepAliveTask: Task<Void, Never>?

    func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let model = Settings.shared.model
                _ = await self.warmUp(model: model)
                try? await Task.sleep(nanoseconds: 4 * 60 * 1_000_000_000)
            }
        }
    }

    func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// Appel unique streamé qui gère à la fois le texte (delta par delta) ET les tool calls.
    /// Remplace l'ancien couple chat()/stream() : un seul aller-retour réseau vers Ollama,
    /// plus de risque de double appel LLM (bug identifié côté version TS de Jarvis).
    func streamChat(messages: [OllamaMessage], tools: [ToolDef]?) -> AsyncThrowingStream<OllamaStreamEvent, Error> {
        guard let url = makeURL() else {
            return AsyncThrowingStream { $0.finish(throwing: OllamaError.invalidURL) }
        }
        let m = Settings.shared.model
        let s = session
        let body = makeRequestBody(model: m, messages: messages, stream: true, tools: tools)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await s.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish(throwing: OllamaError.badStatus)
                        return
                    }

                    // Accumulation des tool calls par index (ils arrivent en petits morceaux successifs)
                    var toolCallsAcc: [Int: (id: String, name: String, arguments: String)] = [:]
                    var sawToolCalls = false

                    for try await line in bytes.lines {
                        try Task.checkCancellation()

                        guard line.hasPrefix("data: ") else { continue }
                        let dataStr = line.dropFirst(6)
                        if dataStr == "[DONE]" { break }

                        guard let json = try? JSONSerialization.jsonObject(with: Data(dataStr.utf8)) as? [String: Any] else {
                            continue
                        }

                        if let err = json["error"] as? String {
                            continuation.finish(throwing: OllamaError.modelError(err))
                            return
                        }

                        guard let choices = json["choices"] as? [[String: Any]],
                              let first = choices.first,
                              let delta = first["delta"] as? [String: Any]
                        else { continue }

                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(.delta(content))
                        }

                        if let rawCalls = delta["tool_calls"] as? [[String: Any]] {
                            sawToolCalls = true
                            for tc in rawCalls {
                                let idx = tc["index"] as? Int ?? 0
                                var entry = toolCallsAcc[idx] ?? (id: "", name: "", arguments: "")
                                if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                                if let function = tc["function"] as? [String: Any] {
                                    if let name = function["name"] as? String, !name.isEmpty {
                                        // Certains serveurs renvoient le nom COMPLET à chaque chunk
                                        // au lieu d'un fragment : += donnait "get_weatherget_weather"
                                        // → "Outil inconnu". On n'accumule que les vrais fragments.
                                        if entry.name.isEmpty || !entry.name.contains(name) {
                                            entry.name += name
                                        }
                                    }
                                    if let args = function["arguments"] as? String { entry.arguments += args }
                                }
                                toolCallsAcc[idx] = entry
                            }
                        }
                    }

                    if sawToolCalls {
                        let calls: [ToolCall] = toolCallsAcc.sorted { $0.key < $1.key }.map { _, v in
                            ToolCall(
                                id: v.id.isEmpty ? UUID().uuidString : v.id,
                                type: "function",
                                function: ToolCallFunction(name: v.name, arguments: v.arguments.isEmpty ? "{}" : v.arguments)
                            )
                        }
                        if !calls.isEmpty {
                            continuation.yield(.toolCalls(calls))
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeRequestBody(model: String, messages: [OllamaMessage], stream: Bool, tools: [ToolDef]?) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { msg in
                var d: [String: Any] = ["role": msg.role]
                if let c = msg.content { d["content"] = c }
                if let tcid = msg.toolCallId { d["tool_call_id"] = tcid }
                if let tc = msg.toolCalls {
                    d["tool_calls"] = tc.map { t in
                        [
                            "id": t.id,
                            "type": t.type ?? "function",
                            "function": ["name": t.function.name, "arguments": t.function.arguments]
                        ] as [String: Any]
                    }
                }
                return d
            },
            "stream": stream,
            "options": ["temperature": 0.7, "num_predict": Settings.shared.maxTokens] as [String: Any]
        ]
        // gemma4 est un modèle "thinking" : sans cette limite il passe 20-30s en raisonnement
        // interne AVANT chaque réponse (et ce, à CHAQUE itération de la boucle de tools), pendant
        // lesquelles l'UI n'affiche rien et l'utilisateur croit à un plantage. Mesuré : 32s -> 4s
        // sur un simple "hello" avec reasoning_effort none.
        body["reasoning_effort"] = Settings.shared.reasoningEffort
        if let t = tools { body["tools"] = t.map { $0.dictionary } }
        return body
    }
}

extension ToolDef {
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

enum OllamaError: Error, CustomStringConvertible {
    case badStatus
    case invalidResponse
    case interrupted
    case invalidURL
    case modelError(String)

    var description: String {
        switch self {
        case .badStatus:    "Le serveur Ollama a retourné un code d'erreur. Vérifie qu'il est bien lancé."
        case .invalidResponse: "Réponse invalide du serveur Ollama."
        case .interrupted:  "Requête annulée."
        case .invalidURL:   "L'URL Ollama dans les réglages est invalide. Vérifie le champ « URL : » dans les paramètres."
        case .modelError(let msg): "Erreur Ollama : \(msg)"
        }
    }
}
