import Foundation
import JarvisKit
import JarvisAgent
import JarvisServices

/// L2 — fabrique : assemble registre + stores pour un run.
///
/// Noyau exposé par défaut (fichiers, bash, web, todo, remember, skill) ;
/// étendus via `tool_search` (applescript, open, screenshot, presse-papiers,
/// notify, edit_file, MCP). Chaque outil d'écriture/envoi est audité et
/// couvert par au moins un test de permission (cf. JarvisToolsTests).
public struct ToolSetConfig: Sendable {
    public var workspace: WorkspaceConfig
    public var web: WebConfig
    public var mac: MacConfig
    public var skillsDirectory: URL?
    public var rememberStore: any RememberStore
    public var todoStore: TodoStore
    public var mcpSource: (any MCPToolSource)?
    public var auditLog: AuditLog?
    public var runId: UUID

    public init(
        workspace: WorkspaceConfig,
        web: WebConfig = WebConfig(),
        mac: MacConfig = MacConfig(),
        skillsDirectory: URL? = nil,
        rememberStore: any RememberStore = InMemoryRememberStore(),
        todoStore: TodoStore = TodoStore(),
        mcpSource: (any MCPToolSource)? = nil,
        auditLog: AuditLog? = nil,
        runId: UUID = UUID()
    ) {
        self.workspace = workspace
        self.web = web
        self.mac = mac
        self.skillsDirectory = skillsDirectory
        self.rememberStore = rememberStore
        self.todoStore = todoStore
        self.mcpSource = mcpSource
        self.auditLog = auditLog
        self.runId = runId
    }
}

public enum ToolSet {
    public static func build(config: ToolSetConfig) -> (registry: ToolRegistry, todos: TodoStore) {
        var definitions: [ToolDefinition] = []
        definitions += WorkspaceTools.definitions(workspace: config.workspace)
        definitions.append(BashTool.definition(workspace: config.workspace))
        definitions += WebTools.definitions(config: config.web)
        definitions.append(config.todoStore.toolDefinition())
        definitions.append(MemoryTools.remember(store: config.rememberStore))
        if let skillsDir = config.skillsDirectory {
            definitions.append(MemoryTools.skill(loader: SkillsLoader(directory: skillsDir)))
        }
        definitions += MacTools.definitions(config: config.mac)
        if let mcp = config.mcpSource {
            definitions += MCPToolsAdapter.definitions(source: mcp)
        }
        if let search = ToolRegistry(definitions: definitions).toolSearchDefinition() {
            definitions.append(search)
        }
        if let log = config.auditLog {
            let runId = config.runId
            definitions = definitions.map { def in
                (def.isWrite || def.isNetworkEgress) ? AuditedTool.wrap(def, log: log, runId: runId) : def
            }
        }
        return (ToolRegistry(definitions: definitions), config.todoStore)
    }
}
