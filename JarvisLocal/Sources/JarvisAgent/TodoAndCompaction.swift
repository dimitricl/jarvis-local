import Foundation
import JarvisKit

/// L1 — liste de tâches tenue par le modèle + rappel du plan.
///
/// Le modèle met à jour ses tâches via l'outil `todo` ; quand le contexte
/// est sous pression, le résumé des tâches ouvertes est maintenu visible
/// (« rappel du plan en fin de contexte »).
public actor TodoStore {
    public struct Task: Sendable, Codable, Equatable {
        public var title: String
        public var done: Bool

        public init(title: String, done: Bool = false) {
            self.title = title
            self.done = done
        }
    }

    private var tasks: [Task] = []

    public init() {}

    public func add(title: String) {
        tasks.append(Task(title: title))
    }

    public func markDone(title: String) {
        if let i = tasks.firstIndex(where: { $0.title == title }) {
            tasks[i].done = true
        }
    }

    public func all() -> [Task] { tasks }

    public func openSummary() -> String? {
        let open = tasks.filter { !$0.done }
        guard !open.isEmpty else { return nil }
        return "Plan en cours (" + open.map { "… " + $0.title }.joined(separator: " ") + ")"
    }

    /// Définition de l'outil `todo` câblée sur ce store.
    public nonisolated func toolDefinition() -> ToolDefinition {
        ToolDefinition(
            name: "todo",
            description: "Tient ta liste de tâches : add, done ou list.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object(["type": .string("string"), "description": .string("add, done ou list")]),
                    "item": .object(["type": .string("string"), "description": .string("libellé")]),
                ]),
                "required": .array([.string("action")]),
            ])
        ) { args, _ in
            let action = args["action"].string?.lowercased() ?? "list"
            let item = args["item"].string ?? ""
            switch action {
            case "add":
                guard !item.isEmpty else {
                    return .failure(code: "bad_args", message: "Paramètre 'item' manquant pour add.", hint: "Relis le schéma.")
                }
                await self.add(title: item)
                let count = await self.all().count
                return .success(JSONValue("Tâche ajoutée (\(count) au total)."))
            case "done":
                await self.markDone(title: item)
                return .success(JSONValue("Tâche soldée."))
            default:
                let list = await self.all()
                if list.isEmpty { return .success(JSONValue("Liste vide.")) }
                let text = list.map { ($0.done ? "✓ " : "… ") + $0.title }.joined(separator: "\n")
                return .success(JSONValue(text))
            }
        }
    }
}

/// L1 — compaction par RÉSUMÉ (jamais de troncature aveugle).
///
/// Quand le budget dépasse 75 % du contexte réel : les messages anciens
/// (hors système + N récents) sont résumés par le LLM et remplacés par un
/// message de résumé marqué. Le résumé des tâches ouvertes est conservé.
public struct Compactor: Sendable {
    public var keepRecentMessages: Int
    public var summarizerSystemPrompt: String

    public init(
        keepRecentMessages: Int = 6,
        summarizerSystemPrompt: String = "Résume fidèlement cet historique de travail en 10 lignes max : actions faites, résultats obtenus, sans inventer."
    ) {
        self.keepRecentMessages = keepRecentMessages
        self.summarizerSystemPrompt = summarizerSystemPrompt
    }

    public func compact(
        messages: [Message],
        todoSummary: String?,
        llm: any AgentLLM
    ) async throws -> (messages: [Message], freedChars: Int) {
        guard messages.count > keepRecentMessages + 1 else { return (messages, 0) }
        let head = Array(messages.prefix(1))
        let tail = Array(messages.suffix(keepRecentMessages))
        let middle = Array(messages.dropFirst().dropLast(keepRecentMessages))
        guard !middle.isEmpty else { return (messages, 0) }

        let digest = middle.map { m in
            "[\(m.role.rawValue)] \((m.content ?? "").prefix(800))\(m.toolCalls.map { " + \($0.count) appels" } ?? "")"
        }.joined(separator: "\n")

        var summary = ""
        let stream = llm.chat(
            messages: [
                Message(role: .system, content: summarizerSystemPrompt),
                Message(role: .user, content: digest),
            ],
            tools: []
        )
        for try await event in stream {
            if case .textDelta(let d) = event { summary += d }
        }
        // Même conversion silence → annulation que dans la boucle principale.
        try Task.checkCancellation()
        let before = messages.reduce(0) { $0 + $1.approxChars }
        var out = head
        var resumeText = "[contexte précédent résumé] " + summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if let todo = todoSummary, !todo.isEmpty {
            resumeText += "\n" + todo
        }
        out.append(Message(role: .user, content: resumeText))
        out.append(contentsOf: tail)
        let after = out.reduce(0) { $0 + $1.approxChars }
        return (out, max(0, before - after))
    }
}
