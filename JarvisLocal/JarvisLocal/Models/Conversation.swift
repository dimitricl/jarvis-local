import Foundation

struct Conversation: Codable, Identifiable, Hashable {
    let id: Int
    var title: String
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
