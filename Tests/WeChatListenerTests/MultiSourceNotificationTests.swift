import Foundation
import Testing

@testable import WeChatListener

@Test("WeChat and Feishu notification identity, conversations and queries stay separate")
func multiSourceNotificationIsolation() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("notifications.sqlite")
    let database = try SQLite(sourceURL.path)
    try database.run("CREATE TABLE app(app_id INTEGER,identifier TEXT)")
    try database.run("CREATE TABLE record(rec_id INTEGER,app_id INTEGER,uuid BLOB,delivered_date REAL,data BLOB)")
    for (id, bundle) in [(1, "com.tencent.xinwechat"), (2, "com.electron.lark"), (3, "other.app")] {
        try database.run("INSERT INTO app VALUES(?,?)", [.integer(Int64(id)), .text(bundle)])
        let payload = try PropertyListSerialization.data(
            fromPropertyList: [
                "req": ["titl": "同名项目群", "subt": "", "body": "张三: 请确认", "usda": ["chatname": "fake@chatroom"]]
            ], format: .binary, options: 0)
        try database.run(
            "INSERT INTO record VALUES(?,?,?, ?,?)",
            [
                .integer(Int64(id)), .integer(Int64(id)), .blob(Data([1, 2, 3])),
                .real(TestSupport.referenceDate.timeIntervalSinceReferenceDate), .blob(payload),
            ])
    }
    let paths = AppPaths(override: root.appendingPathComponent("archive").path)
    let archive = try Archive(paths: paths)
    let first = try NotificationSource(url: sourceURL).capture(to: archive)
    #expect(first.sourceRows == 2 && first.inserted == 2 && first.failed == 0)
    #expect(try NotificationSource(url: sourceURL).capture(to: archive).reusedRows == 2)
    let messages = try archive.messages()
    #expect(Set(messages.map(\.id)).count == 2)
    #expect(Set(messages.map(\.conversationID)).count == 2)
    let feishu = try #require(messages.first { $0.notificationPlatform == .feishu })
    #expect(feishu.conversationKind == "unknown")
    #expect(feishu.conversationIDSource == "display_title_fallback")
    #expect(feishu.mediaDirectoryID == nil)
    #expect(feishu.presentation.sender == nil && !feishu.presentation.isInferredGroup)
    #expect(feishu.presentation.body == "张三: 请确认")
    #expect(try archive.fileCandidates(for: feishu).isEmpty)
    #expect(try archive.imageAssociations(for: feishu).isEmpty)
    #expect(try archive.conversations(platform: .feishu).count == 1)
    #expect(try archive.conversationCount(platform: .wechat) == 1)
    #expect(try archive.conversationCount(query: "同名", platform: .feishu) == 1)
    #expect(try archive.messages(MessageFilter(platform: .feishu)).map(\.id) == [feishu.id])
    let service = QueryService(paths: paths)
    let queried = try service.call(
        "notifications_search_messages", arguments: ["source": "feishu", "detail": "compact"])
    let values = try #require(queried["messages"] as? [[String: Any]])
    #expect(values.count == 1 && values.first?["platform"] as? String == "feishu")
    let conversations = try service.call("notifications_list_conversations", arguments: ["source": "wechat"])
    #expect((conversations["conversations"] as? [[String: Any]])?.first?["source"] as? String == "wechat")
    #expect(throws: MCPQueryError.self) {
        try service.call("notifications_search_messages", arguments: ["source": "unknown"])
    }
    let context = try service.call("notifications_get_context", arguments: ["message_id": feishu.id, "radius": 20])
    #expect((context["messages"] as? [[String: Any]])?.count == 1)
    var fileNotice = feishu
    fileNotice.body = "[文件] 文档.pdf"
    #expect(try archive.fileCandidates(for: fileNotice).isEmpty)
    let exported = root.appendingPathComponent("notifications.jsonl")
    #expect(try archive.export(to: exported, filter: MessageFilter(), markdown: false) == 2)
    let restored = try Archive(paths: AppPaths(override: root.appendingPathComponent("restored").path))
    #expect(try restored.importJSONL(from: exported).inserted == 2)
    #expect(try restored.conversations(platform: .feishu).count == 1)
    #expect(try restored.messages(MessageFilter(platform: .feishu)).first?.id == feishu.id)
    // Existing WeChat identity is unchanged by adding another notification source.
    let legacy = NotificationDecoder.make(
        record: 1, title: "同名项目群", subtitle: "", body: "张三: 请确认", chat: "fake@chatroom",
        identity: Data([1, 2, 3]).base64EncodedString(), delivered: TestSupport.referenceDate, captured: Date())
    #expect(messages.contains { $0.id == legacy.id && $0.conversationID == legacy.conversationID })
}

@Test("Existing rules stay WeChat-only and new Feishu quick rules keep source scope")
func multiSourceReminderRules() throws {
    let now = Date()
    let wechat = NotificationDecoder.make(
        record: 1, title: "同名", subtitle: "", body: "提醒", delivered: now, captured: now)
    let feishu = NotificationDecoder.make(
        record: 1, title: "同名", subtitle: "", body: "提醒", delivered: now, captured: now, platform: .feishu)
    let rule = ReminderRule(
        name: "旧规则", conditions: [ReminderCondition(field: .body, comparison: .contains, value: "提醒")])
    var encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
    encoded.removeValue(forKey: "sources")
    let migrated = try JSONDecoder().decode(ReminderRule.self, from: JSONSerialization.data(withJSONObject: encoded))
    #expect(migrated.sources == [.wechat])
    #expect(ReminderMatcher().evaluate([wechat, feishu], rules: [migrated]).hits.map(\.id) == [wechat.id])
    let quick = try #require(ReminderQuickRule.make(message: feishu, kind: .conversation))
    #expect(quick.sources == [.feishu])
    #expect(ReminderMatcher().evaluate([wechat, feishu], rules: [quick]).hits.map(\.id) == [feishu.id])
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = QueryService(paths: AppPaths(override: root.path))
    let test = try service.call(
        "wechat_test_reminder_rule",
        arguments: [
            "rule": ReminderMCP.ruleObject(quick),
            "sample": ["conversation": "同名", "body": "提醒", "source": "feishu"],
        ])
    #expect(test["matched"] as? Bool == true)
    let wrongSource = try service.call(
        "wechat_test_reminder_rule",
        arguments: [
            "rule": ReminderMCP.ruleObject(quick), "sample": ["conversation": "同名", "body": "提醒"],
        ])
    #expect(wrongSource["matched"] as? Bool == false)
    let store = ReminderRuleStore(paths: service.paths)
    let snapshot = try store.save([quick], expectedRevision: "initial")
    var legacyEdit = ReminderMCP.ruleObject(quick)
    legacyEdit.removeValue(forKey: "sources")
    _ = try service.call(
        "wechat_save_reminder_rule", arguments: ["rule": legacyEdit, "expected_revision": snapshot.revision])
    #expect(try store.load().rules.first?.sources == [.feishu])
    var changed = quick
    changed.sources = [.wechat]
    #expect(!changed.hasSameContent(as: quick))
}
