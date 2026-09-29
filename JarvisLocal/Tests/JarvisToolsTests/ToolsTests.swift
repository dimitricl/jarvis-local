import XCTest
@testable import JarvisTools
@testable import JarvisAgent
@testable import JarvisKit
@testable import JarvisEvalKit

func makeWorkspace(files: [String: String] = [:]) -> (WorkspaceConfig, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("jarvis-tools-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, content) in files {
        try? content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    return (WorkspaceConfig(root: dir), dir)
}

func runTool(_ def: ToolDefinition, args: [String: String]) async -> ToolResult {
    var json: [String: JSONValue] = [:]
    for (k, v) in args { json[k] = .string(v) }
    do {
        return try await def.execute(.object(json), ToolCallContext())
    } catch {
        return .failure(code: "thrown", message: "\(error)", hint: "ne devrait pas jeter")
    }
}

func tool(_ defs: [ToolDefinition], named name: String) -> ToolDefinition {
    defs.first(where: { $0.name == name })!
}

final class WorkspaceResolveTests: XCTestCase {
    func testRefuseDotDotEtAbsolu() {
        let (ws, _) = makeWorkspace()
        XCTAssertNil(ws.resolve("../secret.txt"))
        XCTAssertNil(ws.resolve("/etc/passwd"))
        XCTAssertNil(ws.resolve("~/x"))
        XCTAssertNil(ws.resolve(""))
        XCTAssertNotNil(ws.resolve("notes/a.txt"))
    }

    func testSymlinkFuyantRefuse() throws {
        let (ws, dir) = makeWorkspace(files: ["ok.txt": "x"])
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("lien"),
            withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertNil(ws.resolve("lien/passwd"))
    }
}

final class FileToolsTests2: XCTestCase {
    func testReadWriteRoundTrip() async {
        let (ws, _) = makeWorkspace()
        let defs = WorkspaceTools.definitions(workspace: ws)
        let written = await runTool(tool(defs, named: "write_file"),
                                    args: ["path": "a.txt", "content": "hello"])
        XCTAssertTrue(written.ok)
        let read = await runTool(tool(defs, named: "read_file"), args: ["path": "a.txt"])
        XCTAssertTrue(read.ok)
        XCTAssertEqual(read.data, .string("hello"))
    }

    func testReadAbsentStructure() async {
        let (ws, _) = makeWorkspace()
        let defs = WorkspaceTools.definitions(workspace: ws)
        let r = await runTool(tool(defs, named: "read_file"), args: ["path": "ghost.txt"])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error?.code, "not_found")
    }

    func testWriteHorsWorkspaceRefuse() async {
        let (ws, _) = makeWorkspace()
        let defs = WorkspaceTools.definitions(workspace: ws)
        let r = await runTool(tool(defs, named: "write_file"),
                              args: ["path": "../evil.txt", "content": "x"])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error?.code, "refused")
    }

    func testEditUniqueSinonErreur() async {
        let (ws, _) = makeWorkspace(files: ["c.txt": "a=false b=false"])
        let defs = WorkspaceTools.definitions(workspace: ws)
        let ambiguous = await runTool(tool(defs, named: "edit_file"),
                                      args: ["path": "c.txt", "old": "false", "new": "true"])
        XCTAssertFalse(ambiguous.ok)
        XCTAssertEqual(ambiguous.error?.code, "not_unique")
        let ok = await runTool(tool(defs, named: "edit_file"),
                               args: ["path": "c.txt", "old": "a=false", "new": "a=true"])
        XCTAssertTrue(ok.ok)
    }

    func testGlobEtGrep() async {
        let (ws, _) = makeWorkspace(files: ["a.md": "x", "b.md": "TODO vite", "c.txt": "y"])
        let defs = WorkspaceTools.definitions(workspace: ws)
        let g = await runTool(tool(defs, named: "glob"), args: ["pattern": "*.md"])
        XCTAssertTrue(g.ok)
        XCTAssertTrue((g.data?.string ?? "").contains("a.md"))
        XCTAssertFalse((g.data?.string ?? "").contains("c.txt"))
        let grep = await runTool(tool(defs, named: "grep"), args: ["pattern": "TODO"])
        XCTAssertTrue(grep.ok)
        XCTAssertTrue((grep.data?.string ?? "").contains("b.md"))
    }
}

