import AppKit
import Foundation
import Testing

@testable import WeChatListener

private func syncRule(_ name: String = "合成同步规则") -> ReminderRule {
    ReminderRule(
        name: name, ignoreCase: false,
        conditions: [ReminderCondition(field: .conversation, comparison: .equals, value: "合成项目群")],
        quietHours: ReminderQuietHours(), minimumIntervalSeconds: 300)
}
private func replica(_ document: ReminderRuleSyncDocument) -> ReminderRuleSyncState {
    var state = ReminderRuleSyncState()
    state.document = document
    return state
}
private func seed(_ rules: [ReminderRule]) throws -> ReminderRuleSyncState {
    var state = ReminderRuleSyncState()
    try state.record(previous: [], rules: rules)
    return state
}

@Test("Reminder sync merges independent edits and converges regardless of merge order or repeated delivery")
func reminderSyncConvergence() throws {
    let first = syncRule()
    let second = syncRule("合成第二规则")
    let initial = try seed([first, second])
    var a = replica(initial.document)
    var b = replica(initial.document)
    var c = replica(initial.document)
    var changedA = first
    changedA.minimumIntervalSeconds = 600
    var changedB = second
    changedB.quietHours = nil
    let third = syncRule("合成新增")
    try a.record(previous: [first, second], rules: [changedA, second])
    try b.record(previous: [first, second], rules: [first, changedB])
    try c.record(previous: [first, second], rules: [first, second, third])
    var ab = a.document
    try ab.merge(b.document)
    try ab.merge(c.document)
    var ba = c.document
    try ba.merge(a.document)
    try ba.merge(b.document)
    #expect(ab == ba && ab.materialized().rules.count == 3 && ab.materialized().conflicts == 0)
    #expect(ab.materialized().rules.first(where: { $0.id == first.id })?.minimumIntervalSeconds == 600)
    #expect(ab.materialized().rules.first(where: { $0.id == second.id })?.quietHours == nil)
    let before = ab
    try ab.merge(ab)
    try ab.merge(initial.document)
    #expect(ab == before)
}

@Test("Reminder sync preserves simultaneous edits as disabled copies and retains them until explicitly removed")
func reminderSyncConflicts() throws {
    let rule = syncRule()
    let initial = try seed([rule])
    var a = replica(initial.document)
    var b = replica(initial.document)
    var first = rule
    first.name = "合成编辑 A"
    var second = rule
    second.name = "合成编辑 B"
    try a.record(previous: [rule], rules: [first])
    try b.record(previous: [rule], rules: [second])
    var document = a.document
    try document.merge(b.document)
    #expect(document.materialized().rules.count == 2 && document.materialized().conflicts == 1)
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReminderRuleStore(paths: AppPaths(override: root.path))
    var snapshot = try store.mergeSync(document)
    let copy = try #require(snapshot.rules.first(where: { $0.id != rule.id }))
    #expect(!copy.isEnabled && copy.name.hasSuffix("（冲突副本）"))
    var rules = snapshot.rules
    rules[rules.firstIndex(where: { $0.id == rule.id })!].name = "合成继续编辑"
    snapshot = try store.save(rules, expectedRevision: snapshot.revision)
    snapshot = try store.mergeSync(initial.document)
    #expect(snapshot.rules.contains(where: { $0.id == copy.id }))
    snapshot = try store.save(snapshot.rules.filter { $0.id != copy.id }, expectedRevision: snapshot.revision)
    snapshot = try store.mergeSync(document)
    #expect(snapshot.rules.count == 1 && !snapshot.rules.contains(where: { $0.id == copy.id }))
}

@Test("Reminder sync tombstones prevent offline resurrection and preserve unseen edits without enabling them")
func reminderSyncDeletes() throws {
    let rule = syncRule()
    let initial = try seed([rule])
    var deleted = replica(initial.document)
    try deleted.record(previous: [rule], rules: [])
    var merged = deleted.document
    try merged.merge(initial.document)
    #expect(merged.materialized().rules.isEmpty)
    var edit = replica(initial.document)
    var changed = rule
    changed.name = "合成离线更改"
    try edit.record(previous: [rule], rules: [changed])
    try merged.merge(edit.document)
    #expect(merged.materialized().rules.count == 1)
    #expect(merged.materialized().rules[0].id != rule.id && !merged.materialized().rules[0].isEnabled)
    var acknowledged = replica(merged)
    try acknowledged.record(previous: [], rules: [changed])
    #expect(acknowledged.document.materialized().rules.count == 1)
    #expect(acknowledged.document.materialized().rules[0].id == rule.id)
}

@Test("Reminder sync does not mistake regenerated MCP condition IDs for a concurrent content edit")
func reminderSyncSemanticEquality() throws {
    let rule = syncRule()
    let initial = try seed([rule])
    var a = replica(initial.document)
    var b = replica(initial.document)
    var same = rule
    same.conditions[0].id = UUID()
    try a.record(previous: [rule], rules: [same])
    #expect(a.document == initial.document)
    var changed = rule
    changed.name = "合成同名编辑"
    try a.record(previous: [rule], rules: [changed])
    try b.record(previous: [rule], rules: [changed])
    try a.document.merge(b.document)
    #expect(a.document.materialized().rules.count == 1)
}

