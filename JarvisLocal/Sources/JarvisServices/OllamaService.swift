import Foundation
import JarvisCore

extension TimeInterval {
    static let minRetryDelay: TimeInterval = 1
    static let maxRetryDelay: TimeInterval = 60
}

func retryDelay(for attempt: Int) -> TimeInterval {
    let base = 1.5
    let delay = pow(base, Double(attempt)) * 0.5
    return min(delay, TimeInterval.maxRetryDelay)
}

/// Implémentation Ollama de LLMProvider (JarvisCore) : streaming OpenAI-compatible
/// + tool calling. Le ViewModel ne retient que le protocol ; cette classe reste
/// le point de contact réseau/serveur (étape 2 : factory).
public final class OllamaService: @unchecked Sendable, LLMProvider {
    public static let shared = OllamaService()

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
    /// Énergie : le ping est SAUTÉ en mode basse consommation ou état thermique
    /// sérieux/critique (un keep-alive qui réveille le réseau toutes les 4 min sur
    /// batterie est un anti-pattern macOS). Le prochain cycle re-ping quand ça va mieux.
    private var keepAliveTask: Task<Void, Never>?

    /// NOTE : `internal`/`static` pour les tests — fonction pure.
    nonisolated static func keepAliveShouldSkip(lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState) -> Bool {
        lowPowerMode || thermalState == .serious || thermalState == .critical
    }

    public func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pi = ProcessInfo.processInfo
                if !Self.keepAliveShouldSkip(lowPowerMode: pi.isLowPowerModeEnabled, thermalState: pi.thermalState) {
                    let model = Settings.shared.model
                    _ = await self.warmUp(model: model)
                }
                try? await Task.sleep(nanoseconds: 4 * 60 * 1_000_000_000)
            }
        }
    }

    public func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// Appel unique streamé qui gère à la fois le texte (delta par delta) ET les tool calls.
    /// Remplace l'ancien couple chat()/stream() : un seul aller-retour réseau vers Ollama,
    /// plus de risque de double appel LLM (bug identifié côté version TS de Jarvis).
    public func streamChat(messages: [OllamaMessage], tools: [ToolDef]?) -> AsyncThrowingStream<OllamaStreamEvent, Error> {
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
                    // finish_reason du chunk final ("stop" normal, "length" = coupé en
                    // pleine phrase : contexte serveur ou num_predict épuisé).
                    var truncated = false

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
                              let first = choices.first
                        else { continue }

                        // Le chunk final porte finish_reason avec un delta vide/absent :
                        // on le lit AVANT le guard sur delta (sinon "length" passe inaperçu).
                        if let fr = first["finish_reason"] as? String, !fr.isEmpty {
                            truncated = (fr == "length")
                        }

                        guard let delta = first["delta"] as? [String: Any]
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

                    continuation.yield(.finished(truncated: truncated))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Budget en caractères pour l'historique COMPLET envoyé au modèle (prompt système +
    /// conversation + résultats de tools), dérivé de num_ctx. AVANT : seul le NOMBRE de messages
    /// était borné (50 derniers) — quelques résultats search_web volumineux suffisaient à dépasser
    /// num_ctx, et Ollama tronquait alors silencieusement le DÉBUT du contexte (dont le prompt
    /// système) sans aucune erreur. Ici on réserve maxTokens (génération) + une marge (~1500
    /// tokens : prompt système, définitions de tools, overhead) et on convertit le reste en
    /// caractères (~4 caractères/token, même heuristique que l'ancien prototype TS). Le plancher
    /// évite un budget absurde quand numCtx est petit et maxTokens grand.
    /// NOTE : `internal`/`static` pour les tests — fonction pure, sans état.
    /// Forwarders vers ContextTrimming (JarvisCore) : l'implémentation pure a déménagé
    /// dans les contrats pour que JarvisUI n'ait plus à passer par ce type.
    /// Conservés pour les call-sites de tests existants — ne pas étendre.
    static func historyCharBudget(numCtx: Int, maxTokens: Int) -> Int {
        ContextTrimming.historyCharBudget(numCtx: numCtx, maxTokens: maxTokens)
    }

    /// Réduit un historique sous maxChars en dégrandant le moins utile d'abord. Passe 1 :
    /// tronque les contenus "tool" volumineux les plus anciens (avec marqueur explicite pour
    /// que le modèle sache qu'il voit un extrait). Passe 2 : remplace les contenus "tool"
    /// restants par un résumé d'une ligne (le message et son tool_call_id sont GARDÉS pour ne
    /// pas casser l'appariement appel ↔ résultat côté backend). Passe 3 (dernier recours) :
    /// supprime les messages les plus anciens. Puis réparation d'appariement systématique
    /// (dropOrphanedToolLinkage) : la passe 3 pouvant retirer un assistant porteur de
    /// tool_calls sans retirer ses messages "tool", on ne laisse jamais l'un sans l'autre
    /// en sortie — un tool_call_id orphelin ferait rejeter la requête suivante par les
    /// backends OpenAI-compatibles. Les 2 derniers messages ne sont JAMAIS touchés :
    /// dans la boucle de tools, ce sont les résultats qui viennent d'être produits et dont la
    /// prochaine itération a besoin. Fonction pure — AppViewModel l'applique à l'historique
    /// initial ET après chaque ajout de résultats de tools dans la boucle.
    /// Forwarder vers ContextTrimming (voir ci-dessus).
    static func trimMessagesForContext(_ messages: [OllamaMessage], maxChars: Int) -> [OllamaMessage] {
        ContextTrimming.trimMessagesForContext(messages, maxChars: maxChars)
    }

    /// Réparation d'appariement appel ↔ résultat. Retire avec sa paire manquante :
    /// - un message "tool" dont l'appel parent (assistant portant son tool_call_id)
    ///   a disparu est retiré ;
    /// - un tool_call sans message "tool" est retiré de son message assistant, et le
    ///   message lui-même est retiré s'il devient vide (ni texte ni appels restants).
    /// Les appels partiellement répondus sont conservés pour leur partie répondue.
    /// NOTE : `internal`/`static` pour les tests — fonction pure, sans état.
    /// Forwarder vers ContextTrimming (voir ci-dessus).
    static func dropOrphanedToolLinkage(_ messages: [OllamaMessage]) -> [OllamaMessage] {
        ContextTrimming.dropOrphanedToolLinkage(messages)
    }

    func makeRequestBody(model: String, messages: [OllamaMessage], stream: Bool, tools: [ToolDef]?) -> [String: Any] {        var body: [String: Any] = [
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
            "options": ["temperature": Settings.shared.temperature, "num_predict": Settings.shared.maxTokens, "num_ctx": Settings.shared.numCtx] as [String: Any]
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
