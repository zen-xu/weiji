import Foundation

enum NotificationDecoder {
    static func decode(_ row: [String: SQLValue], now: Date = Date()) throws -> Message {
        guard let bytes = row.data("data"), bytes.count <= 4_000_000,
            let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
            let request = plist["req"] as? [String: Any], let record = row.int("rec_id")
        else {
            throw ListenerError("通知字段格式尚未适配，未猜测正文。")
        }
        guard
            let platform = NotificationPlatform.platform(
                for: row.string("app_bundle_id") ?? NotificationPlatform.wechat.bundleID)
        else {
            throw ListenerError("不支持的通知来源。")
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
        let chat = platform == .wechat ? info["chatname"] as? String : nil
        let unique = platform == .wechat ? info["unique_id"] as? String : nil
        let uuid = row.data("uuid") ?? plist["uuid"] as? Data
        let identity =
            nonempty(unique) ?? uuid.flatMap { $0.isEmpty ? nil : $0.base64EncodedString() }
            ?? nonempty(request["iden"] as? String)
        let seconds = row.double("delivered_date")
        if let seconds {
            guard seconds.isFinite, seconds >= Date.distantPast.timeIntervalSinceReferenceDate,
                seconds <= Date.distantFuture.timeIntervalSinceReferenceDate
            else { throw ListenerError("通知时间字段格式尚未适配，未猜测时间。") }
        }
        let delivered = seconds.map { Date(timeIntervalSinceReferenceDate: $0) }
        return make(
            record: record, title: request["titl"] as? String ?? "",
            subtitle: request["subt"] as? String ?? "", body: request["body"] as? String ?? "",
            chat: chat, identity: identity, delivered: delivered, captured: now, platform: platform)
    }
    static func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
    static func make(
        record: Int64, title: String, subtitle: String, body: String, chat: String? = nil,
        identity: String? = nil, delivered: Date?, captured: Date, platform: NotificationPlatform = .wechat
    ) -> Message {
        let chat = platform == .wechat ? nonempty(chat) : nil
        let sourceNamespace = platform == .wechat ? "" : "\(platform.rawValue)|"
        let sourceKey = digest(
            "\(sourceNamespace)record:\(record)|time:\(Int64((delivered ?? captured).timeIntervalSince1970))")
        let id = digest("\(platform.rawValue)-notification-v1|\(identity ?? sourceKey)")
        let kind = chat.map { $0.hasSuffix("@chatroom") ? "group" : "direct" } ?? "unknown"
        let conversationID = digest("\(platform.rawValue)-conversation-v1|\(chat ?? "title-fallback:" + title)")
        let sender = kind == "direct" ? nonempty(title) : nonempty(subtitle)
        let at = Dates.string(captured)
        return Message(
            id: id, conversationID: conversationID, conversationName: title,
            conversationKind: kind,
            conversationIDSource: chat == nil ? "display_title_fallback" : "notification_chatname",
            senderDisplayName: sender, title: title, subtitle: subtitle, body: body,
            deliveredAt: delivered.map(Dates.string), capturedAt: at, updatedAt: at,
            appBundleID: platform.bundleID, sourceRecordID: record,
            notificationIdentity: identity.map { digest($0) }, sourceKey: sourceKey,
            contentHash: digest(
                [title, subtitle, body, chat ?? "", delivered.map(Dates.string) ?? ""].joined(separator: "\u{0}")),
            mediaDirectoryID: platform == .wechat ? chat.map { mediaDirectoryID($0) } : nil)
    }
}
