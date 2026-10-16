import AppKit
import Foundation
import Testing

@testable import WeChatListener

private func reminderMessage(_ body: String = "紧急：API 延迟异常 🚨", id: String = UUID().uuidString, date: Date = Date())
    -> Message
{
    NotificationDecoder.make(
        record: 1, title: "生产告警频道", subtitle: "张三", body: body, chat: "synthetic@chatroom",
        identity: id, delivered: date, captured: date)
}

private func reminderRule(_ conditions: [ReminderCondition], all: Bool = true) -> ReminderRule {
    ReminderRule(name: "重要告警", matchAll: all, conditions: conditions)
}

@Test("Reminder conditions combine conversation, sender, content, type and exclusions")
func reminderMultipleDimensions() throws {
    let rule = reminderRule([
        ReminderCondition(field: .conversation, comparison: .equals, value: "生产告警频道"),
        ReminderCondition(field: .sender, comparison: .regex, value: "^(张三|李四)$"),
        ReminderCondition(field: .body, comparison: .regex, value: "紧急|故障"),
        ReminderCondition(field: .body, comparison: .notContains, value: "演练"),
        ReminderCondition(field: .conversationKind, comparison: .equals, value: "群聊"),
    ])
    try rule.validate()
    let matcher = ReminderMatcher()
    #expect(matcher.evaluate([reminderMessage()], rules: [rule]).hits.count == 1)
    #expect(matcher.evaluate([reminderMessage("紧急演练")], rules: [rule]).hits.isEmpty)
    var other = reminderMessage()
    other.senderDisplayName = "王五"
    #expect(matcher.evaluate([other], rules: [rule]).hits.isEmpty)
    other = reminderMessage()
    other.conversationName = "其他频道"
    #expect(matcher.evaluate([other], rules: [rule]).hits.isEmpty)
    var any = rule
    any.matchAll = false
    #expect(matcher.evaluate([other], rules: [any]).hits.count == 1)
    var unknown = reminderMessage()
    unknown.senderDisplayName = nil
    unknown.conversationKind = "unknown"
    for field in [ReminderField.sender, .conversationKind] {
        for comparison in [ReminderComparison.notContains, .notEquals, .notRegex] {
            let exclusion = reminderRule([ReminderCondition(field: field, comparison: comparison, value: "测试")])
            #expect(matcher.evaluate([unknown], rules: [exclusion]).hits.isEmpty)
        }
    }
}

@Test("Regex, literal metacharacters, case options and multiple hits retain their semantics")
func reminderMatchingSemantics() {
    let message = reminderMessage("🚨 API\n延迟 [P1]")
    let contains = reminderRule([ReminderCondition(value: "[P1]")])
    var regex = reminderRule([ReminderCondition(comparison: .regex, value: "(?s)🚨 api.*延迟")])
    regex.name = "API 异常"
    let matcher = ReminderMatcher()
    let hits = matcher.evaluate([message], rules: [contains, regex]).hits
    #expect(hits.count == 1 && hits[0].ruleNames == [contains.name, regex.name])
    #expect(matcher.evaluate([message], rules: [contains, regex]).hits.isEmpty)
    var changed = message
    changed.body += " 更新"
    #expect(matcher.evaluate([changed], rules: [contains, regex]).hits.isEmpty)
    regex.ignoreCase = false
    #expect(ReminderMatcher().evaluate([message], rules: [regex]).hits.isEmpty)
    regex.isEnabled = false
    #expect(ReminderMatcher().evaluate([message], rules: [regex]).hits.isEmpty)
    let negative = reminderRule([ReminderCondition(comparison: .notRegex, value: "(?i)api")])
    #expect(ReminderMatcher().evaluate([message], rules: [negative]).hits.isEmpty)
}

@Test("Invalid and pathological regexes fail safely without stopping other rules")
func reminderRegexLimits() throws {
    let invalid = reminderRule([ReminderCondition(comparison: .regex, value: "[")])
    #expect(throws: ListenerError.self) { try invalid.validate() }
    #expect(throws: ListenerError.self) { try ReminderRule(name: "空条件", conditions: []).validate() }
    let slow = reminderRule([ReminderCondition(comparison: .notRegex, value: "(a+)+$")])
    let good = reminderRule([ReminderCondition(value: "!")])
    let matcher = ReminderMatcher(matchBudget: 0.005)
    let started = ProcessInfo.processInfo.systemUptime
    let result = matcher.evaluate([reminderMessage(String(repeating: "a", count: 10_000) + "!")], rules: [slow, good])
    #expect(ProcessInfo.processInfo.systemUptime - started < 2)
    #expect(result.issues.count == 1)
    #expect(result.hits.count == 1 && result.hits[0].ruleNames == [good.name])
    #expect(matcher.evaluate([reminderMessage("!")], rules: [slow, good]).issues.isEmpty)
    matcher.resetConfiguration()
    #expect(matcher.evaluate([reminderMessage("!")], rules: [slow]).hits.count == 1)
    let long = ReminderMatcher().evaluate([reminderMessage(String(repeating: "a", count: 32_769))], rules: [slow])
    #expect(long.hits.isEmpty && long.issues.count == 1)
}

