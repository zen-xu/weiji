import Darwin
import Foundation

/// Durable local outbox. Retains completed request IDs for 30 days to make retries safe.
struct AgentReminderAPI {
    struct Item: Codable {
        var requestID: String
        var title: String
        var body: String
        var sourceMessageIDs: [String]?
        var deliveredAt: Date?
    }
    private static let lock = NSLock()
    let paths: AppPaths
    var tokenURL: URL { paths.root.appendingPathComponent("agent-api-token") }
    private var queueURL: URL { paths.root.appendingPathComponent("agent-reminders.json") }

    private func acquireFileLock() throws -> Int32 {
        try FileManager.default.createDirectory(
            at: paths.root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(
            paths.root.appendingPathComponent("agent-reminders.lock").path,
            O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ListenerError("无法锁定 Agent 提醒队列。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ListenerError("Agent 提醒队列正忙，请稍后使用相同 request_id 重试。")
        }
        return descriptor
    }
    private func releaseFileLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
    func token() throws -> String {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let descriptor = try acquireFileLock()
        defer { releaseFileLock(descriptor) }
        return try tokenUnlocked()
    }
    private func tokenUnlocked() throws -> String {
        if FileManager.default.fileExists(atPath: tokenURL.path) {
            let token = try String(contentsOf: tokenURL, encoding: .utf8)
            guard token.count == 64 else { throw ListenerError("Agent API token 无效。") }
            return token
        }
        try paths.prepare()
        let token =
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try write(Data(token.utf8), to: tokenURL)
        return token
    }
    private func write(_ data: Data, to url: URL) throws {
        // Apply protection before writing any sensitive content, including temporary files.
        let temporary = paths.root.appendingPathComponent(".agent-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        else {
            throw ListenerError("无法保存 Agent 提醒。")
        }
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else { throw ListenerError("无法保存 Agent 提醒。") }
    }
    private func load() throws -> [Item] {
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        guard (try queueURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 24 * 1024 * 1024 else {
            throw ListenerError("Agent 提醒队列过大。")
        }
        return try JSONDecoder().decode([Item].self, from: Data(contentsOf: queueURL))
    }
    func pending() throws -> [Item] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try load().filter { $0.deliveredAt == nil }
    }
    func delivered(_ id: String) throws { try delivered([id]) }
    func delivered(_ ids: [String]) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let descriptor = try acquireFileLock()
        defer { releaseFileLock(descriptor) }
        let completed = Set(ids)
        var items = try load()
        for index in items.indices where completed.contains(items[index].requestID) {
            items[index].deliveredAt = Date()
        }
        try write(JSONEncoder().encode(items), to: queueURL)
    }
    /// MCP callers already use the local MCP trust boundary; never return the HTTP credential.
    func create(arguments: [String: Any]) throws -> [String: Any] {
        let request = MCPHTTPRequest(
            method: "POST", path: "/api/reminders",
            headers: ["authorization": "Bearer \(try token())", "content-type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: arguments))
        let reply = response(to: request)
        let value = try JSONSerialization.jsonObject(with: reply.body) as? [String: Any] ?? [:]
        guard reply.status == 200 || reply.status == 202 else {
            if reply.status == 400 || reply.status == 409 {
                throw MCPQueryError.invalidArguments(value["error"] as? String ?? "提醒参数无效。")
            }
            throw ListenerError("微迹尚未接收提醒：\(value["error"] as? String ?? "storage_unavailable")。请勿声称已经通知。")
        }
        return value.merging([
            "delivery_provider": "weiji", "delivery_state": "queued",
            "notice": "微迹已接收并持久化提醒，运行中的 App 将负责展示；此响应不证明浮窗已显示。不要用 agent 的回复或其自身通知代替微迹提醒。",
        ]) { _, new in new }
    }
    func response(to request: MCPHTTPRequest) -> MCPHTTPResponse {
        guard request.method == "POST" else { return MCPHTTPResponse(status: 405, headers: ["Allow": "POST"]) }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        do {
            let descriptor = try acquireFileLock()
            defer { releaseFileLock(descriptor) }
            guard request.headers["authorization"] == "Bearer \(try tokenUnlocked())" else {
                return .json(["error": "unauthorized"], status: 401)
            }
            guard
                request.headers["content-type"]?.split(separator: ";").first?
                    .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
            else {
                return MCPHTTPResponse(status: 415)
            }
            guard request.body.count <= 24_000,
                let args = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                Set(args.keys).isSubset(of: ["request_id", "title", "body", "source_message_ids"]),
                let id = args["request_id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                id.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                        || [45, 46, 58, 95].contains($0)
                }),
                let title = args["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                title.count <= 200,
                let body = args["body"] as? String, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                body.count <= 4000
            else { return .json(["error": "invalid_arguments"], status: 400) }
            let sources = args["source_message_ids"] as? [String]
            if args["source_message_ids"] != nil
                && (sources == nil || sources!.count > 20 || sources!.contains(where: { $0.isEmpty || $0.count > 128 }))
            {
                return .json(["error": "invalid_source_message_ids"], status: 400)
            }
            var items = try load().filter {
                $0.deliveredAt == nil || $0.deliveredAt! > Date().addingTimeInterval(-30 * 86400)
            }
            if let existing = items.first(where: { $0.requestID == id }) {
                guard existing.title == title, existing.body == body, existing.sourceMessageIDs == sources else {
                    return .json(["error": "request_id_conflict"], status: 409)
                }
                return .json(["request_id": id, "status": "accepted", "duplicate": true])
            }
            guard items.count < 1000 else { return .json(["error": "queue_full"], status: 503) }
            items.append(Item(requestID: id, title: title, body: body, sourceMessageIDs: sources))
            try write(JSONEncoder().encode(items), to: queueURL)
            return .json(["request_id": id, "status": "accepted", "duplicate": false], status: 202)
        } catch { return .json(["error": "storage_unavailable"], status: 503) }
    }
}
