import Foundation
import Testing

@testable import WeChatListener

@Test("Notification decoding, archive, import/export and MCP")
func archiveIntegration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "wechat-listener-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = Dates.parse("2026-10-15T09:00:00.000+08:00")!
    let metadata = try NSKeyedArchiver.archivedData(
        withRootObject: ["chatname": "fixture-team@chatroom", "unique_id": "fixture-unique-1"],
        requiringSecureCoding: true)
    let blob = try PropertyListSerialization.data(
        fromPropertyList: ["req": ["titl": "测试群", "subt": "测试人", "body": "报价明天确认\n第二行", "usda": metadata]],
        format: .binary, options: 0)
    let row: [String: SQLValue] = [
        "rec_id": .integer(1), "data": .blob(blob), "uuid": .blob(Data([1, 2, 3])),
        "delivered_date": .real(date.timeIntervalSinceReferenceDate),
    ]
    let first = try NotificationDecoder.decode(row, now: date)
    try #require(
        first.body == "报价明天确认\n第二行" && first.conversationKind == "group" && first.senderDisplayName == "测试人",
        "secure keyed archive decoding and field provenance")
    try #require(
        first.conversationIDSource == "notification_chatname" && !first.isCompleteChat && !first.includesSentMessages,
        "explicit notification-only coverage")
    var movedRow = row
    movedRow["rec_id"] = .integer(999)
    try #require(
        try NotificationDecoder.decode(movedRow, now: date).id == first.id,
        "stable notification identity survives record-id changes")
    let fallback = NotificationDecoder.make(
        record: 2, title: "同名测试", subtitle: "", body: "测试", delivered: date, captured: date)
    try #require(
        fallback.conversationKind == "unknown" && fallback.conversationIDSource == "display_title_fallback",
        "missing chatname is explicitly unresolved")
    func display(
        _ body: String, title: String = "项目讨论群", subtitle: String = "", chat: String? = "fixture-team@chatroom"
    ) -> Message {
        NotificationDecoder.make(
            record: 90, title: title, subtitle: subtitle, body: body, chat: chat, delivered: date, captured: date)
    }
    let prefixed = display("张同学: 明天 09:30 开会\n链接：https://example.invalid/a")
    try #require(
        prefixed.presentation.sender == "张同学"
            && prefixed.presentation.body == "明天 09:30 开会\n链接：https://example.invalid/a",
        "group presentation separates sender without damaging multiline content, times or URLs")
    try #require(
        prefixed.body.hasPrefix("张同学: ") && prefixed.presentation.senderSource == "body_prefix_inferred",
        "inferred sender has explicit provenance and raw notification remains intact")
    try #require(display("Alice：收到").presentation.sender == "Alice", "full-width colon sender prefix")
    let duplicate = display("张同学: 收到", subtitle: "张同学")
    try #require(
        duplicate.presentation.body == "收到" && duplicate.presentation.senderSource == "notification_sender",
        "explicit subtitle sender wins and matching duplicate prefix is removed for display")
    try #require(
        display("其他人: 收到", subtitle: "张同学").presentation.body == "其他人: 收到", "conflicting sender prefixes remain in body"
    )
    try #require(
        display("https://example.invalid").presentation.sender == nil && display("09:30 开会").presentation.sender == nil,
        "URLs and times are not parsed as senders")
    try #require(display("明天\n说明: 到场").presentation.sender == nil, "multiline prefix is not guessed as nickname")
    try #require(
        display("[3条] 张同学: 合并通知").presentation.sender == nil,
        "merged notification summary is not attributed to one sender")
    try #require(
        display("备注: 明天开会", title: "同学", chat: "fixture-peer").presentation.body == "备注: 明天开会",
        "direct-message content is never split by sender heuristics")
    let inferred = display("张同学: 收到", chat: nil)
    try #require(
        inferred.conversationKind == "unknown" && inferred.presentation.isInferredGroup
            && inferred.presentation.kindLabel == "疑似群聊",
        "title fallback keeps unknown identity and labels inferred group display")
    try #require(display("普通正文").presentation.sender == nil, "unprovided group sender stays unknown")
    let sourcePath = directory.appendingPathComponent("source.sqlite")
    let fixture = try SQLite(sourcePath.path)
    try fixture.run("CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT)")
    try fixture.run(
        "CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,delivered_date REAL,data BLOB)")
    try fixture.run("INSERT INTO app VALUES(1,'com.tencent.xinWeChat')")
    try fixture.run("INSERT INTO app VALUES(2,'fixture.other.app')")
    try fixture.run(
        "INSERT INTO record VALUES(1,1,?,?,?)",
        [.blob(Data([1, 2, 3])), .real(date.timeIntervalSinceReferenceDate), .blob(blob)])
    try fixture.run("INSERT INTO record VALUES(2,2,NULL,0,NULL)")
    let source = try NotificationSource(url: sourcePath)
    try #require(try source.snapshot().count == 1, "case-insensitive WeChat-only source filtering")
    var writeRejected = false
    do { try source.database.run("DELETE FROM record") } catch { writeRejected = true }
    try #require(
        writeRejected && (try fixture.rows("SELECT COUNT(*) AS n FROM record").first!.int("n")) == 2,
        "source database is enforced read-only")
    let paths = AppPaths(override: directory.appendingPathComponent("archive").path)
    let archive = try Archive(paths: paths)
    try #require(try archive.ingest(first) == "inserted", "initial archive ingestion")
    try #require(try archive.ingest(first) == "unchanged", "replayed notifications deduplicate")
    var changed = first
    changed.body = "报价改到周五确认"
    changed.contentHash = digest("fixture-change")
    changed.updatedAt = Dates.string(date.addingTimeInterval(30))
    try #require(
        try archive.ingest(changed) == "updated" && archive.count() == 1,
        "notification updates preserve a single current message")
    try #require(
        try archive.ingest(first) == "unchanged" && archive.messages().first?.body == changed.body,
        "older imports cannot roll current message content backwards")
    let other = NotificationDecoder.make(
        record: 3, title: "测试群", subtitle: "测试人", body: "另一个同名群", chat: "fixture-other@chatroom",
        identity: "fixture-unique-2", delivered: date.addingTimeInterval(60), captured: date)
    try archive.ingest(other)
    try #require(try archive.conversations().count == 2, "same display names do not merge different known chatnames")
    try #require(try archive.messages(MessageFilter(query: "报价")).count == 1, "short Chinese literal search")
    try #require(try archive.messages(MessageFilter(query: "周五确认")).count == 1, "Chinese full-text search")
    try #require(
        try archive.messages(MessageFilter(query: "' OR 1=1 --")).isEmpty,
        "search SQL injection is treated as literal data")
    try #require(
        try archive.messages(MessageFilter(conversation: first.conversationID)).count == 1,
        "conversation scope is enforced")
    let before = NotificationDecoder.make(
        record: 4, title: "测试群", subtitle: "测试人", body: "之前的消息", chat: "fixture-team@chatroom",
        identity: "fixture-unique-3", delivered: date.addingTimeInterval(-60), captured: date)
    let after = NotificationDecoder.make(
        record: 5, title: "测试群", subtitle: "测试人", body: "之后的消息", chat: "fixture-team@chatroom",
        identity: "fixture-unique-4", delivered: date.addingTimeInterval(120), captured: date)
    try archive.ingest(before)
    try archive.ingest(after)
    let context = try archive.context(messageID: first.id, radius: 1)
    try #require(
        context.map(\.id) == [before.id, first.id, after.id],
        "context stays inside the conversation in chronological order")
    let timeFilter = MessageFilter(from: Dates.string(date), before: Dates.string(date.addingTimeInterval(61)))
    try #require(try archive.count(timeFilter) == 2, "inclusive lower and exclusive upper time bounds")
    try archive.flushJournal()
    func journalEntries() throws -> [[String: Any]] {
        try String(contentsOf: paths.journal, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
    let events = try journalEntries()
    try #require(
        events.count == 5 && Set(events.compactMap { $0["event_id"] as? String }).count == 5,
        "durable journal records insert and update events with stable event IDs")
    try archive.flushJournal()
    try #require(try journalEntries().count == 5, "outbox mirroring is idempotent after success")
    let append = try FileHandle(forWritingTo: paths.journal)
    try append.seekToEnd()
    try append.write(contentsOf: Data("{interrupted".utf8))
    try append.close()
    let last = NotificationDecoder.make(
        record: 6, title: "测试人", subtitle: "", body: "恢复测试", chat: "fixture-peer", identity: "fixture-unique-5",
        delivered: date.addingTimeInterval(180), captured: date)
    try archive.ingest(last)
    try archive.flushJournal()
    try #require(
        try journalEntries().count == 6, "interrupted final JSONL line is recovered without damaging prior entries")
    let exported = directory.appendingPathComponent("export.jsonl")
    let exportedCount = try archive.export(to: exported, filter: MessageFilter(), markdown: false)
    let exportedLines = try String(contentsOf: exported, encoding: .utf8).split(separator: "\n")
    try #require(
        exportedCount == 5 && exportedLines.count == 5,
        "snapshot export emits one valid JSON object per message")
    let imported = try Archive(paths: AppPaths(override: directory.appendingPathComponent("imported").path))
    let importedResult = try imported.importJSONL(from: exported)
    let repeated = try imported.importJSONL(from: exported)
    try #require(
        importedResult.inserted == 5 && repeated.unchanged == 5 && repeated.inserted == 0,
        "structured import is repeatable without duplication")
    let legacyURL = directory.appendingPathComponent("legacy.jsonl")
    let legacy: [String: Any] = [
        "record_id": 8, "app": "com.tencent.xinWeChat", "title": "旧通知", "subtitle": "", "body": "旧版验证数据",
        "captured_at": Dates.string(date), "delivered_at": Dates.string(date),
    ]
    var legacyBytes = try JSONSerialization.data(withJSONObject: legacy)
    legacyBytes.append(10)
    legacyBytes.append(Data("invalid-json\n".utf8))
    try legacyBytes.write(to: legacyURL)
    let legacyResult = try imported.importJSONL(from: legacyURL)
    try #require(
        legacyResult.inserted == 1 && legacyResult.failed == 1,
        "legacy import preserves usable data and reports malformed lines")
    let readOnly = try Archive(paths: paths, readOnly: true)
    writeRejected = false
    do { try readOnly.ingest(fallback) } catch { writeRejected = true }
    try #require(writeRejected, "MCP archive connection cannot write")
    let backup = directory.appendingPathComponent("backup.sqlite")
    try archive.database.backup(to: backup)
    try #require(
        try SQLite(backup.path, readOnly: true).rows("SELECT COUNT(*) AS n FROM messages").first!.int("n") == 5,
        "online SQLite backup includes current WAL data")
    let mode = (try FileManager.default.attributesOfItem(atPath: paths.database.path)[.posixPermissions] as! NSNumber)
        .intValue
    try #require(mode & 0o077 == 0, "archive permissions are owner-only")
    let mcp = MCPServer(paths: paths)
    func rpc(_ id: Int, _ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
        mcp.response(["jsonrpc": "2.0", "id": id, "method": method, "params": params])!
    }
    try #require(rpc(1, "tools/list")["error"] != nil, "MCP rejects tool discovery before initialization")
    let initialized = rpc(
        2, "initialize",
        ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "fixture", "version": "1"]])
    try #require(
        (initialized["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18",
        "MCP protocol initialization")
    let list = rpc(3, "tools/list")["result"] as! [String: Any]
    try #require(
        (list["tools"] as? [[String: Any]])?.count == 16,
        "MCP retains six read-only data tools and adds five scoped reminder tools")
    let tool =
        rpc(4, "tools/call", ["name": "wechat_search_messages", "arguments": ["query": "报价"]])["result"]
        as! [String: Any]
    let structured = tool["structuredContent"] as! [String: Any]
    try #require(
        tool["isError"] as? Bool == false && (structured["messages"] as? [Any])?.count == 1
            && structured["notice"] != nil, "MCP returns structured results with provenance and coverage")
    let invalid =
        rpc(5, "tools/call", ["name": "wechat_search_messages", "arguments": ["limit": true]])["result"]
        as! [String: Any]
    try #require(invalid["isError"] as? Bool == true, "MCP validates booleans versus numeric bounds")
    let extra =
        rpc(6, "tools/call", ["name": "wechat_status", "arguments": ["sql": "DELETE FROM messages"]])["result"]
        as! [String: Any]
    let countAfterRejectedSQL = try archive.count()
    try #require(
        extra["isError"] as? Bool == true && countAfterRejectedSQL == 5,
        "MCP rejects arbitrary SQL and unknown parameters")
    try #require(
        mcp.response(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil,
        "MCP notifications do not emit stdout responses")
    let query = QueryService(paths: paths)
    var rejected = false
    do { _ = try query.call("wechat_search_messages", arguments: ["from": "2026-02-30"]) } catch { rejected = true }
    try #require(rejected, "invalid dates are rejected rather than silently normalized")
    try #require(
        try query.normalizedTime("2026-10-15T09:00:00+08:00", end: false) == Dates.string(date),
        "time zone offsets normalize consistently")
    let recycledArchive = try Archive(paths: AppPaths(override: directory.appendingPathComponent("recycled").path))
    let a = NotificationDecoder.make(
        record: 1, title: "测试", subtitle: "", body: "甲", chat: "fixture-peer", identity: "fixture-a", delivered: date,
        captured: date)
    let b = NotificationDecoder.make(
        record: 1, title: "测试", subtitle: "", body: "乙", chat: "fixture-peer", identity: "fixture-b", delivered: date,
        captured: date)
    try recycledArchive.ingest(a)
    try recycledArchive.ingest(b)
    try #require(
        try recycledArchive.count() == 2, "recycled row IDs do not merge distinct known notification identities")
    try #require(
        try archive.database.rows("SELECT name FROM sqlite_master WHERE name='attachments'").isEmpty,
        "text-only archives do not create attachment storage")
    try archive.database.run("CREATE TABLE attachments(id TEXT, message_id TEXT, local_path TEXT)")
    try archive.database.run(
        "INSERT INTO attachments VALUES('legacy',?,'/synthetic/old-attachment.png')", [.text(first.id)])
    let textOnly = try Archive(paths: paths, readOnly: true)
    let textResult = try textOnly.messageObjects(textOnly.messages())
    try #require(
        textResult.allSatisfy { $0["attachments"] == nil }
            && !(try String(decoding: JSONSerialization.data(withJSONObject: textResult), as: UTF8.self)).contains(
                "/synthetic/old-attachment.png"),
        "old attachment metadata is ignored by text-only MCP without breaking archive reads")
    try #require(display("[图片] ").presentation.body == "[图片] ", "image placeholders are preserved as notification text")
    try archive.clear()
    try #require(
        try archive.count() == 0 && Data(contentsOf: paths.journal).isEmpty && source.snapshot().count == 1,
        "clearing an archive never modifies system-source fixtures")
}