@Test("Only changed, fresh source notifications become reminder candidates; backfills and repeats do not")
func reminderCaptureEligibility() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = TestSupport.referenceDate
    let sourceURL = root.appendingPathComponent("source.sqlite")
    let source = try SQLite(sourceURL.path)
    try source.run("CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT)")
    try source.run("INSERT INTO app VALUES(1,'com.tencent.xinwechat')")
    try source.run(
        "CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,delivered_date REAL,data BLOB)")
    func insert(_ id: Int64, at date: Date?) throws {
        let bytes = try PropertyListSerialization.data(
            fromPropertyList: ["req": ["titl": "合成频道", "subt": "张三", "body": "紧急", "iden": "synthetic-\(id)"]],
            format: .binary, options: 0)
        try source.run(
            "INSERT INTO record VALUES(?,1,NULL,?,?)",
            [
                .integer(id), date.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null, .blob(bytes),
            ])
    }
    let archive = try Archive(paths: AppPaths(override: root.appendingPathComponent("archive").path))
    try insert(1, at: now.addingTimeInterval(-600))
    try insert(2, at: now.addingTimeInterval(-1))
    try insert(3, at: nil)
    let capture = try NotificationSource(url: sourceURL)
    let first = try capture.capture(to: archive, reminderSince: now.addingTimeInterval(-10), now: now)
    #expect(first.inserted == 3 && first.reminderCandidates.map(\.sourceRecordID) == [2])
    #expect(
        try capture.capture(to: archive, reminderSince: now.addingTimeInterval(-10), now: now).reminderCandidates
            .isEmpty)
    try insert(4, at: now)
    // The default CLI/backfill path never requests candidates, even for fresh inserts.
    #expect(try capture.capture(to: archive, now: now).reminderCandidates.isEmpty)
    try archive.clear()
    #expect(
        try capture.capture(to: archive, reminderSince: now.addingTimeInterval(1), now: now).reminderCandidates.isEmpty)
}

@Test("Reminder preferences migrate, persist and retain the last saved rules after a failed write")
@MainActor
func reminderPreferences() throws {
    let old = try JSONDecoder().decode(
        Preferences.self, from: Data("{\"collectOnLaunch\":false,\"pollSeconds\":2}".utf8))
    #expect(old.reminderSound == nil)
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let model = AppModel(paths: paths, allowNotificationCapture: false)
    defer { model.shutDown() }
    let rule = reminderRule([ReminderCondition(value: "紧急")])
    try model.saveReminderRules([rule])
    #expect(try ReminderRuleStore(paths: paths).load().rules == [rule])
    let mode =
        try FileManager.default.attributesOfItem(atPath: ReminderRuleStore(paths: paths).url.path)[.posixPermissions]
        as? NSNumber
    #expect(mode?.intValue == 0o600)
    try FileManager.default.removeItem(at: ReminderRuleStore(paths: paths).url)
    try FileManager.default.createDirectory(at: ReminderRuleStore(paths: paths).url, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try model.saveReminderRules([]) }
    #expect(model.reminderRules == [rule])
}

@Test("Late reminder results are discarded when rules change or collection stops")
@MainActor
func reminderLifecycle() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(paths: AppPaths(override: root.path), allowNotificationCapture: false)
    defer { model.shutDown() }
    let rule = reminderRule([ReminderCondition(value: "紧急")])
    try model.saveReminderRules([rule])
    model.isCollecting = true
    model.beginReminderSession(at: Date().addingTimeInterval(-1))
    var hits: [ReminderHit] = []
    model.onReminder = { incoming, _ in hits.append(contentsOf: incoming) }
    model.processReminderCandidates([reminderMessage()])
    try model.saveReminderRules([])
    for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(hits.isEmpty)
    try model.saveReminderRules([rule])
    model.processReminderCandidates([reminderMessage()])
    model.stop()
    for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(hits.isEmpty)
    model.isCollecting = true
    model.beginReminderSession(at: Date().addingTimeInterval(-1))
    model.processReminderCandidates([reminderMessage()])
    for _ in 0..<100 where hits.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(hits.count == 1)
    model.processReminderCandidates([reminderMessage(date: Date().addingTimeInterval(-600))])
    for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(hits.count == 1)
}

