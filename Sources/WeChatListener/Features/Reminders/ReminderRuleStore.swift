import Darwin
import Foundation

struct ReminderRuleSnapshot: Codable, Equatable {
    var revision = "initial"
    var rules: [ReminderRule] = []
}

/// A separate, atomically replaced document shared by GUI, HTTP and stdio clients.
struct ReminderRuleStore {
    let paths: AppPaths
    var url: URL { paths.root.appendingPathComponent("reminder-rules.json") }

    func load() throws -> ReminderRuleSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReminderRuleSnapshot() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw ListenerError("提醒规则文件过大，未加载。") }
        let snapshot = try JSONDecoder().decode(ReminderRuleSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.rules.count <= ReminderRule.maximumRules,
            Set(snapshot.rules.map(\.id)).count == snapshot.rules.count,
            UUID(uuidString: snapshot.revision) != nil || (snapshot.revision == "initial" && snapshot.rules.isEmpty)
        else { throw ListenerError("提醒规则数量、ID 或版本无效。") }
        for rule in snapshot.rules { try rule.validate() }
        return snapshot
    }

    func save(_ rules: [ReminderRule], expectedRevision: String) throws -> ReminderRuleSnapshot {
        guard rules.count <= ReminderRule.maximumRules, Set(rules.map(\.id)).count == rules.count else {
            throw MCPQueryError.invalidArguments("规则 ID 必须唯一，最多 \(ReminderRule.maximumRules) 条规则。")
        }
        for rule in rules { try rule.validate() }
        try FileManager.default.createDirectory(
            at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(
            paths.root.appendingPathComponent(".reminder-rules.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ListenerError("无法打开提醒规则锁。") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw MCPQueryError.reminderConflict }
        defer { flock(lock, LOCK_UN) }
        let previous = try load()
        guard previous.revision == expectedRevision else { throw MCPQueryError.reminderConflict }
        let next = ReminderRuleSnapshot(revision: UUID().uuidString, rules: rules)
        let temporary = paths.root.appendingPathComponent(".reminder-rules-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try jsonData(next, pretty: true).write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw ListenerError("无法保存提醒规则，请检查磁盘空间和目录权限。") }
        return next
    }

    func signature() throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "absent" }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return
            "\(attributes[.systemFileNumber] ?? "")|\(attributes[.modificationDate] ?? "")|\(attributes[.size] ?? "")"
    }
}