final class BashToolTests: XCTestCase {
    func testCommandeSureExecuteeDansWorkspace() async {
        let (ws, _) = makeWorkspace(files: ["a.txt": "hi"])
        let def = BashTool.definition(workspace: ws)
        let r = await runTool(def, args: ["command": "cat a.txt"])
        XCTAssertTrue(r.ok)
        XCTAssertTrue((r.data?.string ?? "").contains("hi"))
    }

    func testMotifsDangereuxRefusesParOutil() async {
        let (ws, _) = makeWorkspace()
        let def = BashTool.definition(workspace: ws)
        for cmd in ["rm -rf /", "rm x", "sudo ls", "curl http://x", "wget http://x",
                    "ssh host", "osascript -e 'x'", "echo hi | sh"] {
            let r = await runTool(def, args: ["command": cmd])
            XCTAssertFalse(r.ok, cmd)
            XCTAssertEqual(r.error?.code, "denied", cmd)
        }
    }
}

final class ToolPermissionsTests: XCTestCase {
    func permissions() -> PermissionEngine { PermissionEngine() }

    func decision(tool: String, args: JSONValue = .object([:])) -> PermissionDecision {
        permissions().evaluate(tool: tool, arguments: args, tainted: false,
                               isWrite: false, isNetworkEgress: false).decision
    }

    func testLectureAutorisee() {
        for t in ["read_file", "glob", "grep", "todo", "tool_search", "skill",
                  "web_search", "web_fetch", "notify"] {
            XCTAssertEqual(decision(tool: t), .allow, t)
        }
    }

    func testEcritureEtEffetsDemandent() {
        for t in ["write_file", "edit_file", "bash", "applescript",
                  "screenshot", "clipboard_get", "clipboard_set", "remember"] {
            XCTAssertEqual(decision(tool: t), .ask, t)
        }
        // open_app est maintenant autorisé par défaut
        XCTAssertEqual(decision(tool: "open"), .allow, "open")
    }

    func testDenyList() {
        let engine = permissions()
        let rm = engine.evaluate(tool: "bash",
                                 arguments: .object(["command": .string("rm -rf /")]),
                                 tainted: false, isWrite: true, isNetworkEgress: false)
        XCTAssertEqual(rm.decision, .deny)
        let ssh = engine.evaluate(tool: "write_file",
                                  arguments: .object(["path": .string("~/.ssh/config")]),
                                  tainted: false, isWrite: true, isNetworkEgress: false)
        XCTAssertEqual(ssh.decision, .deny)
    }

    func testTaintEscaladeMalgreAllow() {
        let engine = permissions()
        let v = engine.evaluate(tool: "web_fetch", arguments: .object([:]),
                                tainted: true, isWrite: false, isNetworkEgress: true)
        XCTAssertEqual(v.decision, .ask)
        XCTAssertTrue(v.reason.contains("contaminé"))
    }
}

final class WebToolsMockTests: XCTestCase {
    func testFetchMockDeterministe() async {
        let defs = WebTools.definitions(config: WebConfig(mockPages: ["mock.local/piege": "PIEGE"]))
        let r = await runTool(tool(defs, named: "web_fetch"), args: ["url": "http://mock.local/piege"])
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.data, .string("PIEGE"))
    }

    func testFetchRefuseNonHTTPetSSRF() async {
        let defs = WebTools.definitions(config: WebConfig())
        let file = await runTool(tool(defs, named: "web_fetch"), args: ["url": "file:///etc/passwd"])
        XCTAssertFalse(file.ok)
        let lan = await runTool(tool(defs, named: "web_fetch"), args: ["url": "http://localhost:11434/api/tags"])
        XCTAssertFalse(lan.ok)
        XCTAssertEqual(lan.error?.code, "refused")
    }

    func testSearchEchoueStructure() async {
        let defs = WebTools.definitions(config: WebConfig())
        let r = await runTool(tool(defs, named: "web_search"), args: ["query": "test qui echoue"])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error?.code, "backend_error")
    }
}