@Test("Reminder panel stacks matches, floats without activation and retains usable real geometry")
@MainActor
func reminderWindowGeometry() async throws {
    _ = NSApplication.shared
    let controller = ReminderWindowController()
    let hit = ReminderHit(message: reminderMessage(), ruleNames: ["重要告警"])
    // Native layout uses the production factory, without showing a test alert over the user's apps.
    controller.present([hit], sound: false, showWindow: false)
    defer {
        controller.dismiss()
        controller.panel?.close()
    }
    let panel = try #require(controller.panel)
    for _ in 0..<20 {
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(panel.contentView!.bounds.width >= 380 && panel.contentView!.bounds.height >= 150)
    #expect(panel.contentView!.bounds.height <= 190)
    #expect(!panel.styleMask.contains(.titled) && !panel.styleMask.contains(.closable))
    #expect(!panel.isOpaque && panel.backgroundColor.alphaComponent == 0 && panel.hasShadow)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.level == .floating && !panel.hidesOnDeactivate)
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    controller.inbox.append([hit, ReminderHit(message: reminderMessage("第二条"), ruleNames: ["项目消息"])])
    #expect(controller.inbox.hits.count == 2)
    controller.toggleExpanded()
    panel.contentView?.layoutSubtreeIfNeeded()
    #expect(panel.contentView!.bounds.width >= 480)
    controller.snooze(minutes: 5)
    #expect(controller.snoozedUntil != nil && controller.inbox.hits.count == 2 && !panel.isVisible)
    controller.dismiss()
    #expect(controller.inbox.hits.isEmpty && !panel.isVisible)
}

@Test("MCP and GUI share rules, reject stale revisions and preserve unrelated preferences")
@MainActor
func reminderMCPSharedRules() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let model = AppModel(paths: paths, allowNotificationCapture: false)
    defer { model.shutDown() }
    let service = QueryService(paths: paths)
    let initial = try service.call("wechat_list_reminder_rules", arguments: [:])
    let revision = try #require(initial["revision"] as? String)
    let rule = reminderRule([ReminderCondition(field: .sender, comparison: .equals, value: "张三")])
    var preferences = Preferences()
    preferences.mcpPort = 19876
    try preferences.save(paths)
    let before = try Data(contentsOf: paths.preferences)
    let saved = try service.call(
        "wechat_save_reminder_rule",
        arguments: [
            "expected_revision": revision, "rule": ReminderMCP.ruleObject(rule),
        ])
    #expect(model.refreshReminderRules())
    #expect(model.reminderRules.map(\.name) == [rule.name])
    #expect(!model.isCollecting && !FileManager.default.fileExists(atPath: paths.database.path))
    #expect(try Data(contentsOf: paths.preferences) == before)
    #expect(throws: MCPQueryError.self) { try model.saveReminderRules([], expectedRevision: revision) }
    let test = try service.call(
        "wechat_test_reminder_rule",
        arguments: [
            "rule": ReminderMCP.ruleObject(rule), "sample": ["body": "示例", "sender": "张三"],
        ])
    #expect(test["matched"] as? Bool == true && test["saved"] as? Bool == false)
    _ = try service.call(
        "wechat_delete_reminder_rule", arguments: ["id": rule.id.uuidString, "expected_revision": saved["revision"]!])
    #expect(model.refreshReminderRules() && model.reminderRules.isEmpty)
}

@Test("A normal reminder batch evaluates many notifications off the capture path")
func reminderBatchMatching() {
    let rules = (0..<16).map { index in
        ReminderRule(
            name: "合成规则\(index)",
            conditions: [
                ReminderCondition(field: .conversation, comparison: .contains, value: "告警"),
                ReminderCondition(field: .sender, comparison: .regex, value: "^(张三|李四)$"),
                ReminderCondition(comparison: .regex, value: "紧急|故障"),
                ReminderCondition(comparison: .notContains, value: "演练"),
            ])
    }
    let messages = (0..<500).map { reminderMessage(id: "batch-\($0)") }
    let start = ProcessInfo.processInfo.systemUptime
    let matcher = ReminderMatcher()
    let result = matcher.evaluate(messages, rules: rules)
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    #expect(result.hits.count == 500 && result.hits.allSatisfy { $0.ruleNames.count == 16 })
    #expect(result.issues.isEmpty)
    #expect(matcher.evaluate(messages, rules: rules).hits.isEmpty)
    print("Synthetic reminder batch: 500 messages × 16 rules × 4 dimensions, \(String(format: "%.2f", elapsed)) ms")
}
