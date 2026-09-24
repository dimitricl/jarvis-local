import Foundation

/// Cycle de vie d'un fait en mémoire long-terme.
/// - active : pris en compte dans le prompt système (factsContext).
/// - superseded : remplacé par un fait plus récent (`supersededBy`) — conservé
///   pour l'audit, exclu du contexte. Voir DatabaseService.supersedeFact.
public enum FactStatus: String, Sendable, Codable, Hashable {
    case active
    case superseded
}

public struct Fact: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let key: String
    public var value: String
    public let updatedAt: Date
    /// Message d'origine de l'information (messages.id), si connue. Permet de
    /// remonter au contexte exact ("qui a dit quoi, quand") au lieu d'une
    /// paire clé/valeur orpheline.
    public let sourceMessageId: Int?
    /// Fiabilité estimée 0-1 (1 = consigne explicite confirmée, bas = heuristique).
    public let confidence: Double
    public let createdAt: Date
    public let status: FactStatus
    /// Fait remplaçant (facts.id), quand status == .superseded.
    public let supersededBy: Int?

    public init(
        id: Int,
        key: String,
        value: String,
        updatedAt: Date,
        sourceMessageId: Int? = nil,
        confidence: Double = 1.0,
        createdAt: Date? = nil,
        status: FactStatus = .active,
        supersededBy: Int? = nil
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
        self.sourceMessageId = sourceMessageId
        self.confidence = confidence
        // Création inconnue = dernière mise à jour (cas des faits pré-v3 backfillés).
        self.createdAt = createdAt ?? updatedAt
        self.status = status
        self.supersededBy = supersededBy
    }

    enum CodingKeys: String, CodingKey {
        case id, key, value
        case updatedAt = "updated_at"
        case sourceMessageId = "source_message_id"
        case confidence
        case createdAt = "created_at"
        case status
        case supersededBy = "superseded_by"
    }

    /// Décodage tolérant aux JSON pré-v3 (sans les nouvelles clés) : les champs
    /// absents reprennent les défauts de l'init principal. Requis explicite car
    /// la synthèse Decodable ignore les valeurs par défaut des `let`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(Int.self, forKey: .id)
        let key = try container.decode(String.self, forKey: .key)
        let value = try container.decode(String.self, forKey: .value)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.init(
            id: id,
            key: key,
            value: value,
            updatedAt: updatedAt,
            sourceMessageId: try container.decodeIfPresent(Int.self, forKey: .sourceMessageId),
            confidence: try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt),
            status: try container.decodeIfPresent(FactStatus.self, forKey: .status) ?? .active,
            supersededBy: try container.decodeIfPresent(Int.self, forKey: .supersededBy)
        )
    }
}
