import Foundation
import SQLite3
import JarvisCore

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
        // Schéma actuel : v1 = tables initiales, v2 = index + purge orphelins,
        // v3 = faits enrichis (source, confidence, created_at, status, superseded_by).
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
        if version < 3 {
            try migrateToV3()
            version = 3
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

    /// v3 : faits enrichis pour une mémoire auditable.
    /// - source_message_id : message d'origine (FK souple, SET NULL à la suppression).
    /// - confidence : fiabilité 0-1, défaut 1.0 (faits pré-v3 = pleine confiance).
    /// - created_at : SANS défaut SQL — ADD COLUMN interdit les défauts non constants
    ///   sur le SQLite embarqué ("Cannot add a column with non-constant default",
    ///   constaté en prod : migration bloquée à mi-chemin, user_version restée à 2).
    ///   La colonne est donc nullable, backfillée ci-dessous, et TOUJOURS renseignée
    ///   explicitement par upsertFact (unixepoch() dans le VALUES — autorisé en DML).
    /// - status : 'active' (défaut) / 'superseded'.
    /// - superseded_by : fait remplaçant.
    /// Rejouable sans risque : chaque ALTER est gardé par hasColumn, le backfill est
    /// idempotent (ne touche que les lignes à created_at NULL) — y compris les bases
    /// restées coincées à mi-migration v3 par le bug ci-dessus.
    private func migrateToV3() throws {
        if !(try hasColumn(table: "facts", column: "source_message_id")) {
            try exec("ALTER TABLE facts ADD COLUMN source_message_id INTEGER REFERENCES messages(id) ON DELETE SET NULL")
        }
        if !(try hasColumn(table: "facts", column: "confidence")) {
            try exec("ALTER TABLE facts ADD COLUMN confidence REAL NOT NULL DEFAULT 1.0")
        }
        if !(try hasColumn(table: "facts", column: "created_at")) {
            try exec("ALTER TABLE facts ADD COLUMN created_at INTEGER")
        }
        if !(try hasColumn(table: "facts", column: "status")) {
            try exec("ALTER TABLE facts ADD COLUMN status TEXT NOT NULL DEFAULT 'active'")
        }
        if !(try hasColumn(table: "facts", column: "superseded_by")) {
            try exec("ALTER TABLE facts ADD COLUMN superseded_by INTEGER REFERENCES facts(id) ON DELETE SET NULL")
        }
        try exec("UPDATE facts SET created_at = updated_at WHERE created_at IS NULL")
        try exec("CREATE INDEX IF NOT EXISTS idx_facts_status ON facts(status)")
    }

    /// true si la colonne existe (garde des ALTER rejouables). Forme PRAGMA
    /// classique (comme userVersion) : les fonctions table-valued pragma_*
    /// n'acceptent pas de paramètre lié sur toutes les versions de SQLite.
    /// `table` est une constante interne (jamais une entrée utilisateur).
    /// `internal` pour les tests (vérifie le schéma après migration).
    func hasColumn(table: String, column: String) throws -> Bool {
        let rows: [[String: Any]] = try queryRaw("PRAGMA table_info(\(table))")
        return rows.contains { ($0["name"] as? String) == column }
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
        // Le journal d'audit DOIT partir avec la conversation : depuis
        // PRAGMA foreign_keys=ON, un tool_runs orphelin bloque le DELETE parent
        // (les bases existantes n'ont pas le ON DELETE CASCADE) — régression
        // constatée : toute conversation avec activité d'outils devenait insupprimable.
        try exec("DELETE FROM tool_runs WHERE conversation_id = ?", params: [id as Any?])
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
    /// Le type de retour vit dans JarvisCore (MessageSearchResult) : le ViewModel
    /// consomme searchMessages via le protocol MessageSearchStore, sans voir ce type.
    func searchMessages(_ query: String) throws -> [MessageSearchResult] {
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
            return MessageSearchResult(message: Message(id: id, role: role, content: content, conversationId: cid, createdAt: ts),
                                 conversationTitle: title)
        }
    }

    // MARK: - Facts

    func getAllFacts() throws -> [Fact] {
        try query("SELECT id, key, value, updated_at, source_message_id, confidence, created_at, status, superseded_by FROM facts ORDER BY updated_at DESC")
    }

    func getFact(key: String) throws -> Fact? {
        try query("SELECT id, key, value, updated_at, source_message_id, confidence, created_at, status, superseded_by FROM facts WHERE key = ?", args: [key]).first
    }

    /// Upsert avec traçabilité (étape 3). La confidence est clampée 0-1 (un écart
    /// de modèle ne doit pas polluer la base).
    /// NOTE : INSERT OR REPLACE recrée la ligne — created_at repart à maintenant et
    /// un éventuel status superseded repasse active : un upsert EST une réaffirmation.
    func upsertFact(key: String, value: String, sourceMessageId: Int?, confidence: Double) throws {
        let clamped = min(max(confidence, 0), 1)
        try exec("INSERT OR REPLACE INTO facts (key, value, updated_at, source_message_id, confidence, created_at) VALUES (?, ?, unixepoch(), ?, ?, unixepoch())",
                 params: [key, value, sourceMessageId as Any?, clamped as Any?])
    }

    /// Marque un fait comme remplacé par un autre (conservé pour l'audit).
    /// L'exclusion du contexte (prompt système) arrive avec l'exploitation.
    func supersedeFact(key: String, byFactId: Int) throws {
        try exec("UPDATE facts SET status = 'superseded', superseded_by = ?, updated_at = unixepoch() WHERE key = ?",
                 params: [byFactId as Any?, key as Any?])
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
                let sourceId = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 4)) : nil
                let replacedBy = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 8)) : nil
                results.append(Fact(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    key: colText(stmt, 1),
                    value: colText(stmt, 2),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int(stmt, 3))),
                    sourceMessageId: sourceId,
                    confidence: sqlite3_column_double(stmt, 5),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int(stmt, 6))),
                    status: FactStatus(rawValue: colText(stmt, 7)) ?? .active,
                    supersededBy: replacedBy
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

// MARK: - Contrats JarvisCore

/// DatabaseService est volontairement `internal` : hors de ce module, il n'est
/// manipulable que via `any PersistentStore` (JarvisUI, tests d'injection).
/// La conformité elle-même est interne — la dispatch via existentiel public
/// fonctionne cross-module sans exposer le type.
extension DatabaseService: PersistentStore {}

enum DatabaseError: Error, LocalizedError {
    case couldNotOpen(message: String)
    case execFailed(message: String)
    case prepareFailed(message: String)
    case stepFailed(message: String)

    /// Sans ça, l'UI affichait "DatabaseError erreur 3" au lieu du message SQLite
    /// ("FOREIGN KEY constraint failed") — la régression suppression aurait été
    /// diagnostiquée en une lecture au lieu d'un audit.
    var errorDescription: String? {
        switch self {
        case .couldNotOpen(let m): return "Ouverture impossible : \(m)"
        case .execFailed(let m): return "Écriture impossible : \(m)"
        case .prepareFailed(let m): return "Requête invalide : \(m)"
        case .stepFailed(let m): return "Opération impossible : \(m)"
        }
    }
}
