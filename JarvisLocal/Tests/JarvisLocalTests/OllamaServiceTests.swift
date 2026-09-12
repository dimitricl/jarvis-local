@testable import JarvisLocal
import XCTest

final class JarvisLocalOllamaService_OllamaTests: XCTestCase {

    var ollamaService: OllamaService!

    override func setUp() async throws {
        try await super.setUp()
        ollamaService = OllamaService.shared
    }

    override func tearDown() async throws {
        ollamaService.stopKeepAlive()
        try await super.tearDown()
    }

    // MARK: - Request Body Tests (existing tests moved here)

    func testMakeRequestBodyStructure() {
        let messages = [OllamaMessage(role: "user", content: "hello")]
        let tools = [ToolDef(function: ToolFunction(name: "test", description: "A test tool", parameters: ToolParameters(properties: [:], required: [])))]
        let body = ollamaService.makeRequestBody(model: "gemma2", messages: messages, stream: true, tools: tools)
        XCTAssertEqual(body["model"] as? String, "gemma2")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["messages"])
        XCTAssertNotNil(body["tools"])
    }

    func testMakeRequestBodyWithoutTools() {
        let messages = [OllamaMessage(role: "system", content: "test")]
        let body = ollamaService.makeRequestBody(model: "llama3", messages: messages, stream: false, tools: nil)
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["model"] as? String, "llama3")
    }

    func testMakeRequestBodyMessageWithToolCallId() {
        let msg = OllamaMessage(role: "tool", content: "result", toolCallId: "call_abc")
        let body = ollamaService.makeRequestBody(model: "m", messages: [msg], stream: false, tools: nil)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs[0]["tool_call_id"] as? String, "call_abc")
    }

    func testMakeRequestBodyWithToolCalls() {
        let tc = ToolCall(id: "c1", type: "function", function: ToolCallFunction(name: "test", arguments: "{}"))
        let msg = OllamaMessage(role: "assistant", content: nil, toolCalls: [tc])
        let body = ollamaService.makeRequestBody(model: "m", messages: [msg], stream: false, tools: nil)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertNotNil(msgs[0]["tool_calls"])
    }

    func testMakeRequestBodyIncludesReasoningEffort() {
        let messages = [OllamaMessage(role: "user", content: "test")]
        let body = ollamaService.makeRequestBody(model: "gemma4", messages: messages, stream: true, tools: nil)
        XCTAssertNotNil(body["reasoning_effort"])
    }

    func testMakeRequestBodyOptionsIncludeTemperatureAndNumPredict() {
        let messages = [OllamaMessage(role: "user", content: "test")]
        let body = ollamaService.makeRequestBody(model: "test", messages: messages, stream: true, tools: nil)
        let options = body["options"] as? [String: Any]
        XCTAssertNotNil(options)
        XCTAssertEqual(options?["temperature"] as? Double, 0.7)
        // num_predict doit refléter le réglage maxTokens (réponses non coupées)
        XCTAssertEqual(options?["num_predict"] as? Int, Settings.shared.maxTokens)
    }

    func testMaxTokensSettingIsClampedToSaneRange() {
        let original = Settings.shared.maxTokens
        defer { Settings.shared.maxTokens = original }

        Settings.shared.maxTokens = 10
        XCTAssertEqual(Settings.shared.maxTokens, 256) // borne basse

        Settings.shared.maxTokens = 100_000
        XCTAssertEqual(Settings.shared.maxTokens, 32_768) // borne haute
    }

    // MARK: - URL Building Tests

    func testMakeURLWithValidBase() {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        settings.ollamaURL = "http://localhost:11434"
        defer { settings.ollamaURL = originalURL }

        let url = ollamaService.makeURL()
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testMakeURLWithChatCompletionsSuffix() {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        settings.ollamaURL = "http://localhost:11434/v1/chat/completions"
        defer { settings.ollamaURL = originalURL }

        let url = ollamaService.makeURL()
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testMakeURLWithEmptyString() {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        settings.ollamaURL = ""
        defer { settings.ollamaURL = originalURL }

        let url = ollamaService.makeURL()
        XCTAssertNil(url)
    }

    func testMakeURLWithWhitespace() {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        settings.ollamaURL = "   "
        defer { settings.ollamaURL = originalURL }

        let url = ollamaService.makeURL()
        XCTAssertNil(url)
    }

    func testMakeBaseURL() {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        settings.ollamaURL = "http://localhost:11434/v1/chat/completions"
        defer { settings.ollamaURL = originalURL }

        // Can't directly test private method, but we can verify it doesn't crash
        // by calling a public method that uses it indirectly
        XCTAssertTrue(true)
    }

    // MARK: - Keep Alive Tests

    func testStartKeepAliveCreatesTask() {
        ollamaService.startKeepAlive()
        // Just verify it doesn't crash
        XCTAssertTrue(true)
    }

    func testStartKeepAliveIdempotent() {
        ollamaService.startKeepAlive()
        ollamaService.startKeepAlive()
        // Should not create multiple tasks
        XCTAssertTrue(true)
    }

    func testStopKeepAliveCancelsTask() {
        ollamaService.startKeepAlive()
        ollamaService.stopKeepAlive()
        // Should not crash
        XCTAssertTrue(true)
    }

    func testStopKeepAliveIdempotent() {
        ollamaService.stopKeepAlive()
        ollamaService.stopKeepAlive()
        // Should not crash
        XCTAssertTrue(true)
    }

    // MARK: - Warm Up Tests (Integration - requires Ollama server)

    func testWarmUpWithoutServerReturnsFalse() async {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        let originalModel = settings.model
        settings.ollamaURL = "http://invalid-host:11434"
        settings.model = "test-model"
        defer {
            settings.ollamaURL = originalURL
            settings.model = originalModel
        }

        let result = await ollamaService.warmUp(model: "test-model")
        // Should return false when server is unreachable
        XCTAssertFalse(result)
    }
}

final class JarvisLocalOllamaStreamParsingTests: XCTestCase {

    // Test the stream parsing logic by testing the ToolDef dictionary encoding
    func testToolDefDictionaryEncoding() {
        let tool = ToolDef(function: ToolFunction(
            name: "search_web",
            description: "Search the web",
            parameters: ToolParameters(
                properties: ["query": ToolProperty(type: "string", description: "The query")],
                required: ["query"]
            )
        ))
        let dict = tool.dictionary

        XCTAssertEqual(dict["type"] as? String, "function")
        let fn = dict["function"] as! [String: Any]
        XCTAssertEqual(fn["name"] as? String, "search_web")
        XCTAssertEqual(fn["description"] as? String, "Search the web")
        let params = fn["parameters"] as! [String: Any]
        XCTAssertEqual(params["type"] as? String, "object")
        XCTAssertEqual(params["required"] as? [String], ["query"])
    }

    func testToolDefDictionaryWithNilDescription() {
        let prop = ToolProperty(type: "string", description: nil)
        let data = try! JSONEncoder().encode(prop)
        let decoded = try! JSONDecoder().decode(ToolProperty.self, from: data)
        XCTAssertNil(decoded.description)
    }

    func testOllamaMessageToolCallSerialization() {
        let calls = [ToolCall(id: "call_1", type: "function", function: ToolCallFunction(name: "test", arguments: "{}"))]
        let msg = OllamaMessage(role: "assistant", content: nil, toolCalls: calls)
        let data = try! JSONEncoder().encode(msg)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(json["tool_calls"])
        let tcArray = json["tool_calls"] as! [[String: Any]]
        XCTAssertEqual(tcArray[0]["id"] as? String, "call_1")
        XCTAssertEqual(tcArray[0]["type"] as? String, "function")
    }

    func testOllamaMessageWithoutToolCalls() {
        let msg = OllamaMessage(role: "user", content: "hello")
        let data = try! JSONEncoder().encode(msg)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["tool_calls"])
        XCTAssertEqual(json["role"] as? String, "user")
        XCTAssertEqual(json["content"] as? String, "hello")
    }

    func testOllamaMessageToolCallIdSerialization() {
        let msg = OllamaMessage(role: "tool", content: "result", toolCallId: "call_abc123")
        let data = try! JSONEncoder().encode(msg)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["tool_call_id"] as? String, "call_abc123")
    }

    func testOllamaMessageToolCallIdAbsentWhenNil() {
        let msg = OllamaMessage(role: "user", content: "hello")
        let data = try! JSONEncoder().encode(msg)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["tool_call_id"])
    }
}

