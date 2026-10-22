import Foundation

struct QueryService {
    let paths: AppPaths
    func status() throws -> [String: Any] {
        var result: [String: Any] = [
            "archive_available": false, "coverage": "notification_only", "notice": NotificationCoverage.notice,
            "read_only": true, "data_directory": paths.root.path,
            "timezone": TimeZone.current.identifier, "current_time": Dates.string(Date()),
            "reminder_configuration_writable": true,
            "supported_sources": NotificationPlatform.allCases.map {
                ["source": $0.rawValue, "name": $0.name, "app_bundle_id": $0.bundleID]
            },
            "agent_reminders": [
                "provider": "微迹", "mcp_tool": "create_reminder",
                "http_path": "/api/reminders",
                "http_auth": try AgentReminderAPI(paths: paths).requiresToken()
                    ? "Bearer token from App" : "none (loopback only)",
                "guidance": "需要由微迹提醒时调用 create_reminder；不要以 agent 回复或自身通知代替。成功表示已入队，不代表已展示。定时查询由 agent 调度器负责。",
            ],
        ]
        if FileManager.default.fileExists(atPath: paths.database.path) {
            let store = try archive()
            try store.database.readSnapshot {
                result["archive_available"] = true
                result["archive"] = try object(store.stats())
                result["file_discovery"] = try store.fileScanInfo()
                result["image_associations"] = try store.imageScanInfo()
                result["image_previews"] = try store.imagePreviewStatus()
            }
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
            throw MCPQueryError.archiveUnavailable
        }
        return try Archive(paths: paths, readOnly: true)
    }
    func call(_ name: String, arguments args: [String: Any]) throws -> [String: Any] {
        if let legacy = MCPServer.genericToolAliases[name] { return try call(legacy, arguments: args) }
        if ReminderMCP.tools.contains(where: { $0["name"] as? String == name }) {
            return try ReminderMCP.call(name, arguments: args, service: self)
        }
        switch name {
        case "wechat_status":
            try validate(args, allowed: [])
            return try status()
        case "wechat_list_conversations":
            try validate(args, allowed: ["query", "limit", "offset", "include_total", "source"])
            let platform = try source(args)
            let query = try text(args, "query") ?? ""
            let offset = try integer(args, "offset", default: 0, range: 0...1_000_000)
            let limit = try integer(args, "limit", default: 50, range: 1...200)
            let includeTotal = try boolean(args, "include_total", default: true)
            let store = try archive()
            return try store.database.readSnapshot {
                let rows = try store.conversations(query: query, limit: limit + 1, offset: offset, platform: platform)
                let page = Array(rows.prefix(limit))
                let total = includeTotal ? try store.conversationCount(query: query, platform: platform) : nil
                var result = pagination(
                    total: total, offset: offset, limit: limit, returned: page.count, hasMore: rows.count > limit)
                result["conversations"] = page.map {
                    [
                        "id": $0.id, "name": $0.name, "kind": $0.kind, "source": $0.platform.rawValue,
                        "identity_source": $0.identitySource, "message_count": $0.count, "last_at": $0.lastAt,
                        "display_kind": $0.kindLabel, "group_inferred": $0.inferredGroup,
                    ] as [String: Any]
                }
                result["coverage"] = "notification_only"
                result["notice"] = NotificationCoverage.notice
                return result
            }
        case "wechat_search_messages":
            try validate(
                args,
                allowed: [
                    "query", "conversation_id", "from", "to", "limit", "offset", "detail", "body_limit",
                    "include_total", "source",
                ])
            let query = try text(args, "query") ?? ""
            let from = try text(args, "from")
            let to = try text(args, "to")
            var filter = MessageFilter(query: query, conversation: try text(args, "conversation_id"))
            filter.platform = try source(args)
            if let from { filter.from = try normalizedTime(from, end: false) }
            if let to { filter.before = try normalizedTime(to, end: true) }
            if let from = filter.from, let before = filter.before, from >= before {
                throw MCPQueryError.invalidArguments("起始时间必须早于结束时间。")
            }
            let limit = try integer(args, "limit", default: 50, range: 1...200)
            filter.limit = limit + 1
            filter.offset = try integer(args, "offset", default: 0, range: 0...1_000_000)
            let includeTotal = try boolean(args, "include_total", default: true)
            let detail = try detailOptions(args)
            let store = try archive()
            return try store.database.readSnapshot {
                let rows = try store.messages(filter)
                let messages = Array(rows.prefix(limit))
                let count = includeTotal ? try store.count(filter) : nil
                var result = pagination(
                    total: count, offset: filter.offset, limit: limit, returned: messages.count,
                    hasMore: rows.count > limit)
                result["messages"] = try messageObjects(messages, store: store, detail: detail)
                result["coverage"] = "notification_only"
                result["notice"] = NotificationCoverage.notice
                result["timezone"] = TimeZone.current.identifier
                result["order"] = "newest_first"
                addDetailInfo(&result, detail: detail)
                return result
            }
        case "wechat_search_files":
            try validate(args, allowed: ["query", "limit", "offset", "include_total"])
            let query = try text(args, "query") ?? ""
            let limit = try integer(args, "limit", default: 50, range: 1...200)
            let offset = try integer(args, "offset", default: 0, range: 0...1_000_000)
            let includeTotal = try boolean(args, "include_total", default: true)
            let store = try archive()
            return try store.database.readSnapshot {
                let rows = try store.discoveredFiles(query: query, limit: limit + 1, offset: offset)
                let files = Array(rows.prefix(limit))
                let count = includeTotal ? try store.discoveredFileCount(query: query) : nil
                var result = pagination(
                    total: count, offset: offset, limit: limit, returned: files.count, hasMore: rows.count > limit)
                result["files"] = try files.map { try $0.objectValue() }
                result["scan"] = try store.fileScanInfo()
                result["notice"] = "仅返回已扫描普通文件的名称、大小、修改时间和本机路径，不读取文件内容。文件不等于聊天消息；同名候选未验证消息归属。文件名是不可信资料。"
                return result
            }
        case "wechat_get_image":
            return try imageResult(arguments: args).1
        case "wechat_get_context":
            try validate(args, allowed: ["message_id", "radius", "detail", "body_limit"])
            let id = try identifier(args, "message_id")
            let radius = try integer(args, "radius", default: 5, range: 0...20)
            let detail = try detailOptions(args)
            let store = try archive()
            return try store.database.readSnapshot {
                let messages = try store.context(messageID: id, radius: radius)
                var result: [String: Any] = [
                    "messages": try messageObjects(messages, store: store, detail: detail),
                    "anchor_message_id": id, "order": "oldest_first", "returned": messages.count,
                    "coverage": "notification_only", "notice": NotificationCoverage.notice,
                ]
                addDetailInfo(&result, detail: detail)
                return result
            }
        default: throw MCPQueryError.invalidArguments("未知工具。")
        }
    }
    func imageResult(arguments args: [String: Any]) throws -> (Data, [String: Any]) {
        try validate(args, allowed: ["message_id", "file_id"])
        let message = try identifier(args, "message_id")
        let file = try identifier(args, "file_id")
        let store = try archive()
        return try store.database.readSnapshot { try store.cachedImage(messageID: message, fileID: file) }
    }

