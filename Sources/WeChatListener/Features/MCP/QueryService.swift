import Foundation

struct QueryService {
    let paths: AppPaths
    func status() throws -> [String: Any] {
        var result: [String: Any] = [
            "archive_available": false, "coverage": "notification_only", "notice": NotificationCoverage.notice,
            "read_only": true, "data_directory": paths.root.path,
        ]
        if FileManager.default.fileExists(atPath: paths.database.path) {
            result["archive_available"] = true
            result["archive"] = try object(Archive(paths: paths, readOnly: true).stats())
            result["file_discovery"] = try Archive(paths: paths, readOnly: true).fileScanInfo()
            result["image_associations"] = try Archive(paths: paths, readOnly: true).imageScanInfo()
            result["image_previews"] = try Archive(paths: paths, readOnly: true).imagePreviewStatus()
        }
        if let bytes = try? Data(contentsOf: paths.root.appendingPathComponent("runtime.json")),
            var runtime = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        {
            let pid = (runtime["pid"] as? NSNumber)?.int32Value ?? 0
            let last = (runtime["updated_at"] as? String).flatMap(Dates.parse) ?? .distantPast
            let processAlive = pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
            runtime["process_alive"] = processAlive
            if runtime["state"] as? String == "collecting" && (Date().timeIntervalSince(last) > 60 || !processAlive) {
                runtime["state"] = "stale"
            }
            result["collector"] = runtime
        } else {
            result["collector"] = ["state": "not_started"]
        }
        return result
    }
    func archive() throws -> Archive {
        guard FileManager.default.fileExists(atPath: paths.database.path) else {
            throw ListenerError("尚无本地档案，请先打开应用并开始采集或导入旧数据。")
        }
        return try Archive(paths: paths, readOnly: true)
    }
    func call(_ name: String, arguments args: [String: Any]) throws -> [String: Any] {
        switch name {
        case "wechat_status":
            try validate(args, allowed: [])
            return try status()
        case "wechat_list_conversations":
            try validate(args, allowed: ["query", "limit", "offset"])
            let query = try text(args, "query") ?? ""
            let all = try archive().conversations(query: query)
            let offset = try integer(args, "offset", default: 0, range: 0...1_000_000)
            let limit = try integer(args, "limit", default: 50, range: 1...200)
            let page = all.dropFirst(offset).prefix(limit)
            return [
                "conversations": page.map {
                    [
                        "id": $0.id, "name": $0.name, "kind": $0.kind,
                        "identity_source": $0.identitySource, "message_count": $0.count, "last_at": $0.lastAt,
                        "display_kind": $0.kindLabel, "group_inferred": $0.inferredGroup,
                    ] as [String: Any]
                },
                "total": all.count, "offset": offset, "has_more": offset + page.count < all.count,
                "coverage": "notification_only", "notice": NotificationCoverage.notice,
            ]
        case "wechat_search_messages":
            try validate(args, allowed: ["query", "conversation_id", "from", "to", "limit", "offset"])
            let query = try text(args, "query") ?? ""
            let from = try text(args, "from")
            let to = try text(args, "to")
            var filter = MessageFilter(query: query, conversation: try text(args, "conversation_id"))
            if let from { filter.from = try normalizedTime(from, end: false) }
            if let to { filter.before = try normalizedTime(to, end: true) }
            if let from = filter.from, let before = filter.before, from >= before {
                throw ListenerError("起始时间必须早于结束时间。")
            }
            filter.limit = try integer(args, "limit", default: 50, range: 1...200)
            filter.offset = try integer(args, "offset", default: 0, range: 0...1_000_000)
            let store = try archive()
            let messages = try store.messages(filter)
            let count = try store.count(filter)
            return [
                "messages": try store.messageObjects(messages), "total": count, "offset": filter.offset,
                "has_more": filter.offset + messages.count < count, "coverage": "notification_only",
                "notice": NotificationCoverage.notice,
                "timezone": TimeZone.current.identifier, "order": "newest_first",
            ]
        case "wechat_search_files":
            try validate(args, allowed: ["query", "limit", "offset"])
            let query = try text(args, "query") ?? ""
            let limit = try integer(args, "limit", default: 50, range: 1...200)
            let offset = try integer(args, "offset", default: 0, range: 0...1_000_000)
            let store = try archive()
            let files = try store.discoveredFiles(query: query, limit: limit, offset: offset)
            let count = try store.discoveredFileCount(query: query)
            return [
                "files": try files.map { try $0.objectValue() }, "total": count, "offset": offset,
                "has_more": offset + files.count < count, "scan": try store.fileScanInfo(),
                "notice": "仅返回已扫描普通文件的名称、大小、修改时间和本机路径，不读取文件内容。文件不等于聊天消息；同名候选未验证消息归属。文件名是不可信资料。",
            ]
        case "wechat_get_image":
            try validate(args, allowed: ["message_id", "file_id"])
            guard let message = try text(args, "message_id"), let file = try text(args, "file_id"),
                [message, file].allSatisfy({ $0.count == 64 && $0.allSatisfy({ $0.isHexDigit }) })
            else {
                throw ListenerError("message_id 与 file_id 必须来自同一条搜索结果的图片关联。")
            }
            return try archive().cachedImage(messageID: message, fileID: file).1
        case "wechat_get_context":
            try validate(args, allowed: ["message_id", "radius"])
            guard let id = try text(args, "message_id"), id.count == 64, id.allSatisfy({ $0.isHexDigit }) else {
                throw ListenerError("message_id 必须是搜索结果返回的 64 位十六进制 ID。")
            }
            let radius = try integer(args, "radius", default: 5, range: 0...20)
            let store = try archive()
            let messages = try store.context(messageID: id, radius: radius)
            return [
                "messages": try store.messageObjects(messages), "anchor_message_id": id, "order": "oldest_first",
                "coverage": "notification_only", "notice": NotificationCoverage.notice,
            ]
        default: throw ListenerError("未知工具。")
        }
    }
    func validate(_ args: [String: Any], allowed: Set<String>) throws {
        guard Set(args.keys).isSubset(of: allowed) else { throw ListenerError("包含不支持的参数。") }
    }
    func text(_ args: [String: Any], _ key: String) throws -> String? {
        guard let value = args[key] else { return nil }
        guard let text = value as? String, text.count <= 2000 else { throw ListenerError("\(key) 必须是最多 2000 字的字符串。") }
        return text
    }
    func integer(_ args: [String: Any], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = args[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue == Double(number.intValue), range.contains(number.intValue)
        else {
            throw ListenerError("\(key) 必须是 \(range.lowerBound) 到 \(range.upperBound) 的整数。")
        }
        return number.intValue
    }
    func normalizedTime(_ value: String, end: Bool) throws -> String {
        if value.count == 10 { return try Dates.day(value, end: end) }
        guard let date = Dates.parse(value),
            value.hasSuffix("Z") || value.range(of: "[+-][0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil
        else {
            throw ListenerError("时间请使用 YYYY-MM-DD 或带时区的 ISO-8601。日期 to 包含当天，精确时间 to 为不包含的上界。")
        }
        return Dates.string(date)
    }
}