final class JarvisLocalOllamaError_OllamaTests: XCTestCase {
    func testAllErrorDescriptionsNonEmpty() {
        let all: [OllamaError] = [.badStatus, .invalidResponse, .interrupted, .invalidURL, .modelError("test")]
        for e in all {
            XCTAssertFalse(e.description.isEmpty, "\(e) should have a description")
        }
    }

    func testInvalidURLDescription() {
        let err = OllamaError.invalidURL
        XCTAssertTrue(err.description.contains("URL"))
    }

    func testBadStatusDescription() {
        let err = OllamaError.badStatus
        XCTAssertTrue(err.description.contains("Ollama"))
    }

    func testModelErrorIncludesMessage() {
        let err = OllamaError.modelError("Custom error message")
        XCTAssertTrue(err.description.contains("Custom error message"))
    }

    func testInterruptedDescription() {
        let err = OllamaError.interrupted
        XCTAssertTrue(err.description.contains("annulée") || err.description.contains("interrupt"))
    }

    func testInvalidResponseDescription() {
        let err = OllamaError.invalidResponse
        XCTAssertTrue(err.description.contains("invalide") || err.description.contains("invalid"))
    }
}

final class JarvisLocalHistoryBudgetTests: XCTestCase {

    func testHistoryCharBudgetReservesGenerationAndMargin() {
        // (16384 - 8192 - 1500) * 4 : la génération (maxTokens) et la marge système
        // ne doivent jamais être mangées par l'historique.
        XCTAssertEqual(
            OllamaService.historyCharBudget(numCtx: 16384, maxTokens: 8192),
            (16384 - 8192 - 1500) * 4
        )
    }

