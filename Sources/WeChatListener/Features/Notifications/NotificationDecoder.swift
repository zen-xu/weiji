import Foundation

enum NotificationDecoder {
    static func decode(_ row: [String: SQLValue], now: Date = Date()) throws -> Message {
        guard let bytes = row.data("data"), bytes.count <= 4_000_000,
            let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
            let request = plist["req"] as? [String: Any], let record = row.int("rec_id")
        else {
            throw ListenerError("通知字段格式尚未适配，未猜测正文。")
        }
        var info = [String: Any]()
        if let archive = request["usda"] as? Data, archive.count <= 1_000_000,
            let reader = try? NSKeyedUnarchiver(forReadingFrom: archive)
        {
            reader.requiresSecureCoding = true
            reader.decodingFailurePolicy = .setErrorAndReturn
            info =
                reader.decodeObject(
                    of: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self],
                    forKey: NSKeyedArchiveRootObjectKey) as? [String: Any] ?? [:]
            reader.finishDecoding()
        } else if let dictionary = request["usda"] as? [String: Any] {
            info = dictionary
        }
        let chat = info["chatname"] as? String
        let unique = info["unique_id"] as? String
        let uuid = row.data("uuid") ?? plist["uuid"] as? Data
        let identity = nonempty(unique) ?? uuid.map { $0.base64EncodedString() } ?? nonempty(request["iden"] as? String)
        let delivered = row.double("delivered_date").map { Date(timeIntervalSinceReferenceDate: $0) }
        return make(
            record: record, title: request["titl"] as? String ?? "",
            subtitle: request["subt"] as? String ?? "", body: request["body"] as? String ?? "",
            chat: chat, identity: identity, delivered: delivered, captured: now)
    }
    static func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    static func make(
        record: Int64, title: String, subtitle: String, body: String, chat: String? = nil,
        identity: String? = nil, delivered: Date?, captured: Date
    ) -> Message {
        let chat = nonempty(chat)
        let sourceKey = digest("record:\(record)|time:\(Int64((delivered ?? captured).timeIntervalSince1970))")
        let id = digest("wechat-notification-v1|\(identity ?? sourceKey)")
        let kind = chat.map { $0.hasSuffix("@chatroom") ? "group" : "direct" } ?? "unknown"
        let conversationID = digest("wechat-conversation-v1|\(chat ?? "title-fallback:" + title)")
        let sender = kind == "direct" ? nonempty(title) : nonempty(subtitle)
        let at = Dates.string(captured)
        return Message(
            id: id, conversationID: conversationID, conversationName: title,
            conversationKind: kind,
            conversationIDSource: chat == nil ? "display_title_fallback" : "notification_chatname",
            senderDisplayName: sender, title: title, subtitle: subtitle, body: body,
            deliveredAt: delivered.map(Dates.string), capturedAt: at, updatedAt: at,
            appBundleID: "com.tencent.xinwechat", sourceRecordID: record,
            notificationIdentity: identity.map { digest($0) }, sourceKey: sourceKey,
            contentHash: digest(
                [title, subtitle, body, chat ?? "", delivered.map(Dates.string) ?? ""].joined(separator: "\u{0}")),
            mediaDirectoryID: chat.map { mediaDirectoryID($0) })
    }
}
