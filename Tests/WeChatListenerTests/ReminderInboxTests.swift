import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WeChatListener

private func inboxMessage(_ id: String = UUID().uuidString, conversation: String = "合成项目群", body: String = "@所有人 合成通知")
    -> Message
{
    NotificationDecoder.make(
        record: 1, title: conversation, subtitle: "合成发送者", body: body,
        chat: conversation + "@chatroom", identity: id, delivered: TestSupport.referenceDate,
        captured: TestSupport.referenceDate)
}
private func inboxHit(_ rule: ReminderRule, id: String = UUID().uuidString, conversation: String = "合成项目群")
    -> ReminderHit
{
    ReminderHit(message: inboxMessage(id, conversation: conversation), ruleNames: [rule.name], ruleIDs: [rule.id])
}
private func inboxCalendar(_ zone: String = "Asia/Shanghai") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}

@Test("Reminder quiet hours support midnight, exact boundaries and DST")
func reminderQuietHoursBoundaries() throws {
    let c = inboxCalendar()
    let q = ReminderQuietHours(startMinute: 22 * 60, endMinute: 8 * 60)
    for (time, expected) in [
        ("2026-10-17T21:59:59+08:00", "2026-10-17T21:59:59+08:00"),
        ("2026-10-17T22:00:00+08:00", "2026-10-18T08:00:00+08:00"),
        ("2026-10-18T01:00:00+08:00", "2026-10-18T08:00:00+08:00"),
        ("2026-10-18T08:00:00+08:00", "2026-10-18T08:00:00+08:00"),
    ] { #expect(q.nextAllowedDate(after: Dates.parse(time)!, calendar: c) == Dates.parse(expected)!) }
    let daytime = ReminderQuietHours(startMinute: 9 * 60, endMinute: 17 * 60)
    #expect(
        daytime.nextAllowedDate(after: Dates.parse("2026-10-17T10:00:00+08:00")!, calendar: c) == Dates.parse(
            "2026-10-17T17:00:00+08:00")!)
    let dst = ReminderQuietHours(startMinute: 22 * 60, endMinute: 2 * 60 + 30)
    #expect(
        dst.nextAllowedDate(
            after: Dates.parse("2026-03-08T01:00:00-05:00")!, calendar: inboxCalendar("America/New_York"))
            == Dates.parse("2026-03-08T03:00:00-04:00")!)
    #expect(throws: ListenerError.self) { try ReminderQuietHours(startMinute: 1, endMinute: 1).validate() }
    #expect(throws: ListenerError.self) { try ReminderQuietHours(startMinute: -1, endMinute: 5).validate() }
}

@Test("Reminder inbox restores unread, handled, snoozed and cooldown state after restart")
@MainActor func reminderInboxPersistence() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    var rule = ReminderRule(name: "合成提醒", conditions: [ReminderCondition(value: "通知")])
    rule.minimumIntervalSeconds = 300
    let first = inboxHit(rule, id: "first")
    let second = inboxHit(rule, id: "second")
    let now = TestSupport.referenceDate
    let inbox = ReminderInbox(paths: paths)
    inbox.append([first, second], rules: [rule], now: now)
    #expect(inbox.takeDue(rules: [rule], now: now).count == 2)
    inbox.handle(first.id, now: now)
    inbox.snooze(second.id, until: now.addingTimeInterval(600))
    inbox.flush()
    let restored = ReminderInbox(paths: paths)
    #expect(restored.issue == nil && restored.count == 1 && restored.entries.count == 2)
    #expect(restored.entries.first(where: { $0.id == first.id })?.isHandled == true)
    #expect(restored.takeDue(rules: [rule], now: now.addingTimeInterval(599)).isEmpty)
    #expect(restored.takeDue(rules: [rule], now: now.addingTimeInterval(600)).count == 1)
    restored.append([first], rules: [rule], now: now.addingTimeInterval(700))
    #expect(restored.count == 1)  // Source updates do not resurrect handled records.
    restored.flush()
    let mode =
        try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("reminder-inbox.json").path)[
            .posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
}

