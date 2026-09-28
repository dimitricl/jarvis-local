import Foundation
import JarvisKit
import JarvisAgent
import JarvisTools
import JarvisProviders

/// L3 — instance UNIQUE et partagée de l'agent (HUD + fenêtre historique).
///
/// Assemble provider distant, outils, permissions (`permissions.json` +
/// défauts), audit, transcripts et confirmations inline. Le HUD consomme les
/// `AgentEvent` via `HUDReduce` (pur) ; les confirmations reviennent par
/// `answerConfirmation` (Entrée = autoriser, Échap = refuser, « toujours » =
/// règle persistée). Un seul run à la fois : un nouveau run annule le
/// précédent. Échap ×2 ou ré-appui du hotkey = `cancel()` immédiat.
public actor AgentHost {
    public struct Runtime: Sendable {
        public var settings: ShellSettings
        public var mcpSource: (any MCPToolSource)?

        public init(settings: ShellSettings, mcpSource: (any MCPToolSource)? = nil) {
            self.settings = settings
            self.mcpSource = mcpSource
        }
    }

    private let runtime: Runtime
    private let loop: AgentLoop
    private let todos: TodoStore
    private let transcripts: FileTranscriptStore
    private let audit: AuditLog
    private let broker = ConfirmationBroker()
    private let permissionsURL: URL
    private var currentTask: Task<Void, Never>?

    public init(runtime: Runtime) throws {
        self.runtime = runtime
        let settings = runtime.settings
        let base = try OllamaHostPolicy.validateBaseURL(settings.ollamaURL)
        _ = base
        let provider = try OllamaProvider(config: OllamaConfig(
            baseURL: settings.ollamaURL, model: settings.model,
            numCtx: settings.numCtx, temperature: 0.2))
        let home = FileManager.default.homeDirectoryForCurrentUser
        let share = home.appendingPathComponent(".local/share/jarvis", isDirectory: true)
        let transcripts = FileTranscriptStore(directory: share.appendingPathComponent("transcripts", isDirectory: true))
        let audit = AuditLog(file: share.appendingPathComponent("tool_runs.jsonl"))
        let todos = TodoStore()
        let workspace = WorkspaceConfig(root: URL(fileURLWithPath: settings.workspacePath, isDirectory: true))
        let skillsDir = AgentHost.skillsDirectory()
        let (registry, _) = ToolSet.build(config: ToolSetConfig(
            workspace: workspace,
            mac: MacConfig(),
            skillsDirectory: skillsDir,
            todoStore: todos,
            mcpSource: runtime.mcpSource,
            auditLog: audit))
        var full = registry
        if let search = registry.toolSearchDefinition() {
            full = ToolRegistry(definitions: registry.toolNames.compactMap { registry.definition(named: $0) } + [search])
        }
        let (engine, _) = PermissionFile.load(from: PermissionFile.defaultURL())
        let broker = self.broker
        self.loop = AgentLoop(
            llm: provider,
            registry: full,
            permissions: engine,
            realContextLength: { [model = settings.model, base = settings.ollamaURL] in
                await AgentHost.readContextLength(baseURL: base, model: model)
            },
            transcripts: transcripts,
            todos: todos,
            config: AgentLoop.Config(maxTurns: 30, timeoutSeconds: 600),
            confirm: { call, _ in await broker.ask(id: call.id) })
        self.todos = todos
        self.transcripts = transcripts
        self.audit = audit
        self.permissionsURL = PermissionFile.defaultURL()
    }

    // MARK: - Runs

    public func run(prompt: String) -> AsyncStream<AgentEvent> {
        currentTask?.cancel()
        let (stream, continuation) = AsyncStream<AgentEvent>.makeStream()
        currentTask = Task {
            let inner = await loop.run(prompt: prompt)
            for await event in inner {
                if Task.isCancelled { break }
                continuation.yield(event)
            }
            continuation.finish()
        }
        return stream
    }

    public func cancel() {
        currentTask?.cancel()
        Task { await loop.cancel() }
    }

    // MARK: - Confirmations inline

    /// Courtier de confirmations : les continuations vivent ici (pas dans
    /// l'hôte) pour ne pas capturer `self` dans l'init de la boucle.
    actor ConfirmationBroker {
        private var pending: [String: CheckedContinuation<Bool, Never>] = [:]

        func ask(id: String) async -> Bool {
            await withCheckedContinuation { continuation in
                pending[id] = continuation
            }
        }

        func answer(id: String, allowed: Bool) {
            pending.removeValue(forKey: id)?.resume(returning: allowed)
        }
    }

    private func askConfirmation(call: ToolCallRef) async -> Bool {
        await broker.ask(id: call.id)
    }

    /// Réponse du HUD. `always` = persiste une règle `allow` ciblée.
    public func answerConfirmation(callId: String, tool: String, allowed: Bool, always: Bool) {
        if always, allowed {
            persistAllowRule(tool: tool)
        }
        Task { await broker.answer(id: callId, allowed: allowed) }
    }

    private func persistAllowRule(tool: String) {
        let url = permissionsURL
        var file = (try? JSONDecoder().decode(PermissionFile.self, from: Data(contentsOf: url)))
            ?? PermissionFile()
        if !file.rules.contains(where: { $0.tool == tool && $0.decision == .allow }) {
            file.rules.insert(PermissionFileEntry(
                tool: tool, decision: .allow, reason: "toujours autoriser (HUD)"), at: 0)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(file).write(to: url, options: .atomic)
        }
    }

    // MARK: - Préchauffage unique (jamais de ping périodique)

    /// Un seul `/api/generate` avec `keep_alive` long, si le modèle n'est
    /// pas résident. Appelé au lancement et sur événement réseau.
    public static func warmupIfNeeded(baseURL: String, model: String, numCtx: Int) async -> Bool {
        guard let base = try? OllamaHostPolicy.validateBaseURL(baseURL) else { return false }
        var req = URLRequest(url: base.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "model": model, "prompt": "", "keep_alive": "24h",
            "options": ["num_predict": 1, "num_ctx": numCtx] as [String: Any],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        return true
    }

    static func readContextLength(baseURL: String, model: String) async -> Int? {
        guard let base = try? OllamaHostPolicy.validateBaseURL(baseURL) else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("api/ps"))
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return nil }
        return models.first { ($0["name"] as? String ?? "").hasPrefix(model) }?["context_length"] as? Int
    }

    static func skillsDirectory() -> URL? {        let home = FileManager.default.homeDirectoryForCurrentUser
        let user = home.appendingPathComponent(".config/jarvis/skills", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: user.path, isDirectory: &isDir), isDir.boolValue {
            return user
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("skills", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path, isDirectory: &isDir), isDir.boolValue {
            return bundled
        }
        return nil
    }

    public func transcriptStore() -> FileTranscriptStore { transcripts }

    public static func transcriptsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/jarvis/transcripts", isDirectory: true)
    }
}
