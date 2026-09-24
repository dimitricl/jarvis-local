import Foundation
import JarvisCore

/// Transport stdio minimal JSON-RPC 2.0 (newline-delimited).
/// Pourquoi newline-delimited : c'est ce que font les serveurs MCP stdio
/// (1 réponse JSON par ligne sur stdout). Pas de Content-Length comme LSP.
/// Pourquoi un transport maison plutôt que le SDK officiel
/// (github.com/modelcontextprotocol/swift-sdk) : le SDK est jeune et son API
/// change vite ; ce transport couvre les 3 méthodes réellement utilisées
/// (initialize, tools/list, tools/call) et l'interface reste substituable
/// par le SDK quand il se stabilise — sans réécrire le routeur.
actor MCPStdioTransport {
    private var proc: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()
    /// Plafond du buffer stdout : sans newline (serveur verbeux, gros tool result),
    /// buffer.append() grossit sans limite. Au-delà, on purge et on échoue les
    /// requêtes en attente plutôt que de laisser la RAM diverger.
    static let maxBufferBytes = 10_000_000

    /// Lance le process serveur. Throw si le binaire n'existe pas
    /// (iMCP non installé → le provider marque le serveur hors-ligne, pas de crash).
    /// Accepte un binaire sans "/" (ex. "imcp") : résolu via PATH au spawn
    /// avec `/usr/bin/env` pour ne pas dépendre d'un chemin absolu.
    func start(command: String, args: [String]) throws {
        let p = Process()
        if command.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: command) else {
                throw MCPError.binaryNotFound(command)
            }
            p.executableURL = URL(fileURLWithPath: command)
            p.arguments = args
        } else {
            // Binaire résolu via PATH : `/usr/bin/env imcp …` plutôt qu'un
            // chemin en dur — fonctionne sur Intel, arm64, et installs custom.
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [command] + args
        }
        let i = Pipe(); let o = Pipe(); let e = Pipe()
        p.standardInput = i; p.standardOutput = o; p.standardError = e
        do {
            try p.run()
        } catch {
            // `env` absent ou spawn impossible : hors-ligne propre, pas de crash.
            throw MCPError.binaryNotFound(command)
        }
        self.proc = p; self.stdin = i.fileHandleForWriting; self.stdout = o.fileHandleForReading; self.stderr = e.fileHandleForReading
        self.stdout?.readabilityHandler = { [weak self] h in
            Task { await self?.ingest(h.availableData) }
        }
        // Drain stderr : un pipe jamais lu se remplit (~64 Ko) puis BLOQUE le
        // serveur fils à sa prochaine écriture (deadlock apparent : tools/list
        // ne répond plus, timeout, relance…). On jette le contenu (logs serveur).
        self.stderr?.readabilityHandler = { h in
            _ = h.availableData
        }
    }

    func stop() {
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil
        try? stdin?.close(); try? stdout?.close(); try? stderr?.close()
        stderr = nil
        proc?.terminate(); proc = nil
        // Les requêtes en vol ne doivent pas rester suspendues pour toujours.
        let stale = pending
        pending = [:]
        buffer = Data()
        for cont in stale.values {
            cont.resume(throwing: MCPError.offline("transport fermé"))
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        if buffer.count > Self.maxBufferBytes {
            // Serveur bavard ou réponse gigantesque : purge + échec propre des
            // requêtes en attente plutôt que croissance mémoire illimitée.
            buffer = Data()
            let stale = pending
            pending = [:]
            for cont in stale.values {
                cont.resume(throwing: MCPError.remote("réponse MCP trop volumineuse (> \(Self.maxBufferBytes) octets), buffer purgé"))
            }
            return
        }
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<nl]
            buffer.removeSubrange(...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["id"] as? Int,
                  let cont = pending.removeValue(forKey: id)
            else { continue }
            if let err = obj["error"] as? [String: Any] {
                cont.resume(throwing: MCPError.remote("\(err)"))
            } else {
                cont.resume(returning: (obj["result"] as? [String: Any]) ?? [:])
            }
        }
    }

    /// Notification JSON-RPC (sans id, sans réponse attendue).
    /// Utilisé pour `notifications/initialized` : la spec MCP exige que le client
    /// l'envoie après `initialize`, et iMCP met en file les requêtes suivantes
    /// (dont `tools/list`) tant qu'il ne l'a pas reçue — sans elle, `tools/list`
    /// timeout de façon intermittente selon le timing du handshake.
    func notify(method: String, params: [String: Any] = [:]) throws {
        let msg: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: msg) + Data([0x0A])
        try stdin?.write(contentsOf: data)
    }

    /// Appel RPC générique avec timeout (un serveur MCP bloqué ne doit
    /// jamais geler le tour de conversation — même règle que runProcess).
    /// Timeout 60s (pas 20s) : constaté en test réel contre iMCP, la réponse
    /// `tools/list` (~22 Ko) arrive en deux flushes espacés de ~20s (relais
    /// Bonjour app ↔ CLI). Avec 20s, le timeout tuait la continuation quelques
    /// millisecondes avant la fin de la réponse — alors que tout le handshake
    /// (notify + ingest des notifications sans id) fonctionnait correctement.
    func request(method: String, params: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> [String: Any] {
        let id = nextId; nextId += 1
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: msg) + Data([0x0A])
        try stdin?.write(contentsOf: data)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            pending[id] = cont
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let c = self.pending.removeValue(forKey: id) {
                    c.resume(throwing: MCPError.timeout(method))
                }
            }
        }
    }
}

enum MCPError: Error, CustomStringConvertible {    case binaryNotFound(String)
    case timeout(String)
    case remote(String)
    case offline(String)
    case notAuthorized(String)
    var description: String {
        switch self {
        case .binaryNotFound(let c): return "Serveur MCP introuvable : \(c) (installe iMCP ou renseigne son chemin dans Réglages > MCP)."
        case .timeout(let m): return "Serveur MCP sans réponse (méthode \(m), timeout)."
        case .remote(let e): return "Erreur serveur MCP : \(e)"
        case .offline(let s): return "Serveur MCP hors-ligne : \(s)."
        case .notAuthorized(let tool): return "Outil MCP non autorisé par la politique locale : \(tool)."
        }
    }
}
