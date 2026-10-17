import Darwin
import Foundation

struct ReminderRuleSnapshot: Codable, Equatable {
    var revision = "initial"
    var rules: [ReminderRule] = []
    var sync: ReminderRuleSyncState?
}

/// A separate, atomically replaced document shared by GUI, HTTP and stdio clients.
struct ReminderRuleStore {
    let paths: AppPaths
    var url: URL { paths.root.appendingPathComponent("reminder-rules.json") }

    func load() throws -> ReminderRuleSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReminderRuleSnapshot() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= ReminderRuleSyncDocument.maximumBytes else { throw ListenerError("提醒规则文件过大，未加载。") }
        let snapshot = try JSONDecoder().decode(ReminderRuleSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.rules.count <= ReminderRule.maximumRules,
            Set(snapshot.rules.map(\.id)).count == snapshot.rules.count,
            UUID(uuidString: snapshot.revision) != nil || (snapshot.revision == "initial" && snapshot.rules.isEmpty)
        else { throw ListenerError("提醒规则数量、ID 或版本无效。") }
        for rule in snapshot.rules { try rule.validate() }
        try snapshot.sync?.document.validate()
        return snapshot
    }

    func save(_ rules: [ReminderRule], expectedRevision: String) throws -> ReminderRuleSnapshot {
        guard rules.count <= ReminderRule.maximumRules, Set(rules.map(\.id)).count == rules.count else {
            throw MCPQueryError.invalidArguments("规则 ID 必须唯一，最多 \(ReminderRule.maximumRules) 条规则。")
        }
        for rule in rules { try rule.validate() }
        return try update { previous in
            guard previous.revision == expectedRevision else { throw MCPQueryError.reminderConflict }
            var next = previous
            if var sync = previous.sync {
                try sync.record(previous: previous.rules, rules: rules)
                next.sync = sync
            }
            next.rules = rules
            next.revision = UUID().uuidString
            return next
        }
    }

    func enableSync(work: BackgroundWorkToken? = nil) throws -> ReminderRuleSnapshot {
        try update(work: work) { previous in
            guard previous.sync == nil else { return previous }
            var next = previous
            var sync = ReminderRuleSyncState()
            try sync.record(previous: [], rules: previous.rules)
            next.sync = sync
            return next
        }
    }

    /// Re-read under the same lock as MCP/GUI writes. Remote merges never overwrite a concurrent local edit.
    func mergeSync(_ document: ReminderRuleSyncDocument, work: BackgroundWorkToken? = nil) throws
        -> ReminderRuleSnapshot
    {
        try document.validate()
        return try update(work: work) { previous in
            var next = previous
            var sync = previous.sync ?? ReminderRuleSyncState()
            if previous.sync == nil { try sync.record(previous: [], rules: previous.rules) }
            try sync.document.merge(document)
            try sync.preserveConflictCopies()
            let merged = sync.document.materialized().rules
            // Retain all causal state even when the UI limit is exceeded, so local deletions can resolve it.
            if merged.count <= ReminderRule.maximumRules {
                var byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
                for rule in previous.rules where byID[rule.id]?.hasSameContent(as: rule) == true {
                    byID[rule.id] = rule
                }
                var ordered = previous.rules.compactMap { byID[$0.id] }
                let existing = Set(ordered.map(\.id))
                ordered += merged.filter { !existing.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }
                if ordered != previous.rules {
                    next.rules = ordered
                    next.revision = UUID().uuidString
                }
            }
            next.sync = sync
            return next
        }
    }

    private func update(
        work: BackgroundWorkToken? = nil, _ change: (ReminderRuleSnapshot) throws -> ReminderRuleSnapshot
    ) throws -> ReminderRuleSnapshot {
        if work?.isCancelled == true { throw CancellationError() }
        try FileManager.default.createDirectory(
            at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(
            paths.root.appendingPathComponent(".reminder-rules.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ListenerError("无法打开提醒规则锁。") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw MCPQueryError.reminderConflict }
        defer { flock(lock, LOCK_UN) }
        if work?.isCancelled == true { throw CancellationError() }
        let previous = try load()
        let next = try change(previous)
        if next == previous { return previous }
        let data = try jsonData(next, pretty: true)
        guard data.count <= ReminderRuleSyncDocument.maximumBytes else { throw ListenerError("规则同步记录过大，请暂停同步后整理规则。") }
        let temporary = paths.root.appendingPathComponent(".reminder-rules-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw ListenerError("无法创建提醒规则文件。")
        }
        try data.write(to: temporary)
        if work?.isCancelled == true { throw CancellationError() }
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
