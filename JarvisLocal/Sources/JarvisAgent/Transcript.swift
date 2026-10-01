import Foundation
import JarvisKit

/// L1 — transcript COMPLET et persisté.
///
/// user, assistant (+ tool_calls), tool (+ résultat tronqué de façon
/// déterministe avec marqueur). Reprise possible après crash : le run
/// repart de l'historique chargé, le modèle revoit ce qu'il a fait.
public struct Transcript: Sendable, Codable, Equatable {
    public var id: UUID
    public var model: String
    public var messages: [Message]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), model: String, messages: [Message] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.model = model
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func append(_ message: Message) {
        messages.append(message)
        updatedAt = Date()
    }
}

public protocol TranscriptStore: Sendable {
    func save(_ transcript: Transcript) async throws
    func load(id: UUID) async throws -> Transcript?
    /// Identifiants connus, du plus récent au plus ancien (I/O locale pure).
    func listIDs() async throws -> [UUID]
    func delete(id: UUID) async throws
}

/// Stockage fichier JSON (un fichier par transcript). Acteur : I/O
/// sérialisée, pas de `@unchecked Sendable`.
public actor FileTranscriptStore: TranscriptStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public func save(_ transcript: Transcript) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(transcript)
        try data.write(to: url(for: transcript.id), options: .atomic)
    }

    public func load(id: UUID) async throws -> Transcript? {
        let u = url(for: id)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: u))
    }

    public func listIDs() async throws -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var ids: [(UUID, Date)] = []
        for name in names where name.hasSuffix(".json") {
            let idString = (name as NSString).deletingPathExtension
            guard let id = UUID(uuidString: idString) else { continue }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.modificationDate] as? Date) ?? .distantPast
            ids.append((id, mtime))
        }
        return ids.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    public func delete(id: UUID) async throws {
        try FileManager.default.removeItem(at: url(for: id))
    }
}

/// Troncature DÉTERMINISTE des résultats d'outils, avec marqueur et octets.
///
/// Le modèle sait qu'il voit un extrait et comment relire la suite
/// (`offset=…`), au lieu de raisonner sur du texte coupé en silence.
public enum TranscriptTrimming {
    public static func truncateResult(_ text: String, limitBytes: Int) -> String {
        let total = text.utf8.count
        guard total > limitBytes else { return text }

        // O(n) : avance caractère par caractère, coupe sur frontière UTF-8 valide.
        var byteCount = 0
        var cutIndex = text.startIndex
        for idx in text.indices {
            let w = text[idx].utf8.count
            if byteCount + w > limitBytes { break }
            byteCount += w
            cutIndex = text.index(after: idx)
        }

        let prefix = String(text[..<cutIndex])
        let dropped = total - byteCount
        return prefix + "\n[tronqué : \(dropped) octets, relire avec offset=\(byteCount)]"
    }
}