@Test("Reminder delivery coalesces per rule and conversation without dropping quiet-hour messages")
@MainActor func reminderInboxDelivery() throws {
    let c = inboxCalendar()
    let now = Dates.parse("2026-10-17T21:59:00+08:00")!
    var rule = ReminderRule(name: "合成提醒", conditions: [ReminderCondition(value: "通知")])
    rule.minimumIntervalSeconds = 300
    rule.quietHours = ReminderQuietHours()
    let inbox = ReminderInbox()
    inbox.append([inboxHit(rule)], rules: [rule], now: now, calendar: c)
    #expect(inbox.takeDue(rules: [rule], now: now, calendar: c).count == 1)
    inbox.append([inboxHit(rule), inboxHit(rule)], rules: [rule], now: now.addingTimeInterval(10), calendar: c)
    #expect(inbox.takeDue(rules: [rule], now: now.addingTimeInterval(10), calendar: c).isEmpty)
    #expect(inbox.nextDue == Dates.parse("2026-10-18T08:00:00+08:00")!)
    // Another conversation has an independent interval.
    inbox.append([inboxHit(rule, conversation: "另一个合成群")], rules: [rule], now: now.addingTimeInterval(20), calendar: c)
    #expect(inbox.takeDue(rules: [rule], now: now.addingTimeInterval(20), calendar: c).count == 1)
    #expect(inbox.takeDue(rules: [rule], now: Dates.parse("2026-10-18T07:59:59+08:00")!, calendar: c).isEmpty)
    #expect(inbox.takeDue(rules: [rule], now: Dates.parse("2026-10-18T08:00:00+08:00")!, calendar: c).count == 2)
    #expect(inbox.count == 4)
    let another = inboxHit(rule)
    inbox.append([another], rules: [rule], now: Dates.parse("2026-10-18T08:00:01+08:00")!, calendar: c)
    rule.isEnabled = false
    #expect(inbox.takeDue(rules: [rule], now: Dates.parse("2026-10-18T08:10:00+08:00")!, calendar: c).isEmpty)
    #expect(inbox.count == 5 && inbox.nextDue == nil)
}

@Test("Reminder snooze includes newly arriving messages and survives restart; corrupt files are preserved")
@MainActor func reminderInboxSnoozeAndCorruption() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let now = TestSupport.referenceDate
    let rule = ReminderRule(name: "合成规则", conditions: [ReminderCondition(value: "通知")])
    let inbox = ReminderInbox(paths: paths)
    inbox.append([inboxHit(rule)], rules: [rule], now: now)
    _ = inbox.takeDue(rules: [rule], now: now)
    inbox.snooze(until: now.addingTimeInterval(600))
    inbox.flush()
    let restored = ReminderInbox(paths: paths)
    restored.append([inboxHit(rule)], rules: [rule], now: now.addingTimeInterval(100))
    #expect(restored.takeDue(rules: [rule], now: now.addingTimeInterval(100)).isEmpty)
    #expect(restored.takeDue(rules: [rule], now: now.addingTimeInterval(600)).count == 2)
    restored.flush()
    let file = root.appendingPathComponent("reminder-inbox.json")
    let damaged = Data("broken-synthetic".utf8)
    try damaged.write(to: file)
    let failed = ReminderInbox(paths: paths)
    #expect(failed.issue != nil)
    failed.append([inboxHit(rule)], rules: [rule], now: now)
    failed.flush()
    #expect(try Data(contentsOf: file) == damaged && failed.count == 1)
}

@Test("Message quick rules scope exact conversations, quote regex names and refuse inferred senders")
func reminderQuickDrafts() throws {
    var message = inboxMessage(body: "合成人名：@所有人")
    message.senderDisplayName = nil
    message.subtitle = ""
    #expect(message.presentation.senderSource == "body_prefix_inferred")
    #expect(ReminderQuickRule.make(message: message, kind: .sender) == nil)
    let everyone = try #require(ReminderQuickRule.make(message: message, kind: .everyone))
    #expect(ReminderMatcher().evaluate([message], rules: [everyone]).hits.count == 1)
    var other = message
    other.conversationName += "副本"
    #expect(ReminderMatcher().evaluate([other], rules: [everyone]).hits.isEmpty)
    other = message
    other.body = "普通通知"
    #expect(ReminderMatcher().evaluate([other], rules: [everyone]).hits.isEmpty)
    message.senderDisplayName = "A.*"
    let sender = try #require(ReminderQuickRule.make(message: message, kind: .sender))
    #expect(sender.conditions.last?.comparison == .equals && sender.conditions.last?.value == "A.*")
    message.conversationKind = "direct"
    #expect(ReminderQuickRule.make(message: message, kind: .sender)?.conditions.count == 1)
    #expect(ReminderQuickRule.make(message: message, kind: .everyone) == nil)
}

@Test("Reminder scheduling migrates old JSON and preserves settings omitted by older MCP clients")
func reminderSchedulingCompatibility() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let service = QueryService(paths: paths)
    var rule = ReminderRule(name: "合成规则", conditions: [ReminderCondition(value: "通知")])
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as! [String: Any]
    object.removeValue(forKey: "quietHours")
    object.removeValue(forKey: "minimumIntervalSeconds")
    let old = try JSONDecoder().decode(ReminderRule.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.quietHours == nil && old.minimumIntervalSeconds == 0)
    rule.quietHours = ReminderQuietHours()
    rule.minimumIntervalSeconds = 300
    let snapshot = try ReminderRuleStore(paths: paths).save([rule], expectedRevision: "initial")
    var input = ReminderMCP.ruleObject(rule)
    input.removeValue(forKey: "quiet_hours")
    input.removeValue(forKey: "minimum_interval_seconds")
    input["name"] = "旧客户端修改名称"
    _ = try service.call(
        "wechat_save_reminder_rule", arguments: ["rule": input, "expected_revision": snapshot.revision])
    let saved = try ReminderRuleStore(paths: paths).load()
    #expect(saved.rules[0].quietHours == rule.quietHours && saved.rules[0].minimumIntervalSeconds == 300)
    input["quiet_hours"] = NSNull()
    input["minimum_interval_seconds"] = 0
    _ = try service.call("wechat_save_reminder_rule", arguments: ["rule": input, "expected_revision": saved.revision])
    let cleared = try ReminderRuleStore(paths: paths).load()
    #expect(cleared.rules[0].quietHours == nil && cleared.rules[0].minimumIntervalSeconds == 0)
    input["quiet_hours"] = ["start_minute": 0, "end_minute": 0]
    #expect(throws: MCPQueryError.self) { try ReminderMCP.parse(input, service: service, requireID: true) }
}