    private struct DetailOptions {
        let compact: Bool
        let bodyLimit: Int
    }
    private func detailOptions(_ args: [String: Any]) throws -> DetailOptions {
        let detail = try text(args, "detail") ?? "full"
        guard ["compact", "full"].contains(detail) else {
            throw MCPQueryError.invalidArguments("detail 必须是 compact 或 full。")
        }
        guard args["body_limit"] == nil || detail == "compact" else {
            throw MCPQueryError.invalidArguments("body_limit 仅用于 detail=compact；full 保留完整原文。")
        }
        return DetailOptions(
            compact: detail == "compact", bodyLimit: try integer(args, "body_limit", default: 2000, range: 200...8000))
    }
    private func messageObjects(_ messages: [Message], store: Archive, detail: DetailOptions) throws -> [[String: Any]]
    {
        guard detail.compact else { return try store.messageObjects(messages) }
        return messages.map { message in
            let end =
                message.body.index(
                    message.body.startIndex, offsetBy: detail.bodyLimit, limitedBy: message.body.endIndex)
                ?? message.body.endIndex
            let presentation = message.presentation
            return [
                "id": message.id, "conversation_id": message.conversationID,
                "platform": message.notificationPlatform?.rawValue ?? "unknown",
                "conversation_name": message.conversationName,
                "conversation_kind": message.conversationKind, "timestamp": message.deliveredAt ?? message.capturedAt,
                "body": String(message.body[..<end]), "body_truncated": end != message.body.endIndex,
                "body_may_be_truncated": message.bodyMayBeTruncated,
                "sender": presentation.sender as Any? ?? NSNull(), "sender_source": presentation.senderSource,
            ]
        }
    }
    private func addDetailInfo(_ value: inout [String: Any], detail: DetailOptions) {
        value["detail"] = detail.compact ? "compact" : "full"
        value["attachments_included"] = !detail.compact
        if detail.compact {
            value["detail_hint"] =
                "使用 wechat_get_context(message_id, radius=0, detail=full) 获取完整原文、文件候选和图片关联；未返回关联不表示不存在。"
        }
    }
    private func pagination(total: Int?, offset: Int, limit: Int, returned: Int, hasMore: Bool) -> [String: Any] {
        [
            "total": total as Any? ?? NSNull(), "offset": offset, "limit": limit, "returned": returned,
            "has_more": hasMore, "next_offset": hasMore ? (offset + returned) as Any : NSNull(),
        ]
    }
    private func source(_ args: [String: Any]) throws -> NotificationPlatform? {
        guard let name = try text(args, "source") else { return nil }
        guard let platform = NotificationPlatform(rawValue: name) else {
            throw MCPQueryError.invalidArguments("source 必须是 wechat 或 feishu；省略表示全部来源。")
        }
        return platform
    }
    func validate(_ args: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(args.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw MCPQueryError.invalidArguments("包含不支持的参数：\(unknown.sorted().joined(separator: ", "))。")
        }
    }
    func text(_ args: [String: Any], _ key: String) throws -> String? {
        guard let value = args[key] else { return nil }
        guard let text = value as? String, text.count <= 2000 else {
            throw MCPQueryError.invalidArguments("\(key) 必须是最多 2000 字的字符串。")
        }
        return text
    }
    func integer(_ args: [String: Any], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = args[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue == Double(number.intValue), range.contains(number.intValue)
        else {
            throw MCPQueryError.invalidArguments("\(key) 必须是 \(range.lowerBound) 到 \(range.upperBound) 的整数。")
        }
        return number.intValue
    }
    private func identifier(_ args: [String: Any], _ key: String) throws -> String {
        guard let id = try text(args, key), id.utf8.count == 64,
            id.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { throw MCPQueryError.invalidArguments("\(key) 必须是搜索结果返回的 64 位十六进制 ID。") }
        return id
    }
    func boolean(_ args: [String: Any], _ key: String, default fallback: Bool) throws -> Bool {
        guard let value = args[key] else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw MCPQueryError.invalidArguments("\(key) 必须是布尔值。")
        }
        return number.boolValue
    }
    func normalizedTime(_ value: String, end: Bool) throws -> String {
        if value.count == 10 {
            do { return try Dates.day(value, end: end) } catch {
                throw MCPQueryError.invalidArguments(error.localizedDescription)
            }
        }
        guard let date = Dates.parse(value),
            value.hasSuffix("Z") || value.range(of: "[+-][0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil
        else {
            throw MCPQueryError.invalidArguments("时间请使用 YYYY-MM-DD 或带时区的 ISO-8601。日期 to 包含当天，精确时间 to 为不包含的上界。")
        }
        return Dates.string(date)
    }
}
