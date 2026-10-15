import Foundation
import Testing

@testable import WeChatListener

private func queryMessage(
    _ record: Int64, chat: String = "query-group@chatroom", body: String = "合成正文", seconds: Double = 0,
    title: String = "查询测试群"
) -> Message {
    NotificationDecoder.make(
        record: record, title: title, subtitle: "", body: body, chat: chat,
        delivered: TestSupport.referenceDate.addingTimeInterval(seconds), captured: TestSupport.referenceDate)
}

@Test("Compact discovery preserves citation IDs, marks truncation, and retrieves full evidence on demand")
func mcpCompactDiscovery() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let writer = try Archive(paths: paths)
    let original = queryMessage(1, body: "测试人: " + String(repeating: "👨‍👩‍👧‍👦通知资料", count: 100))
    try writer.ingest(original)
    let service = QueryService(paths: paths)
    let compact = try service.call(
        "wechat_search_messages", arguments: ["detail": "compact", "body_limit": 200, "include_total": false])
    let message = try #require((compact["messages"] as? [[String: Any]])?.first)
    #expect(message["id"] as? String == original.id)
    #expect(message["conversation_id"] as? String == original.conversationID)
    #expect(message["timestamp"] as? String == original.deliveredAt)
    #expect(message["body"] as? String == String(original.body.prefix(200)))
    #expect(message["body_truncated"] as? Bool == true && message["body_may_be_truncated"] as? Bool == true)
    #expect(message["sender"] as? String == "测试人" && message["sender_source"] as? String == "body_prefix_inferred")
    #expect(message["image_associations"] == nil && message["file_candidates"] == nil)
    #expect(compact["attachments_included"] as? Bool == false && compact["detail_hint"] != nil)
    #expect(compact["total"] is NSNull && compact["next_offset"] is NSNull)
    let full = try service.call("wechat_get_context", arguments: ["message_id": original.id, "radius": 0])
    let restored = try #require((full["messages"] as? [[String: Any]])?.first)
    #expect(restored["body"] as? String == original.body)
    #expect(restored["file_candidates"] != nil && restored["image_associations"] != nil)
    #expect(full["detail"] as? String == "full" && full["attachments_included"] as? Bool == true)
    let normal = try service.call("wechat_search_messages", arguments: [:])
    #expect((normal["messages"] as? [[String: Any]])?.first?["source_record_id"] != nil)
    #expect(normal["total"] as? Int == 1)
}

@Test("Conversation pagination uses the latest title and deterministic timestamp ties")
func mcpConversationPagination() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try Archive(paths: AppPaths(override: root.path))
    try archive.ingest(queryMessage(1, seconds: -1, title: "旧名称"))
    try archive.ingest(queryMessage(2, seconds: 2, title: "新名称"))
    try archive.ingest(queryMessage(3, chat: "peer-a", seconds: 2, title: "同名"))
    try archive.ingest(queryMessage(4, chat: "peer-b", seconds: 2, title: "同名"))
    #expect(try archive.conversationCount(query: "旧名称") == 0)
    #expect(try archive.conversationCount(query: "新名称") == 1)
    #expect(try archive.conversations(query: "新名称", limit: 1).first?.count == 2)
    let service = QueryService(paths: archive.paths)
    let expected = try archive.conversations().map(\.id)
    var collected = [String]()
    for offset in 0..<3 {
        let page = try service.call(
            "wechat_list_conversations", arguments: ["limit": 1, "offset": offset, "include_total": false])
        collected += (page["conversations"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        #expect(page["total"] is NSNull && page["returned"] as? Int == 1)
        #expect(page["has_more"] as? Bool == (offset < 2))
        if offset < 2 {
            #expect(page["next_offset"] as? Int == offset + 1)
        } else {
            #expect(page["next_offset"] is NSNull)
        }
    }
    #expect(collected == expected && Set(collected).count == 3)
    let absent = try service.call("wechat_list_conversations", arguments: ["offset": 9])
    #expect(absent["returned"] as? Int == 0 && absent["total"] as? Int == 3)
}

@Test("Indexed context preserves chronological ordering, tie breaks and conversation isolation")
func mcpIndexedContext() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try Archive(paths: AppPaths(override: root.path))
    var messages = [Message]()
    for index in 0..<12 {
        let message = queryMessage(Int64(index), seconds: Double(index / 3))
        messages.append(message)
        try archive.ingest(message)
        try archive.ingest(queryMessage(Int64(100 + index), chat: "other", seconds: Double(index / 3)))
    }
    let ordered = messages.sorted { ($0.deliveredAt!, $0.id) < ($1.deliveredAt!, $1.id) }
    let reader = try Archive(paths: archive.paths, readOnly: true)
    for index in ordered.indices {
        for radius in [0, 1, 5, 20] {
            let actual = try reader.context(messageID: ordered[index].id, radius: radius)
            #expect(
                actual.map(\.id) == ordered[max(0, index - radius)...min(ordered.count - 1, index + radius)].map(\.id))
        }
    }
    #expect(throws: ListenerError.self) { try reader.context(messageID: String(repeating: "f", count: 64), radius: 0) }
    // Older archives still work before the GUI has created the additional context index.
    try archive.database.run("DROP INDEX messages_context")
    #expect(try reader.context(messageID: ordered[5].id, radius: 1).map(\.id) == ordered[4...6].map(\.id))
}

