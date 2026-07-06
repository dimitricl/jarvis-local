import Foundation

enum OllamaStreamEvent {
    case delta(String)
    case toolCalls([ToolCall])
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

    private func makeURL() -> URL? {
        let s = Settings.shared.ollamaURL
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        if s.hasSuffix("/chat/completions") { return URL(string: s) }
        return URL(string: "\(s)/v1/chat/completions")
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
                                    if let name = function["name"] as? String { entry.name += name }
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
            "options": ["temperature": 0.7, "num_predict": 2048] as [String: Any]
        ]
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