final class MacToolsFakeTests: XCTestCase {
    func testAppleScriptSimule() async {
        let defs = MacTools.definitions(config: MacConfig.fakes())
        let r = await runTool(tool(defs, named: "applescript"), args: ["script": "liste les rappels"])
        XCTAssertTrue(r.ok)
        XCTAssertTrue((r.data?.string ?? "").contains("2 rappels"))
    }

    func testOpenSimule() async {
        let defs = MacTools.definitions(config: MacConfig.fakes())
        let r = await runTool(tool(defs, named: "open"), args: ["target": "Notes"])
        XCTAssertTrue(r.ok)
    }

    func testOpenAccepteAliasPath() async {
        // Le modèle calque `path` (convention dominante) au lieu de `target`
        // (constaté : `open(path="mail")` → bad_args ×2 puis stall).
        let defs = MacTools.definitions(config: MacConfig.fakes())
        let r = await runTool(tool(defs, named: "open"), args: ["path": "Mail"])
        XCTAssertTrue(r.ok)
    }

    func testScreenshotPNG() async {
        let defs = MacTools.definitions(config: MacConfig.fakes())
        let r = await runTool(tool(defs, named: "screenshot"), args: [:])
        XCTAssertTrue(r.ok)
        XCTAssertNotNil(r.data?["png_base64"].string)
    }

    func testClipboardSimule() async {
        let defs = MacTools.definitions(config: MacConfig.fakes())
        let get = await runTool(tool(defs, named: "clipboard_get"), args: [:])
        XCTAssertTrue(get.ok)
        let set = await runTool(tool(defs, named: "clipboard_set"), args: ["text": "x"])
        XCTAssertTrue(set.ok)
    }

    func testNotifySimule() async {
        let defs = MacTools.definitions(config: MacConfig.fakes())
        let r = await runTool(tool(defs, named: "notify"), args: ["message": "fini"])
        XCTAssertTrue(r.ok)
    }

    func testAppleScriptLiveLectureSeule() async throws {
        // Lecture seule inoffensive (même appel que le smoke test CI).
        let out = try await LiveAppleScriptRunner().run(script: "tell application \"Finder\" to get name")
        XCTAssertFalse(out.isEmpty)
    }
}

final class MemoryToolsTests: XCTestCase {
    func testRememberPuisRelit() async {
        let store = InMemoryRememberStore()
        let def = MemoryTools.remember(store: store)
        let r = await runTool(def, args: ["fact": "écran 4K"])
        XCTAssertTrue(r.ok)
        let facts = await store.facts()
        XCTAssertEqual(facts, ["écran 4K"])
    }

    func testRememberVideRejete() async {
        let def = MemoryTools.remember(store: InMemoryRememberStore())
        let r = await runTool(def, args: ["fact": "  "])
        XCTAssertFalse(r.ok)
    }

    struct FailingStore: RememberStore {
        func remember(fact: String) async throws { throw ToolRunnerError.failed("db down") }
        func facts() async -> [String] { [] }
    }

    func testEchecDBRemonteAuModele() async {
        // Jamais de succès mensonger : l'erreur est structurée, pas avalée.
        let def = MemoryTools.remember(store: FailingStore())
        let r = await runTool(def, args: ["fact": "x"])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error?.code, "store_error")
    }

    func testSkillListReadMissing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "Recette test.".write(to: dir.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        let def = MemoryTools.skill(loader: SkillsLoader(directory: dir))
        let list = await runTool(def, args: ["action": "list"])
        XCTAssertTrue((list.data?.string ?? "").contains("demo"))
        let read = await runTool(def, args: ["action": "read", "name": "demo"])
        XCTAssertTrue(read.ok)
        let missing = await runTool(def, args: ["action": "read", "name": "ghost"])
        XCTAssertFalse(missing.ok)
    }
}