@Test("Request snapshots remain consistent across concurrent collection and release after failure")
func mcpReadSnapshots() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try Archive(paths: AppPaths(override: root.path))
    try writer.ingest(queryMessage(1))
    let reader = try Archive(paths: writer.paths, readOnly: true)
    try reader.database.readSnapshot {
        #expect(try reader.count() == 1)
        try writer.ingest(queryMessage(2))
        #expect(try reader.database.readSnapshot { try reader.count() } == 1)
    }
    #expect(try reader.count() == 2)
    #expect(throws: ListenerError.self) {
        try reader.database.readSnapshot {
            _ = try reader.count()
            throw ListenerError("Synthetic read failure")
        }
    }
    try writer.ingest(queryMessage(3))
    #expect(try reader.database.readSnapshot { try reader.count() } == 3)
    #expect(throws: ListenerError.self) { try reader.database.run("DELETE FROM messages") }
}

@Test("Maximum-size pages use bounded lookahead for messages and ordinary files")
func mcpPageBoundaries() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try Archive(paths: AppPaths(override: root.appendingPathComponent("archive").path))
    let folder = root.appendingPathComponent("account/msg/file")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<201 {
        try archive.ingest(queryMessage(Int64(index), seconds: Double(index)))
        try Data("Synthetic file".utf8).write(to: folder.appendingPathComponent("file-\(index).pdf"))
    }
    _ = try archive.scanFiles(in: folder)
    let service = QueryService(paths: archive.paths)
    for tool in ["wechat_search_messages", "wechat_search_files"] {
        let page = try service.call(tool, arguments: ["limit": 200, "include_total": false])
        #expect(page["returned"] as? Int == 200 && page["has_more"] as? Bool == true)
        #expect(page["next_offset"] as? Int == 200 && page["total"] is NSNull)
        let last = try service.call(tool, arguments: ["limit": 200, "offset": 200, "include_total": false])
        #expect(last["returned"] as? Int == 1 && last["has_more"] as? Bool == false)
        #expect(last["next_offset"] is NSNull)
        let empty = try service.call(tool, arguments: ["offset": 500])
        #expect(empty["returned"] as? Int == 0 && empty["total"] as? Int == 201)
    }
}

@Test("Actionable MCP errors distinguish invalid input from a missing archive without creating data")
func mcpActionableErrors() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.appendingPathComponent("absent").path)
    let server = MCPServer(paths: paths, initialized: true)
    func call(_ args: [String: Any]) throws -> [String: Any] {
        let response = server.response([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "wechat_search_messages", "arguments": args],
        ])!
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let value = try #require(result["structuredContent"] as? [String: Any])
        let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary == value as NSDictionary)
        return try #require(value["error"] as? [String: Any])
    }
    for args: [String: Any] in [
        ["detail": "summary"], ["body_limit": 1000], ["include_total": 1], ["include_total": "false"],
        ["detail": "compact", "body_limit": true], ["from": "2026-02-30"], ["limit": true], ["sql": "anything"],
    ] {
        let error = try call(args)
        #expect(error["code"] as? String == "invalid_arguments" && error["retryable"] as? Bool == false)
        #expect(error["next_action"] != nil)
    }
    #expect(try call([:])["code"] as? String == "archive_not_available")
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))
}
