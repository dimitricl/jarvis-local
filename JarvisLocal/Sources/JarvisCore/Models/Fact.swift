import Foundation

public struct Fact: Codable, Identifiable, Hashable {
    public let id: Int
    public let key: String
    public var value: String
    public let updatedAt: Date

    public init(id: Int, key: String, value: String, updatedAt: Date) {
        self.id = id
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, key, value
        case updatedAt = "updated_at"
    }
}
