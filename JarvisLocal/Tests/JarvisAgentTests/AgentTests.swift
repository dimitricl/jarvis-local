import XCTest
@testable import JarvisAgent
@testable import JarvisKit

struct FakeTurn: Sendable {
    var text: String
    var calls: [(name: String, args: JSONValue)]
    var metrics: LLMMetrics?

    init(text: String = "", calls: [(name: String, args: JSONValue)] = [], metrics: LLMMetrics? = nil) {
        self.text = text
        self.calls = calls
        self.metrics = metrics
    }
}

/// LLM scripté : chaque `chat()` joue le tour suivant.
struct FakeLLM: AgentLLM {
    final class Cursor: @unchecked Sendable {
        var index = 0
        let lock = NSLock()
    }

    let turns: [FakeTurn]
    let cursor = Cursor()
    var sleepSeconds: Double = 0
    /// Flux continu de petits deltas (avec micro-pauses) avant le script :
    /// simule le streaming réel pour tester l'annulation à granularité fine.
    var trickleCount: Int = 0

    func chat(messages: [Message], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        let turns = turns
        let cursor = cursor
        let sleepSeconds = sleepSeconds
        let trickleCount = trickleCount
        return AsyncThrowingStream { continuation in
            let task = Task {
                for i in 0..<trickleCount {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    continuation.yield(.textDelta("…\(i)"))
                }
                if sleepSeconds > 0 {
                    try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                }
                try Task.checkCancellation()
                cursor.lock.lock()
                let i = min(cursor.index, turns.count - 1)
                cursor.index += 1
                cursor.lock.unlock()
                let turn = turns[max(0, i)]
                if !turn.text.isEmpty { continuation.yield(.textDelta(turn.text)) }
                if !turn.calls.isEmpty {
                    continuation.yield(.toolCalls(turn.calls.enumerated().map { n, c in
                        ToolCallRef(id: "call-\(n)", name: c.name, arguments: c.args)
                    }))
                }
                continuation.yield(.finished(turn.metrics))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

func echoTool() -> ToolDefinition {
    ToolDefinition(name: "echo", description: "Renvoie le texte.", parameters: .object([:])) { args, _ in
        .success(args["text"])
    }
}

func writeTool() -> ToolDefinition {
    ToolDefinition(
        name: "write_file", description: "Écrit.", parameters: .object([:]),
        isWrite: true
    ) { args, _ in
        .success(JSONValue("écrit \(args["path"].string ?? "?")"))
    }
}

func fetchTool() -> ToolDefinition {
    ToolDefinition(
        name: "web_fetch", description: "Lit une page (non fiable).", parameters: .object([:]),
        producesUntrustedContent: true
    ) { _, _ in
        .success(JSONValue("contenu web non fiable"))
    }
}

func failingTool() -> ToolDefinition {
    ToolDefinition(name: "boom", description: "Rate toujours.", parameters: .object([:])) { _, _ in
        .failure(code: "backend_error", message: "panne simulée", hint: "conclus en échec")
    }
}

func makeLoop(
    turns: [FakeTurn],
    tools: [ToolDefinition] = [echoTool()],
    rules: [PermissionRule]? = nil,
    contextLength: Int? = 100_000,
    confirm: @Sendable @escaping (ToolCallRef, String) async -> Bool = { _, _ in false },
    config: AgentLoop.Config = AgentLoop.Config(),
    todos: TodoStore? = nil,
    transcripts: (any TranscriptStore)? = nil
) -> AgentLoop {
    AgentLoop(
        llm: FakeLLM(turns: turns),
        registry: ToolRegistry(definitions: tools),
        permissions: PermissionEngine(rules: rules ?? PermissionRule.defaults()),
        realContextLength: { contextLength },
        transcripts: transcripts,
        todos: todos,
        config: config,
        confirm: confirm)
}

func collect(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var out: [AgentEvent] = []
    for await e in stream { out.append(e) }
    return out
}

func eventKind(_ e: AgentEvent) -> String {
    switch e {
    case .thinking: return "thinking"
    case .textDelta: return "textDelta"
    case .toolStarted: return "toolStarted"
    case .toolFinished: return "toolFinished"
    case .permissionRequested: return "permissionRequested"
    case .compacted: return "compacted"
    case .done: return "done"
    case .failed: return "failed"
    }
}

final class AgentLoopTests: XCTestCase {
    func testTourSimpleOutilPuisTexte() async {
        let loop = makeLoop(turns: [
            FakeTurn(calls: [(name: "echo", args: .object(["text": .string("hi")]))]),
            FakeTurn(text: "voilà hi")
        ],
        rules: [PermissionRule(toolGlob: "echo", decision: .allow, reason: "test")])
        let events = await collect(loop.run(prompt: "dis hi"))
        XCTAssertEqual(events.map(eventKind), ["toolStarted", "toolFinished", "textDelta", "done"])
        if case .done(let text, let turnsUsed, _) = events.last {
            XCTAssertEqual(text, "voilà hi")
            XCTAssertEqual(turnsUsed, 2)
        } else {
            XCTFail("attendu done")
        }
    }

    func testArretSansAppelOutil() async {
        let loop = makeLoop(turns: [FakeTurn(text: "réponse directe")])
        let events = await collect(loop.run(prompt: "bonjour"))
        XCTAssertEqual(events.map(eventKind), ["textDelta", "done"])
    }

    func testOutilInconnuRefuse() async {
        let loop = makeLoop(turns: [
            FakeTurn(calls: [(name: "nope", args: .object([:]))]),
            FakeTurn(text: "ok sans outil")
        ])
        let events = await collect(loop.run(prompt: "x"))
        XCTAssertTrue(events.contains { eventKind($0) == "toolFinished" })
        XCTAssertEqual(events.map(eventKind).last, "done")
    }

    func testAskConfirmeExecute() async {
        let loop = makeLoop(
            turns: [
                FakeTurn(calls: [(name: "write_file", args: .object(["path": .string("a.txt")]))]),
                FakeTurn(text: "écrit")
            ],
            tools: [writeTool()],
            confirm: { _, _ in true })
        let events = await collect(loop.run(prompt: "écris a"))
        XCTAssertTrue(events.contains {
            if case .permissionRequested(_, _, _, let d) = $0 { return d == .ask }
            return false
        })
        XCTAssertEqual(events.map(eventKind).last, "done")
    }

    func testAskRefuseParDefaut() async {
        let loop = makeLoop(
            turns: [
                FakeTurn(calls: [(name: "write_file", args: .object(["path": .string("a.txt")]))]),
                FakeTurn(text: "bloqué, alternative")
            ],
            tools: [writeTool()])
        let events = await collect(loop.run(prompt: "écris a"))
        if case .done(let text, _, _) = events.last {
            XCTAssertTrue(text.contains("alternative"))
        } else {
            XCTFail("attendu done")
        }
    }

    func testDenyRmRf() async {
        let bash = ToolDefinition(name: "bash", description: "shell", parameters: .object([:])) { _, _ in
            XCTFail("ne doit jamais s'exécuter")
            return .failure(code: "x", message: "x", hint: "x")
        }
        let loop = makeLoop(
            turns: [
                FakeTurn(calls: [(name: "bash", args: .object(["command": .string("rm -rf /")]))]),
                FakeTurn(text: "refusé")
            ],
            tools: [bash])
        let events = await collect(loop.run(prompt: "détruis tout"))
        XCTAssertTrue(events.contains {
            if case .permissionRequested(_, _, _, let d) = $0 { return d == .deny }
            return false
        })
        XCTAssertEqual(events.map(eventKind).last, "done")
    }

    func testTaintEscaladeAllowEnAsk() async {
        // Règles permissives : sans taint, write passe en allow.
        let rules = [PermissionRule(toolGlob: "*", decision: .allow, reason: "test")]
        let loop = makeLoop(
            turns: [
                FakeTurn(calls: [(name: "web_fetch", args: .object(["url": .string("http://x")]))]),
                FakeTurn(calls: [(name: "write_file", args: .object(["path": .string("a")]))]),
                FakeTurn(text: "fini")
            ],
            tools: [fetchTool(), writeTool()],
            rules: rules,
            confirm: { _, _ in true })
        let events = await collect(loop.run(prompt: "lis puis écris"))
        let asks = events.filter {
            if case .permissionRequested(_, let name, _, let d) = $0 { return name == "write_file" && d == .ask }
            return false
        }
        XCTAssertEqual(asks.count, 1)
        if case .permissionRequested(_, _, let reason, _) = asks.first {
            XCTAssertTrue(reason.contains("contaminé"))
        }
    }

    func testExecutionParalleleOrdonnee() async {
        let loop = makeLoop(turns: [
            FakeTurn(calls: [
                (name: "echo", args: .object(["text": .string("un")])),
                (name: "echo", args: .object(["text": .string("deux")]))
            ]),
            FakeTurn(text: "fini")
        ],
        rules: [PermissionRule(toolGlob: "echo", decision: .allow, reason: "test")])
        let events = await collect(loop.run(prompt: "deux echos"))
        let finished = events.filter { eventKind($0) == "toolFinished" }
        XCTAssertEqual(finished.count, 2)
        XCTAssertEqual(events.map(eventKind).last, "done")
    }

    func testMaxTurns() async {
        var turns: [FakeTurn] = []
        for _ in 0..<10 {
            turns.append(FakeTurn(calls: [(name: "echo", args: .object(["text": .string("x")]))]))
        }
        let loop = makeLoop(
            turns: turns,
            rules: [PermissionRule(toolGlob: "echo", decision: .allow, reason: "test")],
            config: AgentLoop.Config(maxTurns: 3, timeoutSeconds: nil))
        let events = await collect(loop.run(prompt: "boucle"))
        if case .failed(let err) = events.last {
            XCTAssertEqual(err, .maxTurnsReached(turns: 3))
        } else {
            XCTFail("attendu maxTurnsReached")
        }
    }

    func testNoProgressApresRepetitions() async {
        let repeatCall = FakeTurn(calls: [(name: "boom", args: .object([:]))])
        let loop = makeLoop(
            turns: [repeatCall, repeatCall, repeatCall, repeatCall],
            tools: [failingTool()],
            rules: [PermissionRule(toolGlob: "boom", decision: .allow, reason: "test")],
            config: AgentLoop.Config(maxTurns: 10, timeoutSeconds: nil, maxIdenticalRepeats: 3))
        let events = await collect(loop.run(prompt: "rate"))
        if case .failed(let err) = events.last {
            if case .noProgress = err { return }
            XCTFail("attendu noProgress, reçu \(err)")
        } else {
            XCTFail("attendu failed")
        }
    }

    func testTimeoutGlobal() async {
        var llm = FakeLLM(turns: [
            FakeTurn(calls: [(name: "echo", args: .object(["text": .string("x")]))]),
            FakeTurn(calls: [(name: "echo", args: .object(["text": .string("x")]))])
        ])
        llm.sleepSeconds = 1
        let loop = AgentLoop(
            llm: llm,
            registry: ToolRegistry(definitions: [echoTool()]),
            permissions: PermissionEngine(rules: [
                PermissionRule(toolGlob: "echo", decision: .allow, reason: "test")
            ]),
            realContextLength: { 100_000 },
            config: AgentLoop.Config(maxTurns: 5, timeoutSeconds: 0.2))
        let events = await collect(loop.run(prompt: "lent"))
        if case .failed(let err) = events.last {
            XCTAssertEqual(err, .timeout)
        } else {
            XCTFail("attendu timeout")
        }
    }

    func testAnnulationPropre() async {
        var llm = FakeLLM(turns: [FakeTurn(text: "jamais")])
        llm.trickleCount = 200
        let loop = AgentLoop(
            llm: llm,
            registry: ToolRegistry(definitions: [echoTool()]),
            realContextLength: { 100_000 },
            config: AgentLoop.Config(timeoutSeconds: nil))
        let stream = await loop.run(prompt: "annule-moi")
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            await loop.cancel()
        }
        let events = await collect(stream)
        if case .failed(let err) = events.last {
            XCTAssertEqual(err, .cancelled)
        } else {
            XCTFail("attendu cancelled, reçu \(events.map(eventKind))")
        }
    }

    func testTranscriptPersisteEtReprend() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-agent-test-\(UUID().uuidString)", isDirectory: true)
        let store = FileTranscriptStore(directory: dir)
        let loop = makeLoop(
            turns: [
                FakeTurn(calls: [(name: "echo", args: .object(["text": .string("a")]))]),
                FakeTurn(text: "premier tour")
            ],
            transcripts: store)
        _ = await collect(loop.run(prompt: "tour 1"))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        let saved = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: dir.appendingPathComponent(files[0])))
        // Transcript COMPLET : tool_calls + tool persistés, pas que du texte.
        XCTAssertTrue(saved.messages.contains { $0.toolCalls?.isEmpty == false })
        XCTAssertTrue(saved.messages.contains { $0.role == .tool })

        // Reprise après « crash » : nouvel acteur, même store.
        let loop2 = makeLoop(
            turns: [FakeTurn(text: "second tour")],
            transcripts: store)
        let events2 = await collect(loop2.run(prompt: "tour 2", resumeFrom: saved.id))
        XCTAssertEqual(events2.map(eventKind).last, "done")
        let reloaded = try await store.load(id: saved.id)
        XCTAssertEqual(reloaded?.messages.filter { $0.role == .user }.count, 2)
    }

