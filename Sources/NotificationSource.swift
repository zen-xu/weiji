import Foundation

enum NotificationDecoder {
    static func decode(_ row: [String: SQLValue], now: Date = Date()) throws -> Message {
        guard let bytes = row.data("data"), bytes.count <= 4_000_000,
              let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let request = plist["req"] as? [String: Any], let record = row.int("rec_id") else {
            throw ListenerError("通知字段格式尚未适配，未猜测正文。")
        }
        var info = [String: Any]()
        if let archive = request["usda"] as? Data, archive.count <= 1_000_000,
           let reader = try? NSKeyedUnarchiver(forReadingFrom: archive) {
            reader.requiresSecureCoding = true
            reader.decodingFailurePolicy = .setErrorAndReturn
            info = reader.decodeObject(of: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self], forKey: NSKeyedArchiveRootObjectKey) as? [String: Any] ?? [:]
            reader.finishDecoding()
        } else if let dictionary = request["usda"] as? [String: Any] { info = dictionary }
        let chat = info["chatname"] as? String
        let unique = info["unique_id"] as? String
        let uuid = row.data("uuid") ?? plist["uuid"] as? Data
        let identity = nonempty(unique) ?? uuid.map { $0.base64EncodedString() } ?? nonempty(request["iden"] as? String)
        let delivered = row.double("delivered_date").map { Date(timeIntervalSinceReferenceDate: $0) }
        return make(record: record, title: request["titl"] as? String ?? "",
                    subtitle: request["subt"] as? String ?? "", body: request["body"] as? String ?? "",
                    chat: chat, identity: identity, delivered: delivered, captured: now)
    }
    static func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    static func make(record: Int64, title: String, subtitle: String, body: String, chat: String? = nil,
                     identity: String? = nil, delivered: Date?, captured: Date) -> Message {
        let chat = nonempty(chat)
        let sourceKey = digest("record:\(record)|time:\(Int64((delivered ?? captured).timeIntervalSince1970))")
        let id = digest("wechat-notification-v1|\(identity ?? sourceKey)")
        let kind = chat.map { $0.hasSuffix("@chatroom") ? "group" : "direct" } ?? "unknown"
        let conversationID = digest("wechat-conversation-v1|\(chat ?? "title-fallback:" + title)")
        let sender = kind == "direct" ? nonempty(title) : nonempty(subtitle)
        let at = Dates.string(captured)
        return Message(id: id, conversationID: conversationID, conversationName: title,
                       conversationKind: kind, conversationIDSource: chat == nil ? "display_title_fallback" : "notification_chatname",
                       senderDisplayName: sender, title: title, subtitle: subtitle, body: body,
                       deliveredAt: delivered.map(Dates.string), capturedAt: at, updatedAt: at,
                       appBundleID: "com.tencent.xinwechat", sourceRecordID: record,
                       notificationIdentity: identity.map { digest($0) }, sourceKey: sourceKey,
                       contentHash: digest([title, subtitle, body, chat ?? "", delivered.map(Dates.string) ?? ""].joined(separator: "\u{0}")),
                       mediaDirectoryID: chat.map { mediaDirectoryID($0) })
    }
}

final class NotificationSource {
    let database: SQLite
    init(url: URL) throws {
        database = try SQLite(url.path, readOnly: true)
        let columns = try database.rows("PRAGMA table_info(record)").compactMap { $0.string("name") }
        guard Set(["rec_id", "data", "app_id", "delivered_date", "uuid"]).isSubset(of: Set(columns)) else {
            throw ListenerError("当前 macOS 通知数据库结构尚未适配。")
        }
    }
    func snapshot() throws -> [[String: SQLValue]] {
        // Read one consistent snapshot. Never write, copy, or alter the system database/WAL.
        try database.run("BEGIN")
        do {
            var rows = [[String: SQLValue]]()
            var offset = 0
            while true {
                let page = try database.rows("""
                    SELECT r.rec_id, r.uuid, r.delivered_date, r.data
                    FROM record r JOIN app a ON a.app_id=r.app_id
                    WHERE a.identifier = ? COLLATE NOCASE ORDER BY r.rec_id LIMIT 500 OFFSET ?
                    """, [.text("com.tencent.xinwechat"), .integer(Int64(offset))])
                rows.append(contentsOf: page)
                if page.count < 500 { break }
                offset += page.count
            }
            try database.run("COMMIT")
            return rows
        } catch { try? database.run("ROLLBACK"); throw error }
    }
    func capture(to archive: Archive) throws -> CaptureResult {
        let rows = try snapshot()
        var result = CaptureResult(sourceRows: rows.count)
        for row in rows {
            do {
                let message = try NotificationDecoder.decode(row)
                switch try archive.ingest(message) {
                case "inserted": result.inserted += 1
                case "updated": result.updated += 1
                default: break
                }
            } catch { result.failed += 1 }
        }
        do { try archive.flushJournal() } catch { result.journalError = true }
        return result
    }
}
