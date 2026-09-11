import Foundation
import SQLite3

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
        try migrate()
    }

    private func migrate() throws {
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
        let count = (try querySingle("SELECT COUNT(*) as c FROM conversations"))?["c"] as? Int ?? 0
        if count == 0 {
            try exec("INSERT INTO conversations (id, title) VALUES (1, 'Général')")
        }
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
        try exec("UPDATE conversations SET title = ?, updated_at = unixepoch() WHERE id = ?", params: [title, "\(id)"])
    }

    func deleteConversation(id: Int) throws {
        try exec("DELETE FROM messages WHERE conversation_id = ?", params: ["\(id)"])
        try exec("DELETE FROM conversations WHERE id = ?", params: ["\(id)"])
    }

    // MARK: - Messages

    func getMessages(conversationId: Int, limit: Int = 50) throws -> [Message] {
        try query("SELECT * FROM messages WHERE conversation_id = ? ORDER BY id DESC LIMIT ?", args: [conversationId, limit]).reversed()
    }

    func insertMessage(role: String, content: String, conversationId: Int?) throws -> Message {
        try exec("INSERT INTO messages (role, content, conversation_id) VALUES (?, ?, ?)", params: [role, content, conversationId.map { "\($0)" }])
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

    // MARK: - Query helpers

    private func exec(_ sql: String, params: [String?]) throws {
        try withStmt(sql) { stmt in
            for (i, p) in params.enumerated() {
                let idx = Int32(i + 1)
                if let value = p {
                    sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1, nil)
                } else {
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
                sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, nil)
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