    func testCompactionA75Pourcent() async throws {
        let todos = TodoStore()
        await todos.add(title: "relire le bilan")
        // D'abord un tour avec outil pour allonger l'historique, puis pression.
        let loop = makeLoop(
            turns: [
                FakeTurn(calls: [(name: "echo", args: .object(["text": .string("a")]))]),
                FakeTurn(text: "résumé ignoré"),
                FakeTurn(text: "tour final")
            ],
            contextLength: 120,
            config: AgentLoop.Config(timeoutSeconds: nil, keepRecentMessages: 1),
            todos: todos)
        let events = await collect(loop.run(
            prompt: "un très long prompt " + String(repeating: "bla ", count: 200)))
        XCTAssertTrue(events.contains { eventKind($0) == "compacted" },
                      "compaction attendue, reçu \(events.map(eventKind))")
        XCTAssertEqual(events.map(eventKind).last, "done")
    }

    func testRappelDuPlanA60Pourcent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-agent-reminder-\(UUID().uuidString)", isDirectory: true)
        let store = FileTranscriptStore(directory: dir)
        let todos = TodoStore()
        await todos.add(title: "relire le bilan")
        // 2000 ctx : rappel à 1200 tokens, compaction à 1500. Le prompt vise entre les deux.
        let loop = makeLoop(
            turns: [FakeTurn(text: "je continue le plan")],
            contextLength: 2000,
            todos: todos,
            transcripts: store)
        let events = await collect(loop.run(
            prompt: "avance " + String(repeating: "bla ", count: 1100)))
        XCTAssertEqual(events.map(eventKind).last, "done")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let saved = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: dir.appendingPathComponent(files[0])))
        XCTAssertTrue(saved.messages.contains { $0.content?.contains("[rappel]") == true },
                      "rappel du plan attendu dans le transcript")
    }

    func testOutilTodoDeBoutEnBout() async {
        let todos = TodoStore()
        let loop = makeLoop(
            turns: [
                FakeTurn(calls: [(name: "todo", args: .object([
                    "action": .string("add"), "item": .string("écrire le rapport")]))]),
                FakeTurn(text: "tâche notée")
            ],
            tools: [echoTool(), todos.toolDefinition()])
        let events = await collect(loop.run(prompt: "note la tâche"))
        XCTAssertEqual(events.map(eventKind).last, "done")
        let tasks = await todos.all()
        XCTAssertEqual(tasks.map { $0.title }, ["écrire le rapport"])
    }
}