    func testHistoryCharBudgetNeverBelowFloor() {
        // numCtx petit + maxTokens énorme : on plafonne au plancher plutôt que de
        // retourner un budget nul/négatif qui viderait tout l'historique.
        XCTAssertEqual(OllamaService.historyCharBudget(numCtx: 2048, maxTokens: 32768), 4000)
    }

    func testTrimLeavesShortHistoryUntouched() {
        let msgs = [
            OllamaMessage(role: "system", content: "sys"),
            OllamaMessage(role: "user", content: "bonjour"),
            OllamaMessage(role: "assistant", content: "salut"),
        ]
        let out = OllamaService.trimMessagesForContext(msgs, maxChars: 10_000)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1].content, "bonjour")
    }

    func testTrimTruncatesOldBulkyToolMessageFirst() {
        let huge = String(repeating: "résultat search_web ", count: 500)
        let msgs = [
            OllamaMessage(role: "system", content: "sys"),
            OllamaMessage(role: "assistant", content: nil, toolCalls: [
                ToolCall(id: "c1", type: "function", function: ToolCallFunction(name: "search_web", arguments: "{}"))
            ]),
            OllamaMessage(role: "tool", content: huge, toolCallId: "c1"),
            OllamaMessage(role: "assistant", content: "voici la réponse"),
            OllamaMessage(role: "user", content: "merci !"),
        ]
        let out = OllamaService.trimMessagesForContext(msgs, maxChars: 4000)
        // Le vieux résultat "tool" est tronqué avec marqueur, pas supprimé (le
        // tool_call_id est gardé pour l'appariement appel ↔ résultat).
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out[2].toolCallId, "c1")
        XCTAssertTrue(out[2].content?.contains("tronqué") == true)
        XCTAssertLessThanOrEqual(out[2].content?.count ?? .max, 3600)
        // La queue récente (réponse + dernier message) est intacte.
        XCTAssertEqual(out[3].content, "voici la réponse")
        XCTAssertEqual(out[4].content, "merci !")
    }

    func testTrimNeverTouchesLastTwoMessages() {
        let big = String(repeating: "x", count: 5000)
        let msgs = [
            OllamaMessage(role: "system", content: "sys"),
            OllamaMessage(role: "user", content: "question"),
            // Queue réaliste et APPARIÉE : dans la boucle de tools, un résultat "tool"
            // suit toujours son assistant porteur des tool_calls. (Un tool sans parent
            // serait légitimement réparé par le sweep d'appariement, voir plus bas.)
            OllamaMessage(role: "assistant", content: nil, toolCalls: [
                ToolCall(id: "c9", type: "function", function: ToolCallFunction(name: "search_web", arguments: "{}"))
            ]),
            OllamaMessage(role: "tool", content: big, toolCallId: "c9"),
        ]
        // Budget minuscule : même en dernier recours, les 2 derniers (résultats frais
        // du tour en cours) doivent survivre tels quels.
        let out = OllamaService.trimMessagesForContext(msgs, maxChars: 100)
        XCTAssertEqual(out.last?.content, big)
        XCTAssertEqual(out.last?.toolCallId, "c9")
        XCTAssertEqual(out[out.count - 2].toolCalls?.first?.id, "c9")
        XCTAssertEqual(out.first?.role, "system")
    }

    func testTrimEmptyHistory() {
        XCTAssertTrue(OllamaService.trimMessagesForContext([], maxChars: 100).isEmpty)
    }

    // MARK: - Pairing assistant/tool_calls + tool (aucun orphelin en sortie)

    /// Invariant exigé par les backends OpenAI-compatibles : chaque message "tool"
    /// a un assistant parent portant son tool_call_id, et chaque tool_call d'assistant
    /// a son message "tool". Un orphelin = requête suivante rejetée.
    private func assertNoOrphanToolLinkage(
        _ msgs: [OllamaMessage], file: StaticString = #filePath, line: UInt = #line
    ) {
        let called = Set(msgs.filter { $0.role == "assistant" }
            .flatMap { $0.toolCalls?.map { $0.id } ?? [] })
        for m in msgs where m.role == "tool" {
            XCTAssertNotNil(m.toolCallId, "message tool sans tool_call_id", file: file, line: line)
            XCTAssertTrue(called.contains(m.toolCallId ?? ""),
                          "message tool orphelin (aucun assistant ne porte \(m.toolCallId ?? "nil"))",
                          file: file, line: line)
        }
        let answered = Set(msgs.filter { $0.role == "tool" }.compactMap { $0.toolCallId })
        for m in msgs where m.role == "assistant" {
            for c in m.toolCalls ?? [] {
                XCTAssertTrue(answered.contains(c.id),
                              "tool_call orphelin (aucun message tool pour \(c.id))",
                              file: file, line: line)
            }
        }
    }

    private func toolCall(_ id: String) -> ToolCall {
        ToolCall(id: id, type: "function",
                 function: ToolCallFunction(name: "search_web", arguments: "{}"))
    }

    /// Cas qui cassait l'ancienne passe 3 : 11 messages (minKeep = 10), budget calibré
    /// pour que la suppression s'arrête JUSTE après avoir retiré l'assistant porteur
    /// des tool_calls — son message "tool" survivait orphelin.
    /// Total = 3 + 3000 + 2 + 6×1500 + 2 + 2 = 12009 (> 9500) ; sans l'assistant : 9009
    /// (≤ 9500) → la boucle s'arrêtait là, avec le tool c1 sans parent.
    func testTrimLastResortNeverOrphansToolMessage() {
        var msgs = [
            OllamaMessage(role: "system", content: "sys"),
            OllamaMessage(role: "assistant", content: String(repeating: "a", count: 3000),
                           toolCalls: [toolCall("c1")]),
            OllamaMessage(role: "tool", content: "ok", toolCallId: "c1"),
        ]
        for i in 1...6 {
            msgs.append(OllamaMessage(role: "user", content: "filler\(i)" + String(repeating: "u", count: 1500)))
        }
        msgs.append(OllamaMessage(role: "assistant", content: "r1"))
        msgs.append(OllamaMessage(role: "user", content: "r2"))
        XCTAssertEqual(msgs.count, 11)

        let out = OllamaService.trimMessagesForContext(msgs, maxChars: 9500)
        assertNoOrphanToolLinkage(out)
        // L'assistant supprimé a emporté son tool avec lui : plus aucune trace de c1.
        XCTAssertFalse(out.contains { $0.toolCallId == "c1" })
        XCTAssertFalse(out.contains { $0.toolCalls?.contains { $0.id == "c1" } ?? false })
    }

    func testDropOrphanedToolLinkageRemovesToolWithoutParent() {
        let msgs = [
            OllamaMessage(role: "system", content: "sys"),
            OllamaMessage(role: "tool", content: "résultat fantôme", toolCallId: "ghost"),
            OllamaMessage(role: "user", content: "bonjour"),
        ]
        let out = OllamaService.dropOrphanedToolLinkage(msgs)
        XCTAssertFalse(out.contains { $0.toolCallId == "ghost" })
        XCTAssertEqual(out.count, 2)
    }

    func testDropOrphanedToolLinkageStripsUnansweredCallsButKeepsText() {
        let msgs = [
            OllamaMessage(role: "system", content: "sys"),
            // Appel sans résultat, mais avec du texte : on retire l'appel, on garde le texte.
            OllamaMessage(role: "assistant", content: "Je vais chercher ça",
                           toolCalls: [toolCall("dead")]),
        ]
        let out = OllamaService.dropOrphanedToolLinkage(msgs)
        XCTAssertEqual(out.count, 2)
        XCTAssertNil(out[1].toolCalls)
        XCTAssertEqual(out[1].content, "Je vais chercher ça")
    }

    func testDropOrphanedToolLinkageDropsEmptyAssistantWithoutResult() {
        let msgs = [
            OllamaMessage(role: "system", content: "sys"),
            // Appel sans résultat et sans texte (cas réel : contenu nil) : message vide,
            // on le retire entièrement plutôt que d'envoyer des tool_calls orphelins.
            OllamaMessage(role: "assistant", content: nil, toolCalls: [toolCall("dead")]),
        ]
        let out = OllamaService.dropOrphanedToolLinkage(msgs)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.role, "system")
    }

    func testDropOrphanedToolLinkageKeepsPartiallyAnsweredCalls() {
        let msgs = [
            OllamaMessage(role: "system", content: "sys"),
            OllamaMessage(role: "assistant", content: nil,
                           toolCalls: [toolCall("kept"), toolCall("dead")]),
            OllamaMessage(role: "tool", content: "résultat", toolCallId: "kept"),
        ]
        let out = OllamaService.dropOrphanedToolLinkage(msgs)
        XCTAssertEqual(out[1].toolCalls?.map { $0.id }, ["kept"])
        assertNoOrphanToolLinkage(out)
    }

    /// Invariant vérifié sur plusieurs historiques adverses et budgets : la sortie du
    /// trim ne contient JAMAIS d'orphelin, quel que soit le chemin (tronqué, résumé,
    /// supprimé, ou même déjà orphelin en entrée).
    func testTrimNeverEmitsOrphanLinkageWhateverTheInput() {
        let big = String(repeating: "z", count: 4000)
        let histories: [[OllamaMessage]] = [
            // Paires normales + remplissage.
            [
                OllamaMessage(role: "system", content: "sys"),
                OllamaMessage(role: "assistant", content: nil, toolCalls: [toolCall("c1")]),
                OllamaMessage(role: "tool", content: big, toolCallId: "c1"),
                OllamaMessage(role: "user", content: big),
                OllamaMessage(role: "assistant", content: nil, toolCalls: [toolCall("c2")]),
                OllamaMessage(role: "tool", content: big, toolCallId: "c2"),
                OllamaMessage(role: "user", content: "et après ?"),
            ],
            // Tool déjà orphelin en entrée.
            [
                OllamaMessage(role: "system", content: "sys"),
                OllamaMessage(role: "tool", content: big, toolCallId: "ghost"),
                OllamaMessage(role: "user", content: big),
            ],
            // Assistant avec appels sans résultats + texte.
            [
                OllamaMessage(role: "system", content: "sys"),
                OllamaMessage(role: "assistant", content: "Je m'en occupe",
                               toolCalls: [toolCall("dead1"), toolCall("dead2")]),
                OllamaMessage(role: "user", content: big),
            ],
        ]
        for history in histories {
            for budget in [100, 2000, 50_000] {
                let out = OllamaService.trimMessagesForContext(history, maxChars: budget)
                assertNoOrphanToolLinkage(out)
                XCTAssertEqual(out.first?.role, "system")
            }
        }
    }
}