@Test("Reminder inbox bounds history, preserves cooldown across restart and clears private content")
@MainActor func reminderInboxRetention() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let now = TestSupport.referenceDate
    let rule = ReminderRule(name: "合成规则", conditions: [ReminderCondition(value: "通知")], minimumIntervalSeconds: 300)
    let inbox = ReminderInbox(paths: paths)
    inbox.append([inboxHit(rule)], rules: [rule], now: now)
    _ = inbox.takeDue(rules: [rule], now: now)
    inbox.flush()
    let restored = ReminderInbox(paths: paths)
    restored.append([inboxHit(rule)], rules: [rule], now: now.addingTimeInterval(20))
    #expect(restored.takeDue(rules: [rule], now: now.addingTimeInterval(20)).isEmpty)
    #expect(restored.nextDue == now.addingTimeInterval(300))
    restored.handle()
    let started = ProcessInfo.processInfo.systemUptime
    restored.append((0..<1001).map { inboxHit(rule, id: "bounded-\($0)") }, rules: [rule], now: now)
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    #expect(restored.entries.count == 1000 && restored.overflow == 1)
    #expect(elapsed < 2)
    restored.flush()
    #expect(ReminderInbox(paths: paths).entries.count == 1000)
    try restored.erase()
    #expect(restored.count == 0 && restored.entries.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("reminder-inbox.json").path))
    print(
        "Synthetic inbox: 1001 incoming records, main-thread update \(String(format: "%.2f", elapsed * 1000)) ms; atomic persistence restored 1000 records"
    )
}

@Test("A second matching reminder rule can deliver immediately while another rule is quiet")
@MainActor func reminderInboxMultiplePolicies() {
    let now = Dates.parse("2026-10-17T23:00:00+08:00")!
    let calendar = inboxCalendar()
    let quiet = ReminderRule(
        name: "合成安静", conditions: [ReminderCondition(value: "通知")], quietHours: ReminderQuietHours())
    let immediate = ReminderRule(name: "合成立即", conditions: [ReminderCondition(value: "通知")])
    let hit = ReminderHit(
        message: inboxMessage(), ruleNames: [quiet.name, immediate.name], ruleIDs: [quiet.id, immediate.id])
    let inbox = ReminderInbox()
    inbox.append([hit], rules: [quiet, immediate], now: now, calendar: calendar)
    #expect(inbox.takeDue(rules: [quiet, immediate], now: now, calendar: calendar).count == 1)
    #expect(inbox.takeDue(rules: [quiet, immediate], now: now.addingTimeInterval(1), calendar: calendar).isEmpty)
}

@Test("Reminder window inbox retains usable layout when empty and populated")
@MainActor func reminderWindowInboxLayout() async throws {
    _ = NSApplication.shared
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let model = AppModel(paths: paths, allowNotificationCapture: false)
    let startup = StartupCoordinator(
        setupCompleted: true, demo: true, checkAccess: { .readable }, persistCompletion: {})
    model.page = .reminders
    let window = ApplicationWindows.startup(model: model, startup: startup)
    ApplicationWindows.library(window, autosaveName: nil)
    defer {
        model.shutDown()
        window.close()
    }
    for _ in 0..<10 {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.contentView!.bounds.width >= 820 && window.contentView!.bounds.height >= 580)
    let message = inboxMessage()
    model.createReminder(from: message, kind: .everyone)
    #expect(model.reminderDraft?.conditions.count == 2 && model.reminderDraftSample?.id == message.id)
    model.reminderInbox.append([ReminderHit(message: message, ruleNames: ["合成布局"])])
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(window.contentView!.bounds.width >= 820 && window.contentView!.bounds.height >= 580)
    // Isolated previews can repeat without being suppressed as handled production reminders.
    let preview = ReminderWindowController()
    let hit = ReminderHit(message: message, ruleNames: ["合成预览"], isPreview: true)
    preview.present([hit], sound: false, showWindow: false)
    preview.dismiss()
    preview.present([hit], sound: false, showWindow: false)
    #expect(preview.inbox.count == 1)
    preview.dismiss()
    preview.panel?.close()
}