final class BudgetEtPermissionsTests: XCTestCase {
    func testSchemasComptesAuBudget() {
        let est = TokenEstimator()
        let messages = [Message(role: .user, content: "salut")]
        let sans = est.estimate(messages: messages, schemas: [])
        let specs = (1...15).map { i in
            ToolSpec(name: "outil\(i)", description: "fait des choses", parameters: .object([:]))
        }
        let avec = est.estimate(messages: messages, schemas: specs)
        XCTAssertGreaterThan(avec, sans)
        _ = est
    }

    func testCalibrationResserre() {
        var est = TokenEstimator(charsPerToken: 4.0)
        est.calibrate(promptChars: 2000, promptTokens: 1000)
        XCTAssertEqual(est.charsPerToken, 3.0, accuracy: 0.001)
        est.calibrate(promptChars: 0, promptTokens: 0)
        XCTAssertEqual(est.charsPerToken, 3.0, accuracy: 0.001)
    }

    func testSeuilCompaction75() {
        XCTAssertTrue(ContextBudget.needsCompaction(estimatedTokens: 750, realContextLength: 1000))
        XCTAssertFalse(ContextBudget.needsCompaction(estimatedTokens: 749, realContextLength: 1000))
        XCTAssertFalse(ContextBudget.needsCompaction(estimatedTokens: 9999, realContextLength: nil))
        XCTAssertTrue(ContextBudget.needsPlanReminder(estimatedTokens: 600, realContextLength: 1000))
        XCTAssertFalse(ContextBudget.needsPlanReminder(estimatedTokens: 599, realContextLength: 1000))
    }

