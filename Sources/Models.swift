import Foundation
import CryptoKit

struct ListenerError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

func mediaDirectoryID(_ chat: String) -> String {
    Insecure.MD5.hash(data: Data(chat.utf8)).map { String(format: "%02x", $0) }.joined()
}

enum Dates {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func day(_ value: String, end: Bool = false) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw ListenerError("日期必须为 YYYY-MM-DD")
        }
        return string(end ? Calendar.current.date(byAdding: .day, value: 1, to: date)! : date)
    }
}

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
        case schemaVersion = "schema_version", id
        case conversationID = "conversation_id", conversationName = "conversation_name"
        case conversationKind = "conversation_kind", conversationIDSource = "conversation_id_source"
        case senderDisplayName = "sender_display_name", title, subtitle, body
        case deliveredAt = "delivered_at", capturedAt = "captured_at", updatedAt = "updated_at"
        case appBundleID = "app_bundle_id", sourceRecordID = "source_record_id"
        case notificationIdentity = "notification_identity", sourceKey = "source_key", contentHash = "content_hash"
        case mediaDirectoryID = "media_directory_id"
        case source, coverage, accountIdentity = "account_identity", isCompleteChat = "is_complete_chat"
        case bodyMayBeTruncated = "body_may_be_truncated", includesSentMessages = "includes_sent_messages"
    }
    var date: Date { Dates.parse(deliveredAt ?? capturedAt) ?? .distantPast }
    var displayName: String { conversationName.isEmpty ? "未命名会话" : conversationName }
    var kindLabel: String { conversationKind == "group" ? "群聊" : conversationKind == "direct" ? "私聊" : "通知分组" }
}

struct Conversation: Identifiable {
    var id: String
    var name: String
    var kind: String
    var identitySource: String
    var preview: String
    var lastAt: String
    var count: Int
    var inferredGroup = false
    var kindLabel: String { kind == "group" ? "群聊" : kind == "direct" ? "私聊" : inferredGroup ? "疑似群聊" : "通知分组" }
}

struct MessageFilter {
    var query = ""
    var conversation: String?
    var from: String?
    var before: String?
    var limit = 100
    var offset = 0
}

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
        case firstMessageAt = "first_message_at", lastMessageAt = "last_message_at"
        case databaseBytes = "database_bytes", schemaVersion = "schema_version", coverage
    }
}

struct ImportResult { var inserted = 0; var updated = 0; var unchanged = 0; var failed = 0 }
struct CaptureResult {
    var sourceRows = 0
    var inserted = 0
    var updated = 0
    var failed = 0
    var journalError = false
}

struct AppPaths {
    let root: URL
    let logs: URL
    var database: URL { root.appendingPathComponent("archive.sqlite") }
    var journal: URL { root.appendingPathComponent("events.jsonl") }
    var exports: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    var preferences: URL { root.appendingPathComponent("preferences.json") }
    var source: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }
    init(override: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        root = override.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? home.appendingPathComponent("Library/Application Support/WeChatListener", isDirectory: true)
        logs = override == nil ? home.appendingPathComponent("Library/Logs/WeChatListener", isDirectory: true)
            : root.appendingPathComponent("Logs", isDirectory: true)
    }
    func prepare() throws {
        for url in [root, logs, exports] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
    func log(_ code: String) {
        // Callers supply fixed diagnostic codes only, never message text or source errors.
        let url = logs.appendingPathComponent("listener.log")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            let previous = logs.appendingPathComponent("listener.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(Dates.string(Date())) \(code)\n".utf8))
    }
}

struct Preferences: Codable {
    var collectOnLaunch = false
    var pollSeconds = 2
    var fileDirectory: String?
    static func load(_ paths: AppPaths) -> Preferences {
        (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: paths.preferences))) ?? Self()
    }
    func save(_ paths: AppPaths) throws {
        try JSONEncoder().encode(self).write(to: paths.preferences, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.preferences.path)
    }
}

func jsonData<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