@Test(
    "Reminder sync rejects unknown schemas, duplicate version identities and malformed clocks without overwriting local rules"
)
func reminderSyncValidation() throws {
    let rule = syncRule()
    let original = try seed([rule])
    var invalid = original.document
    invalid.schema = 999
    #expect(throws: ListenerError.self) { try invalid.validate() }
    invalid = original.document
    invalid.clock = [:]
    #expect(throws: ListenerError.self) { try invalid.validate() }
    var collision = original.document
    collision.registers[rule.id.uuidString]![0].rule!.name = "合成篡改"
    var local = original.document
    #expect(throws: ListenerError.self) { try local.merge(collision) }
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let store = ReminderRuleStore(paths: paths)
    _ = try store.save([rule], expectedRevision: "initial")
    let before = try Data(contentsOf: store.url)
    #expect(throws: ListenerError.self) { try store.mergeSync(invalid) }
    #expect(try Data(contentsOf: store.url) == before)
}

@Test("Reminder sync compacts causal history across thousands of edits")
func reminderSyncBoundedHistory() throws {
    var rule = syncRule()
    var state = try seed([rule])
    for i in 0..<1200 {
        let old = rule
        rule.name = "合成版本 \(i)"
        try state.record(previous: [old], rules: [rule])
    }
    #expect(state.document.registers.count == 1 && state.document.registers[rule.id.uuidString]?.count == 1)
    #expect(try jsonData(state.document).count < 5000)
}

@Test("Reminder sync coordinates two local replicas, propagates MCP changes and deletion, and avoids unchanged writes")
func reminderSyncFolderExchange() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cloud = root.appendingPathComponent("synthetic-cloud")
    try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    let a = AppPaths(override: root.appendingPathComponent("a").path)
    let b = AppPaths(override: root.appendingPathComponent("b").path)
    let sa = ReminderRuleStore(paths: a)
    let sb = ReminderRuleStore(paths: b)
    let rule = syncRule()
    _ = try sa.save([rule], expectedRevision: "initial")
    let wa = ReminderRuleSyncWorker(paths: a)
    let wb = ReminderRuleSyncWorker(paths: b)
    _ = try wa.exchange(folder: cloud)
    _ = try wb.exchange(folder: cloud)
    _ = try wa.exchange(folder: cloud)
    var remote = try sb.load()
    #expect(remote.rules == [rule])
    let service = QueryService(paths: b)
    var edited = rule
    edited.minimumIntervalSeconds = 900
    _ = try service.call(
        "wechat_save_reminder_rule",
        arguments: ["rule": ReminderMCP.ruleObject(edited), "expected_revision": remote.revision])
    _ = try wb.exchange(folder: cloud)
    _ = try wa.exchange(folder: cloud)
    #expect(try sa.load().rules[0].minimumIntervalSeconds == 900)
    let own = cloud.appendingPathComponent(ReminderRuleSyncWorker.directoryName).appendingPathComponent(
        "weiji-rules-\(try sa.load().sync!.deviceID.uuidString).json")
    let time = try own.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let revision = try sa.load().revision
    _ = try wa.exchange(folder: cloud)
    #expect(try own.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == time)
    #expect(try sa.load().revision == revision)
    remote = try sb.load()
    _ = try sb.save([], expectedRevision: remote.revision)
    _ = try wb.exchange(folder: cloud)
    _ = try wa.exchange(folder: cloud)
    #expect(try sa.load().rules.isEmpty)
    let mode = try FileManager.default.attributesOfItem(atPath: own.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    #expect(!FileManager.default.fileExists(atPath: a.database.path))
}

@Test("Reminder sync preserves local state when a provider file is damaged, and cancellation makes no cloud writes")
func reminderSyncProviderFailures() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cloud = root.appendingPathComponent("synthetic-cloud")
    try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    let paths = AppPaths(override: root.appendingPathComponent("a").path)
    let store = ReminderRuleStore(paths: paths)
    let rule = syncRule()
    _ = try store.save([rule], expectedRevision: "initial")
    let worker = ReminderRuleSyncWorker(paths: paths)
    let token = BackgroundWorkToken()
    token.cancel()
    #expect(throws: CancellationError.self) { try worker.exchange(folder: cloud, work: token) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: cloud.path).isEmpty)
    _ = try worker.exchange(folder: cloud)
    let folder = cloud.appendingPathComponent(ReminderRuleSyncWorker.directoryName)
    let bad = folder.appendingPathComponent("weiji-rules-\(UUID().uuidString).json")
    try Data("synthetic damaged JSON".utf8).write(to: bad)
    let before = try Data(contentsOf: store.url)
    #expect(throws: (any Error).self) { try worker.exchange(folder: cloud) }
    #expect(try Data(contentsOf: store.url) == before)
    #expect(try store.load().rules == [rule])
}

