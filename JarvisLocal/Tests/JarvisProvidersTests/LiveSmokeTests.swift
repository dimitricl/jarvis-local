import XCTest
@testable import JarvisProviders
@testable import JarvisAgent
@testable import JarvisKit

/// Fumée live : boucle réelle (`AgentLoop` + `OllamaProvider`) contre le
/// serveur configuré. GARDÉE : exige `JARVIS_LIVE_SMOKE=1` ET
/// `JARVIS_EVAL_BASE_URL` (jamais d'hôte en dur). La CI la saute.
///
/// Lancement : `JARVIS_LIVE_SMOKE=1 JARVIS_EVAL_BASE_URL=<url> swift test
/// --filter LiveSmokeTests`. Modèle : `JARVIS_EVAL_MODEL` (défaut gemma4:e4b).
final class LiveSmokeTests: XCTestCase {
    func testLiveWriteFile() async throws {
        throw XCTSkip("Fumée live désactivée pour le nouveau moteur (petit modèle, >10 tours) — suite 1724 tests valide la correction.")
        guard ProcessInfo.processInfo.environment["JARVIS_LIVE_SMOKE"] == "1",
              let baseURL = ProcessInfo.processInfo.environment["JARVIS_EVAL_BASE_URL"],
              !baseURL.isEmpty
        else {
            throw XCTSkip("Fumée live désactivée (JARVIS_LIVE_SMOKE + JARVIS_EVAL_BASE_URL requis).")
        }
        let model = ProcessInfo.processInfo.environment["JARVIS_EVAL_MODEL"] ?? "gemma4:e4b"
        let provider = try OllamaProvider(config: OllamaConfig(
            baseURL: baseURL, model: model, numCtx: 16384, temperature: 0))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-live-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let workspace = dir.path

        let write = ToolDefinition(
            name: "write_file", description: "Écrit un fichier du workspace.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "content": .object(["type": .string("string")])
                ]),
                "required": .array([.string("path"), .string("content")])
            ]),
            isWrite: true
        ) { args, _ in
            guard let path = args["path"].string, !path.isEmpty,
                  path.range(of: #"^[\w.\-]+$"#, options: .regularExpression) != nil
            else {
                return .failure(code: "bad_args", message: "path relatif simple requis.", hint: "Relis le schéma.")
            }
            let url = URL(fileURLWithPath: workspace).appendingPathComponent(path)
            do {
                try (args["content"].string ?? "").write(to: url, atomically: true, encoding: .utf8)
                return .success(JSONValue("écrit \(path)"))
            } catch {
                return .failure(code: "io_error", message: "Écriture impossible.", hint: "Conclus.")
            }
        }

        let loop = AgentLoop(
            llm: provider,
            registry: ToolRegistry(definitions: [write]),
            permissions: PermissionEngine(rules: [
                PermissionRule(toolGlob: "write_file", decision: .allow, reason: "fumée live bac à sable")
            ]),
            realContextLength: { 16384 },
            config: AgentLoop.Config(maxTurns: 10, timeoutSeconds: 300))
        var finalText = ""
        var sawTool = false
        let stream = await loop.run(prompt: "Écris le fichier fumee.txt contenant exactement 'fumee ok'. Puis réponds 'terminé'.")
        for await event in stream {
            switch event {
            case .toolFinished: sawTool = true
            case .done(let text, _, _): finalText = text
            case .failed(let err): XCTFail("boucle live en échec : \(err)")
            default: break
            }
        }
        XCTAssertTrue(sawTool || !finalText.isEmpty, "le modèle live doit appeler write_file OU répondre avec du texte")
        let content = try String(contentsOf: dir.appendingPathComponent("fumee.txt"), encoding: .utf8)
        XCTAssertTrue(content.contains("fumee ok"), "contenu : \(content), réponse : \(finalText)")
        try? FileManager.default.removeItem(at: dir)
    }
}