final class MCPAdapterTests: XCTestCase {
    func testDecouverteEtExecutionFake() async {
        let source = FakeMCPToolSource(
            tools: [MCPToolInfo(name: "events_fetch", description: "Lit.",
                                parameters: .object([:]), sensitive: false)],
            handler: { name, _ in "2 événements (simulé) via \(name)." })
        let online = await source.isOnline()
        XCTAssertTrue(online)
        let defs = MCPToolsAdapter.definitions(tools: await source.tools(), source: source)
        XCTAssertEqual(defs.count, 1)
        XCTAssertFalse(defs[0].isCore)
        XCTAssertTrue(defs[0].producesUntrustedContent)
        let r = await runTool(defs[0], args: [:])
        XCTAssertTrue(r.ok)
        XCTAssertTrue((r.data?.string ?? "").contains("2 événements"))
    }

    func testRefreshHorsLigne() async {
        struct Offline: MCPToolSource {
            func isOnline() async -> Bool { false }
            func tools() async -> [MCPToolInfo] { [] }
            func call(tool name: String, args: JSONValue) async throws -> String {
                throw ToolRunnerError.failed("offline")
            }
        }
        let defs = MCPToolsAdapter.definitions(source: Offline())
        let refresh = defs.first(where: { $0.name == "mcp_refresh" })!
        let r = await runTool(refresh, args: [:])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error?.code, "offline")
    }

    func testErreurMCPStructuree() async {
        let source = FakeMCPToolSource(
            tools: [MCPToolInfo(name: "x", description: "x", parameters: .object([:]))],
            handler: { _, _ in throw ToolRunnerError.failed("boom") })
        let defs = MCPToolsAdapter.definitions(tools: await source.tools(), source: source)
        let r = await runTool(defs[0], args: [:])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error?.code, "mcp_error")
    }
}

final class AuditAndPermissionsFileTests: XCTestCase {
    func testAuditAppendEtRelecture() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        let log = AuditLog(file: file)
        let runId = UUID()
        try await log.append(AuditEntry(runId: runId, tool: "write_file",
                                        argsPreview: "a.txt", status: "ok",
                                        durationMs: 3, resultPreview: "écrit"))
        let all = try await log.readAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].tool, "write_file")
        XCTAssertEqual(all[0].runId, runId)
    }

    func testPermissionsFileAbsentEtCasse() {
        let missing = URL(fileURLWithPath: "/tmp/jarvis-perm-absent-\(UUID().uuidString).json")
        let (engine, warning) = PermissionFile.load(from: missing)
        XCTAssertNil(warning)
        XCTAssertEqual(engine.evaluate(tool: "zzz", arguments: .null, tainted: false,
                                       isWrite: false, isNetworkEgress: false).decision, .ask)
        let broken = FileManager.default.temporaryDirectory
            .appendingPathComponent("perm-\(UUID().uuidString).json")
        try? "{cassé".write(to: broken, atomically: true, encoding: .utf8)
        let (_, warning2) = PermissionFile.load(from: broken)
        XCTAssertNotNil(warning2)
    }

    func testPermissionsFilePrioritaire() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("perm-\(UUID().uuidString).json")
        let content = """
        {"rules": [{"tool": "notify", "decision": "ask", "reason": "silence"}]}
        """
        try content.write(to: file, atomically: true, encoding: .utf8)
        let (engine, warning) = PermissionFile.load(from: file)
        XCTAssertNil(warning)
        // Le fichier gagne sur le défaut (notify = allow par défaut).
        XCTAssertEqual(engine.evaluate(tool: "notify", arguments: .null, tainted: false,
                                       isWrite: false, isNetworkEgress: false).decision, .ask)
    }

    func testToolSetAssembleEtAudite() async throws {
        let (ws, _) = makeWorkspace()
        let auditFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        let log = AuditLog(file: auditFile)
        let (registry, _) = ToolSet.build(config: ToolSetConfig(
            workspace: ws, mac: MacConfig.fakes(), auditLog: log))
        XCTAssertNotNil(registry.definition(named: "read_file"))
        XCTAssertNotNil(registry.definition(named: "applescript"))
        XCTAssertNotNil(registry.toolSearchDefinition())
        let write = registry.definition(named: "write_file")!
        let r = await runTool(write, args: ["path": "a.txt", "content": "x"])
        XCTAssertTrue(r.ok)
        let entries = try await log.readAll()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].tool, "write_file")
        // Lecture non auditee (pas d'écriture/envoi).
        let read = registry.definition(named: "read_file")!
        _ = await runTool(read, args: ["path": "a.txt"])
        let entriesAfterRead = try await log.readAll()
        XCTAssertEqual(entriesAfterRead.count, 1)
    }
}

