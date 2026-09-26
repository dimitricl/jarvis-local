import Foundation
import JarvisCore

/// Coordinateur de gestion des conversations (extraits d'AppViewModel).
/// `DatabaseProtocol` est l'alias pour `PersistentStore` dans JarvisCore.
typealias DatabaseProtocol = PersistentStore
/// Responsabilité unique : logique cycle de vie conversations + recherche + export.
/// L'état observable reste dans AppViewModel ; ce coordinateur opère via callbacks.
@MainActor
public final class ConversationCoordinator {
    // MARK: - Dépendances

    private let db: any DatabaseProtocol
    private let onError: (String) -> Void
    private let onConversationChange: (Conversation?) -> Void
    private let onConversationsChange: ([Conversation]) -> Void
    private let onSearchResultsChange: ([AppViewModel.SearchResultEntry]) -> Void
    private let onSearchingChange: (Bool) -> Void
    private let getMessages: () -> [Message]
    private let getCurrentConversation: () -> Conversation?
    private let getConversations: () -> [Conversation]

    /// Crée le coordinateur.
    /// - Parameters:
    ///   - db: Base de données pour persistance.
    ///   - onError: Callback pour reporter les erreurs.
    ///   - onConversationChange: Appelé quand `currentConversation` change.
    ///   - onConversationsChange: Appelé quand la liste `conversations` change (reçoit le NOUVEL array).
    ///   - onSearchResultsChange: Appelé quand les résultats de recherche changent.
    ///   - onSearchingChange: Appelé quand l'état de recherche change.
    ///   - getMessages: Fournit les messages actuels pour l'export.
    ///   - getCurrentConversation: Fournit la conversation courante pour l'export.
    ///   - getConversations: Fournit la liste actuelle des conversations pour les mutations locales.
    init(
        db: any DatabaseProtocol,
        onError: @escaping (String) -> Void,
        onConversationChange: @escaping (Conversation?) -> Void,
        onConversationsChange: @escaping ([Conversation]) -> Void,
        onSearchResultsChange: @escaping ([AppViewModel.SearchResultEntry]) -> Void,
        onSearchingChange: @escaping (Bool) -> Void,
        getMessages: @escaping () -> [Message],
        getCurrentConversation: @escaping () -> Conversation?,
        getConversations: @escaping () -> [Conversation]
    ) {
        self.db = db
        self.onError = onError
        self.onConversationChange = onConversationChange
        self.onConversationsChange = onConversationsChange
        self.onSearchResultsChange = onSearchResultsChange
        self.onSearchingChange = onSearchingChange
        self.getMessages = getMessages
        self.getCurrentConversation = getCurrentConversation
        self.getConversations = getConversations
    }

    // MARK: - Cycle de vie conversations

    /// Charge toutes les conversations et sélectionne la première si aucune n'est active.
    func loadConversations() async {
        do {
            let convs = try await db.getAllConversations()
            onConversationsChange(convs)
            if getCurrentConversation() == nil, let first = convs.first {
                await selectConversation(first)
            }
        } catch {
            onError("Erreur chargement conversations : \(error.localizedDescription)")
        }
    }

    /// Sélectionne une conversation et charge ses messages.
    func selectConversation(_ conv: Conversation) async {
        onConversationChange(conv)
        await loadMessages()
    }

    /// Crée une nouvelle conversation et la sélectionne.
    func newConversation() async {
        do {
            let conv = try await db.createConversation()
            // Insère au début (comportement identique à l'ancien VM) pour éviter un rechargement complet
            // qui pourrait ramener des conversations dans un ordre différent.
            let updated = [conv] + getConversations()
            onConversationsChange(updated)
            await selectConversation(conv)
        } catch {
            onError("Erreur création conversation : \(error.localizedDescription)")
        }
    }

    /// Supprime une conversation. Si c'était la courante, sélectionne la suivante.
    func deleteConversation(_ conv: Conversation) async {
        do {
            try await db.deleteConversation(id: conv.id)
            // Met à jour localement (comportement identique à l'ancien VM) pour éviter
            // un rechargement DB qui peut avoir des problèmes de visibilité sur :memory:.
            let updated = getConversations().filter { $0.id != conv.id }
            onConversationsChange(updated)
            if getCurrentConversation()?.id == conv.id {
                let next = updated.first
                onConversationChange(next)
                await loadMessages()
            }
        } catch {
            onError("Erreur suppression : \(error.localizedDescription)")
        }
    }

    /// Renomme une conversation.
    func renameConversation(id: Int, title: String) async {
        do {
            try await db.updateConversationTitle(id: id, title: title)
            // Met à jour localement (comportement identique à l'ancien VM) pour éviter
            // un rechargement DB qui peut avoir des problèmes de visibilité sur :memory:.
            let updated = getConversations().map { c in
                var copy = c
                if copy.id == id { copy.title = title }
                return copy
            }
            onConversationsChange(updated)
            if var current = getCurrentConversation(), current.id == id {
                current.title = title
                onConversationChange(current)
            }
        } catch {
            onError("Erreur renommage : \(error.localizedDescription)")
        }
    }

    // MARK: - Messages

    /// Charge les messages de la conversation courante.
    /// Note: le VM met à jour son tableau `messages` via son propre `loadMessages()`.
    /// Ce coordinateur ne fait que la lecture DB.
    func loadMessages() async {
        guard let cid = getCurrentConversation()?.id else { return }
        do {
            _ = try await db.getMessages(conversationId: cid)
        } catch {
            onError("Erreur chargement messages : \(error.localizedDescription)")
        }
    }

    // MARK: - Recherche

    /// Recherche plein-texte dans toutes les conversations.
    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        onSearchingChange(!trimmed.isEmpty)
        guard !trimmed.isEmpty else {
            onSearchResultsChange([])
            return
        }
        do {
            let results = try await db.searchMessages(trimmed)
            let entries = results.map { r in
                AppViewModel.SearchResultEntry(
                    id: r.message.id,
                    role: r.message.role,
                    content: r.message.content,
                    conversationTitle: r.conversationTitle,
                    conversationId: r.message.conversationId
                )
            }
            onSearchResultsChange(entries)
        } catch {
            onError("Erreur recherche : \(error.localizedDescription)")
        }
    }

    // MARK: - Export

    /// Exporte la conversation courante en Markdown.
    func exportConversationAsMarkdown() -> String? {
        guard let conv = getCurrentConversation() else { return nil }
        let messages = getMessages()
        guard !messages.isEmpty else { return nil }

        let df = DateFormatter()
        df.dateFormat = "dd/MM/yyyy HH:mm"
        var out = "# \(conv.title)\n\n"
        for msg in messages {
            let who = msg.role == "user" ? "Vous" : "Jarvis"
            out += "**\(who)** — \(df.string(from: msg.createdAt))\n\n\(msg.content)\n\n---\n\n"
        }
        return out
    }

    /// Exporte la conversation courante en JSON.
    func exportConversationAsJSON() -> String? {
        guard let conv = getCurrentConversation() else { return nil }
        let messages = getMessages()
        guard !messages.isEmpty else { return nil }

        let df = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "title": conv.title,
            "exported_at": df.string(from: Date()),
            "messages": messages.map { m in
                ["role": m.role, "content": m.content, "created_at": df.string(from: m.createdAt)]
            }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}