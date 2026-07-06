import Foundation

struct Fact: Codable, Identifiable, Hashable {
    let id: Int
    let key: String
    var value: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, key, value
        case updatedAt = "updated_at"
    }
}
