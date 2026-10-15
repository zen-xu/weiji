import Foundation

struct Message: Codable, Identifiable, Equatable {
    var schemaVersion = 1
    var id: String
    var conversationID: String
    var conversationName: String
    var conversationKind: String
    var conversationIDSource: String
    var senderDisplayName: String?
    var title: String
    var subtitle: String
    var body: String
    var deliveredAt: String?
    var capturedAt: String
    var updatedAt: String
    var appBundleID: String
    var sourceRecordID: Int64
    var notificationIdentity: String?
    var sourceKey: String
    var contentHash: String
    var mediaDirectoryID: String?
    var source = "macos_notification"
    var coverage = "notification_only"
    var accountIdentity = "not_available_from_notification"
    var isCompleteChat = false
    var bodyMayBeTruncated = true
    var includesSentMessages = false

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case id
        case conversationID = "conversation_id"
        case conversationName = "conversation_name"
        case conversationKind = "conversation_kind"
        case conversationIDSource = "conversation_id_source"
        case senderDisplayName = "sender_display_name"
        case title, subtitle, body
        case deliveredAt = "delivered_at"
        case capturedAt = "captured_at"
        case updatedAt = "updated_at"
        case appBundleID = "app_bundle_id"
        case sourceRecordID = "source_record_id"
        case notificationIdentity = "notification_identity"
        case sourceKey = "source_key"
        case contentHash = "content_hash"
        case mediaDirectoryID = "media_directory_id"
        case source, coverage
        case accountIdentity = "account_identity"
        case isCompleteChat = "is_complete_chat"
        case bodyMayBeTruncated = "body_may_be_truncated"
        case includesSentMessages = "includes_sent_messages"
    }
    var date: Date { Dates.parse(deliveredAt ?? capturedAt) ?? .distantPast }
    var displayName: String { conversationName.isEmpty ? "未命名会话" : conversationName }
    var kindLabel: String { conversationKind == "group" ? "群聊" : conversationKind == "direct" ? "私聊" : "通知分组" }
}