@Test("Reminder sync journals MCP writes while GUI is closed and rejects stale revisions after a remote merge")
func reminderSyncRevisionSafety() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let store = ReminderRuleStore(paths: paths)
    let rule = syncRule()
    let initial = try store.save([rule], expectedRevision: "initial")
    _ = try store.enableSync()
    let unrelated = syncRule("合成其他设备规则")
    let remote = try seed([unrelated])
    _ = try store.mergeSync(remote.document)
    #expect(throws: MCPQueryError.self) { try store.save([], expectedRevision: initial.revision) }
    let service = QueryService(paths: paths)
    let latest = try store.load()
    _ = try service.call(
        "wechat_delete_reminder_rule", arguments: ["id": rule.id.uuidString, "expected_revision": latest.revision])
    let snapshot = try store.load()
    #expect(snapshot.sync!.document.materialized().rules.map(\.id) == [unrelated.id])
    #expect(snapshot.sync!.document.registers[rule.id.uuidString]?.first?.rule == nil)
    #expect(ReminderMCP.snapshotObject(snapshot)["sync"] == nil)
}

@Test("Reminder sync configuration is opt in, persists only its folder bookmark, and can stop without deleting rules")
@MainActor func reminderSyncConfiguration() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.appendingPathComponent("local").path)
    let sync = ReminderRuleSync(paths: paths)
    sync.start()
    #expect(!sync.enabled && !sync.busy)
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))
    let folder = root.appendingPathComponent("synthetic-cloud")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try sync.configure(folder: folder)
    for _ in 0..<200
    where sync.busy
        || !FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(ReminderRuleSyncWorker.directoryName).path)
    {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(sync.enabled && !sync.busy && sync.issue == nil)
    #expect(
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(ReminderRuleSyncWorker.directoryName).path)
    )
    sync.stop()
    let restored = ReminderRuleSync(paths: paths)
    #expect(restored.enabled)
    var completed = false
    restored.onRulesChanged = { completed = true }
    restored.start()
    for _ in 0..<500 where !completed { try await Task.sleep(for: .milliseconds(10)) }
    #expect(completed && restored.issue == nil)
    var callbacks = 0
    restored.onRulesChanged = { callbacks += 1 }
    restored.request()
    for _ in 0..<500 where callbacks == 0 { try await Task.sleep(for: .milliseconds(10)) }
    try await Task.sleep(for: .milliseconds(1200))
    #expect(callbacks == 1 && !restored.busy)  // No presenter-driven self-sync loop while idle.
    restored.disable()
    #expect(!restored.enabled && !restored.busy)
    #expect(!ReminderRuleSync(paths: paths).enabled)
    let config = paths.root.appendingPathComponent("reminder-sync.json")
    let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    restored.stop()
    sync.stop()
}

@Test("Reminder rules window keeps usable geometry with the iCloud Drive controls")
@MainActor func reminderWindowSyncLayout() async throws {
    _ = NSApplication.shared
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(paths: AppPaths(override: root.path), allowNotificationCapture: false)
    let window = ApplicationWindows.reminderRules(model: model)
    defer {
        model.shutDown()
        window.close()
    }
    for _ in 0..<15 {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.contentView!.bounds.width >= 640 && window.contentView!.bounds.height >= 500)
}

@Test("Reminder sync keeps all remote state over the UI limit so deletions can restore convergence")
func reminderSyncRuleLimitRecovery() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReminderRuleStore(paths: AppPaths(override: root.path))
    let local = (0..<32).map { syncRule("合成本机 \($0)") }
    let remote = (0..<32).map { syncRule("合成远端 \($0)") }
    let initial = try store.save(local, expectedRevision: "initial")
    _ = try store.enableSync()
    let remoteState = try seed(remote)
    let merged = try store.mergeSync(remoteState.document)
    #expect(merged.rules == local && merged.revision == initial.revision)
    #expect(merged.sync!.document.materialized().rules.count == 64)
    _ = try store.save([], expectedRevision: merged.revision)
    let recovered = try store.mergeSync(remoteState.document)
    #expect(Set(recovered.rules.map(\.id)) == Set(remote.map(\.id)))
    #expect(recovered.sync!.document.materialized().rules.count == 32)
}

@Test("Reminder sync cancellation is checked within the local rule transaction")
func reminderSyncCancelledMerge() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ReminderRuleStore(paths: AppPaths(override: root.path))
    let rule = syncRule()
    _ = try store.save([rule], expectedRevision: "initial")
    let before = try Data(contentsOf: store.url)
    let token = BackgroundWorkToken()
    token.cancel()
    #expect(throws: CancellationError.self) { try store.enableSync(work: token) }
    #expect(throws: CancellationError.self) { try store.mergeSync(seed([syncRule("合成远端")]).document, work: token) }
    #expect(try Data(contentsOf: store.url) == before)
}
