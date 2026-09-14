import Foundation
import SQLite3

// SQLITE_TRANSIENT (-1) : demande à SQLite de COPIER la chaîne liée avant le retour
// de sqlite3_bind_text. Sans ça (nil = SQLITE_STATIC), SQLite garde le pointeur tel quel
// et le déréférence plus tard au sqlite3_step — or ici le pointeur vient d'un NSString
// temporaire ((value as NSString).utf8String) qui peut être libéré entre-temps, d'où un
// risque réel de corruption / crash sur les chaînes longues ou unicode.
// Référence : https://www.sqlite.org/c3ref/c_static.html
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor DatabaseService {
    static let shared = DatabaseService()
    private var db: OpaquePointer?

    private init() {}

    private func dbPath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("JarvisLocal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.db")
    }

    func open(path: String? = nil) throws {
        let resolvedPath = path ?? dbPath().path
        let rc = sqlite3_open(resolvedPath, &db)
        if rc != SQLITE_OK {
            throw DatabaseError.couldNotOpen(message: String(cString: sqlite3_errmsg(db)))
        }
        // WAL : lecteurs ne bloquent plus l'écrivain (tour de conversation + UI) ;
        // FOREIGN KEYS : refermet la porte aux orphelins (appliqué à chaque open,
        // SQLite ne le persiste pas). synchronous=NORMAL = compromis WAL standard.
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA synchronous=NORMAL")
        try migrate()
    }

    private func migrate() throws {
        // Migrations versionnées via PRAGMA user_version (persisté par SQLite) :
        // chaque palier ne s'exécute qu'une fois, dans l'ordre. AVANT : que des
        // CREATE IF NOT EXISTS — impossible d'écrire une vraie migration
        // (ALTER, backfill, purge) sans risquer de la rejouer ou de l'oublier.
        // Schéma actuel : v1 = tables initiales, v2 = index + purge orphelins.
        var version = try userVersion()
        if version < 1 {
            try migrateToV1()
            version = 1
            try setUserVersion(version)
        }
        if version < 2 {
            try migrateToV2()
            version = 2
            try setUserVersion(version)
        }
    }

    /// NOTE : `internal` pour les tests (vérifie la version après open).
    func userVersion() throws -> Int {
        guard let db else { throw DatabaseError.couldNotOpen(message: "Database not opened") }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) != SQLITE_OK {
            throw DatabaseError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DatabaseError.stepFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func setUserVersion(_ version: Int) throws {
        try exec("PRAGMA user_version = \(version)")
    }

    private func migrateToV1() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS conversations (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                title      TEXT    NOT NULL DEFAULT 'Nouvelle conversation',
                created_at INTEGER DEFAULT (unixepoch()),
                updated_at INTEGER DEFAULT (unixepoch())
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS messages (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                role            TEXT    NOT NULL,
                content         TEXT    NOT NULL,
                conversation_id INTEGER REFERENCES conversations(id),
                created_at      INTEGER DEFAULT (unixepoch())
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS facts (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                key        TEXT    UNIQUE,
                value      TEXT,
                updated_at INTEGER DEFAULT (unixepoch())
            )
        """)
        try exec("""
            CREATE TABLE IF NOT EXISTS tool_runs (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_id INTEGER REFERENCES conversations(id) ON DELETE CASCADE,
                tool            TEXT    NOT NULL,
                args            TEXT    NOT NULL DEFAULT '',
                status          TEXT    NOT NULL DEFAULT '',
                result          TEXT    NOT NULL DEFAULT '',
                created_at      INTEGER DEFAULT (unixepoch())
            )
        """)
        // Index du chemin chaud getMessages(conversation_id) : sans lui, chaque tour
        // scannait toute la table messages. Idempotent (IF NOT EXISTS).
        try exec("CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id)")
        try exec("CREATE INDEX IF NOT EXISTS idx_tool_runs_conversation ON tool_runs(conversation_id)")
        let count = (try querySingle("SELECT COUNT(*) as c FROM conversations"))?["c"] as? Int ?? 0
        if count == 0 {
            try exec("INSERT INTO conversations (id, title) VALUES (1, 'Général')")
        }
    }

    /// v2 : FK ajoutées après coup (les bases v1 ont été créées sans ON DELETE
    /// CASCADE — SQLite ne permet pas d'ajouter une FK par ALTER, d'où la purge
    /// explicite des orphelins, rejouable sans risque).
    private func migrateToV2() throws {
        try exec("DELETE FROM tool_runs WHERE conversation_id IS NOT NULL AND conversation_id NOT IN (SELECT id FROM conversations)")
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw DatabaseError.execFailed(message: msg)
        }
    }

    // MARK: - Conversations

    func getAllConversations() throws -> [Conversation] {
        try query("SELECT * FROM conversations ORDER BY updated_at DESC")
    }

    func getConversation(id: Int) throws -> Conversation? {
        try querySingle("SELECT * FROM conversations WHERE id = ?", args: [id])
    }

    func createConversation(title: String = "Nouvelle conversation") throws -> Conversation {
        try exec("INSERT INTO conversations (title) VALUES (?)", params: [title])
        let id = Int(sqlite3_last_insert_rowid(db))
        return try getConversation(id: id)!
    }

    func updateConversationTitle(id: Int, title: String) throws {
        // NOTE : id passé en Int directement (bind en INTEGER via sqlite3_bind_int64),
        // comme getConversation — pas de conversion "\(id)" en TEXT.
        try exec("UPDATE conversations SET title = ?, updated_at = unixepoch() WHERE id = ?", params: [title as Any?, id as Any?])
    }

    func deleteConversation(id: Int) throws {
        // NOTE : id passé en Int directement (bind en INTEGER), pas en String.
        try exec("DELETE FROM messages WHERE conversation_id = ?", params: [id as Any?])
        try exec("DELETE FROM conversations WHERE id = ?", params: [id as Any?])
    }

    // MARK: - Messages

    func getMessages(conversationId: Int, limit: Int = 50) throws -> [Message] {
        try query("SELECT * FROM messages WHERE conversation_id = ? ORDER BY id DESC LIMIT ?", args: [conversationId, limit]).reversed()
    }

    func insertMessage(role: String, content: String, conversationId: Int?) throws -> Message {
        // NOTE : conversationId passé en Int? directement (bind en INTEGER ou NULL),
        // pas converti en String — SQLite compare INTEGER = INTEGER sans coercition surprise.
        try exec("INSERT INTO messages (role, content, conversation_id) VALUES (?, ?, ?)", params: [role as Any?, content as Any?, conversationId as Any?])
        let id = Int(sqlite3_last_insert_rowid(db))
        return Message(id: id, role: role, content: content, conversationId: conversationId, createdAt: Date())
    }

    /// Recherche plein-texte dans tous les messages. Retourne les résultats avec le titre
    /// de la conversation associée pour un affichage direct dans l'UI.
    struct SearchResult {
        let message: Message
        let conversationTitle: String
    }

    func searchMessages(_ query: String) throws -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let pattern = "%\(query.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"
        let rows: [[String: Any]] = try queryRaw("""
            SELECT m.id, m.role, m.content, m.conversation_id, m.created_at, c.title
            FROM messages m JOIN conversations c ON c.id = m.conversation_id
            WHERE m.content LIKE ? ESCAPE '\\' ORDER BY m.id DESC LIMIT 50
            """, args: [pattern])
        return rows.compactMap { row in
            guard let id = row["id"] as? Int,
                  let role = row["role"] as? String,
                  let content = row["content"] as? String,
                  let title = row["title"] as? String else { return nil }
            let cid = row["conversation_id"] as? Int
            let ts = (row["created_at"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
            return SearchResult(message: Message(id: id, role: role, content: content, conversationId: cid, createdAt: ts),
                                conversationTitle: title)
        }
    }

    // MARK: - Facts

    func getAllFacts() throws -> [Fact] {
        try query("SELECT id, key, value, updated_at FROM facts ORDER BY updated_at DESC")
    }

    func upsertFact(key: String, value: String) throws {
        try exec("INSERT OR REPLACE INTO facts (key, value, updated_at) VALUES (?, ?, unixepoch())", params: [key, value])
    }

    func deleteFact(key: String) throws {
        try exec("DELETE FROM facts WHERE key = ?", params: [key])
    }

    func deleteAllFacts() throws {
        try exec("DELETE FROM facts")
    }

    // MARK: - Tool runs (audit)

    /// Journalise une exécution d'outil. Tronque args/résultat : c'est un journal
    /// d'audit, pas une archive — 500 caractères de résultat suffisent à dire si
    /// l'action a vraiment eu lieu.
    func logToolRun(conversationId: Int?, tool: String, args: String, status: String, result: String) throws {
        try exec("INSERT INTO tool_runs (conversation_id, tool, args, status, result) VALUES (?, ?, ?, ?, ?)",
                 params: [conversationId as Any?, tool as Any?, String(args.prefix(200)) as Any?, status as Any?, String(result.prefix(500)) as Any?])
    }

    func getRecentToolRuns(limit: Int = 100) throws -> [ToolRun] {
        try query("SELECT id, conversation_id, tool, args, status, result, created_at FROM tool_runs ORDER BY id DESC LIMIT ?", args: [limit])
    }

    // MARK: - Query helpers

    // NOTE : params est [Any?] (et plus [String?]) pour que les id INTEGER soient liés
    // en INTEGER via sqlite3_bind_int64 plutôt que convertis en TEXT. Les chaînes sont
    // liées avec SQLITE_TRANSIENT (copie immédiate par SQLite) — jamais nil/SQLITE_STATIC
    // sur un pointeur temporaire, voir le commentaire en tête de fichier.
    private func exec(_ sql: String, params: [Any?]) throws {
        try withStmt(sql) { stmt in
            for (i, p) in params.enumerated() {
                let idx = Int32(i + 1)
                switch p {
                case nil:
                    sqlite3_bind_null(stmt, idx)
                case let n as Int:
                    sqlite3_bind_int64(stmt, idx, Int64(n))
                case let n as Int64:
                    sqlite3_bind_int64(stmt, idx, n)
                case let d as Double:
                    sqlite3_bind_double(stmt, idx, d)
                case let value as String:
                    sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
                default:
                    sqlite3_bind_null(stmt, idx)
                }
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.stepFailed(message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func query(_ sql: String, args: [Any] = []) throws -> [Conversation] {
        try withStmt(sql) { stmt in
            bindArgs(stmt, args)
            var results: [Conversation] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(Conversation(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    title: colText(stmt, 1),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int(stmt, 2))),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int(stmt, 3)))
                ))
            }
            return results
        }
    }

    private func query(_ sql: String, args: [Any] = []) throws -> [Message] {
        try withStmt(sql) { stmt in
            bindArgs(stmt, args)
            var results: [Message] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cid = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil
                results.append(Message(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    role: colText(stmt, 1),
                    content: colText(stmt, 2),
                    conversationId: cid,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int(stmt, 4)))
                ))
            }
            return results
        }
    }

    private func query(_ sql: String, args: [Any] = []) throws -> [Fact] {
        try withStmt(sql) { stmt in
            bindArgs(stmt, args)
            var results: [Fact] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(Fact(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    key: colText(stmt, 1),
                    value: colText(stmt, 2),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int(stmt, 3)))
                ))
            }
            return results
        }
    }

    private func query(_ sql: String, args: [Any] = []) throws -> [ToolRun] {
        try withStmt(sql) { stmt in
            bindArgs(stmt, args)
            var results: [ToolRun] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cid = sqlite3_column_type(stmt, 1) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 1)) : nil
                results.append(ToolRun(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    tool: colText(stmt, 2),
                    args: colText(stmt, 3),
                    status: colText(stmt, 4),
                    result: colText(stmt, 5),
                    conversationId: cid,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int(stmt, 6)))
                ))
            }
            return results
        }
    }

    private func querySingle(_ sql: String, args: [Any] = []) throws -> Conversation? {
        try withStmt(sql) { stmt in
            bindArgs(stmt, args)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Conversation(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    title: colText(stmt, 1),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int(stmt, 2))),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int(stmt, 3)))
                )
            }
            return nil
        }
    }

    private func querySingle(_ sql: String) throws -> [String: Any]? {
        try withStmt(sql) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                var dict: [String: Any] = [:]
                let count = sqlite3_column_count(stmt)
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    let type = sqlite3_column_type(stmt, i)
                    switch type {
                    case SQLITE_INTEGER: dict[name] = Int(sqlite3_column_int(stmt, i))
                    case SQLITE_TEXT: dict[name] = colText(stmt, i)
                    default: break
                    }
                }
                return dict
            }
            return nil
        }
    }

    private func withStmt<T>(_ sql: String, block: (OpaquePointer) throws -> T) throws -> T {
        guard let db else { throw DatabaseError.couldNotOpen(message: "Database not opened") }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw DatabaseError.prepareFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        return try block(stmt!)
    }

    /// Requête générique retournant chaque ligne sous forme de dictionnaire colonne → valeur.
    private func queryRaw(_ sql: String, args: [Any] = []) throws -> [[String: Any]] {
        try withStmt(sql) { stmt in
            bindArgs(stmt, args)
            var results: [[String: Any]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var dict: [String: Any] = [:]
                let count = sqlite3_column_count(stmt)
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: dict[name] = Int(sqlite3_column_int64(stmt, i))
                    case SQLITE_TEXT: dict[name] = colText(stmt, i)
                    default: break
                    }
                }
                results.append(dict)
            }
            return results
        }
    }

    private func bindArgs(_ stmt: OpaquePointer, _ args: [Any]) {
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            if let n = arg as? Int {
                sqlite3_bind_int64(stmt, idx, Int64(n))
            } else if let d = arg as? Double {
                sqlite3_bind_double(stmt, idx, d)
            } else if let n = arg as? Int64 {
                sqlite3_bind_int64(stmt, idx, n)
            } else if let s = arg as? String {
                // SQLITE_TRANSIENT : SQLite copie la chaîne immédiatement. Avec nil
                // (SQLITE_STATIC), le pointeur temporaire d'NSString pouvait être libéré
                // avant sqlite3_step → corruption mémoire sur chaînes longues/unicode.
                sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else if arg is NSNull {
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func colText(_ stmt: OpaquePointer, _ idx: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: ptr)
    }
}

enum DatabaseError: Error {
    case couldNotOpen(message: String)
    case execFailed(message: String)
    case prepareFailed(message: String)
    case stepFailed(message: String)
}
