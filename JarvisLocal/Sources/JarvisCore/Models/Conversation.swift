import Foundation

public struct Conversation: Codable, Identifiable, Hashable {
    public let id: Int
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: Int, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