    func testGlob() {
        XCTAssertTrue(PermissionEngine.globMatch(pattern: "*", text: "nimporte_quoi"))
        XCTAssertTrue(PermissionEngine.globMatch(pattern: "write_*", text: "write_file"))
        XCTAssertFalse(PermissionEngine.globMatch(pattern: "write_*", text: "read_file"))
        XCTAssertTrue(PermissionEngine.globMatch(pattern: "???", text: "abc"))
        XCTAssertFalse(PermissionEngine.globMatch(pattern: "???", text: "abcd"))
    }

    func testPremiereRegleGagne() {
        let engine = PermissionEngine(rules: [
            PermissionRule(toolGlob: "bash", argumentContains: "rm -rf", decision: .deny, reason: "deny"),
            PermissionRule(toolGlob: "bash", decision: .allow, reason: "allow")
        ])
        let denied = engine.evaluate(tool: "bash", arguments: .string("rm -rf /"),
                                     tainted: false, isWrite: false, isNetworkEgress: false)
        XCTAssertEqual(denied.decision, .deny)
        let allowed = engine.evaluate(tool: "bash", arguments: .string("ls"),
                                      tainted: false, isWrite: false, isNetworkEgress: false)
        XCTAssertEqual(allowed.decision, .allow)
    }

    func testDefautAsk() {
        let engine = PermissionEngine(rules: [])
        let v = engine.evaluate(tool: "outil_inconnu", arguments: .null,
                                tainted: false, isWrite: false, isNetworkEgress: false)
        XCTAssertEqual(v.decision, .ask)
    }

    func testPromptSansNomEnDur() {
        let sys = AgentPrompts.system(profile: AgentProfile())
        XCTAssertFalse(sys.contains("Dimitri"))
        XCTAssertFalse(sys.contains(where: { $0.isUppercase }) && sys.contains("JAMAIS"))
        XCTAssertLessThan(sys.components(separatedBy: "\n").count, 40)
        let named = AgentPrompts.system(profile: AgentProfile(displayName: "Ada", facts: ["aime le thé"]))
        XCTAssertTrue(named.contains("Ada"))
    }
}
