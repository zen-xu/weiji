import Foundation

struct ArchiveStats: Codable {
    var messages: Int
    var conversations: Int
    var events: Int
    var firstMessageAt: String?
    var lastMessageAt: String?
    var databaseBytes: Int64
    var schemaVersion = 1
    var coverage = "notification_only"
    enum CodingKeys: String, CodingKey {
        case messages, conversations, events
        case firstMessageAt = "first_message_at"
        case lastMessageAt = "last_message_at"
        case databaseBytes = "database_bytes"
        case schemaVersion = "schema_version"
        case coverage
    }
}