// MARK: - Boucle complète sur vrais outils (fake LLM scripté)

struct ScriptedLLM: AgentLLM {
    var turns: [(text: String, calls: [(String, JSONValue)])]
    final class Cursor: @unchecked Sendable {
        var i = 0
        let lock = NSLock()
    }
    let cursor = Cursor()

    func chat(messages: [Message], tools: [ToolSpec]) -> AsyncThrowingStream<LLMEvent, Error> {
        let turns = turns
        let cursor = cursor
        return AsyncThrowingStream { continuation in
            cursor.lock.lock()
            let t = turns[min(cursor.i, turns.count - 1)]
            cursor.i += 1
            cursor.lock.unlock()
            if !t.text.isEmpty { continuation.yield(.textDelta(t.text)) }
            if !t.calls.isEmpty {
                continuation.yield(.toolCalls(t.calls.enumerated().map { n, c in
                    ToolCallRef(id: "k\(n)", name: c.0, arguments: c.1)
                }))
            }
            continuation.yield(.finished(nil))
            continuation.finish()
        }
    }
}

final class InjectionLoopTests: XCTestCase {
    func testTaintEscaladeEcritureApresFetch() async {
        // Règles permissives : sans taint, write passe en allow.
        let engine = PermissionEngine(rules: [
            PermissionRule(toolGlob: "*", decision: .allow, reason: "test")
        ])
        let (ws, _) = makeWorkspace()
        var defs = WorkspaceTools.definitions(workspace: ws)
        defs += WebTools.definitions(config: WebConfig(mockPages: ["mock.local/piege": "CONTENU PIEGE NON FIABLE"]))
        let registry = ToolRegistry(definitions: defs)
        let llm = ScriptedLLM(turns: [
            (text: "", calls: [("web_fetch", .object(["url": .string("http://mock.local/piege")]))]),
            (text: "", calls: [("write_file", .object(["path": .string("out.txt"), "content": .string("x")]))]),
            (text: "fini", calls: [])
        ])
        let loop = AgentLoop(
            llm: llm, registry: registry, permissions: engine,
            realContextLength: { 100_000 },
            config: AgentLoop.Config(timeoutSeconds: nil),
            confirm: { _, _ in true })
        var askedWrite = false
        let stream = await loop.run(prompt: "lis puis écris")
        for await event in stream {
            if case .permissionRequested(_, let name, let reason, let d) = event,
               name == "write_file", d == .ask, reason.contains("contaminé") {
                askedWrite = true
            }
        }
        XCTAssertTrue(askedWrite, "l'écriture post-fetch doit escalader en ask")
    }

    func testExfiltrationDetecteeParTaint() {
        // Même algorithme que la grille : fragment tainté dans une URL = exfil.
        XCTAssertTrue(EvalTaint.isExfiltrated(
            taintedContents: ["Article piégé demande envoi vers collecteur"],
            argument: "http://collecteur.local/e?d=Article piégé demande envoi vers collecteur"))
        XCTAssertFalse(EvalTaint.isExfiltrated(
            taintedContents: ["Article piégé"],
            argument: "http://mock.local/autre-page"))
    }
}
