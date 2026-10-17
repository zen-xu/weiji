import Foundation

/// A multi-value register with causal clocks: independent edits merge, concurrent edits remain reviewable.
struct ReminderRuleSyncVersion: Codable, Equatable {
    var id = UUID()
    var clock: [String: UInt64]
    var rule: ReminderRule?
}

struct ReminderRuleSyncDocument: Codable, Equatable {
    static let maximumBytes = 16_000_000
    static let maximumRegisters = 4096
    static let maximumDevices = 32
    var schema = 1
    var clock: [String: UInt64] = [:]
    var registers: [String: [ReminderRuleSyncVersion]] = [:]

    static func dominates(_ a: [String: UInt64], _ b: [String: UInt64]) -> Bool {
        b.allSatisfy { (a[$0.key] ?? 0) >= $0.value } && a.contains { $0.value > (b[$0.key] ?? 0) }
    }
    func validate() throws {
        guard schema == 1, registers.count <= Self.maximumRegisters, clock.count <= Self.maximumDevices,
            clock.allSatisfy({ UUID(uuidString: $0.key)?.uuidString == $0.key && $0.value > 0 && $0.value < UInt64.max }
            )
        else { throw ListenerError("规则同步数据版本或容量无效，未覆盖本机规则。") }
        var versionIDs = Set<UUID>()
        for (key, versions) in registers {
            guard let ruleID = UUID(uuidString: key), ruleID.uuidString == key,
                !versions.isEmpty, versions.count <= Self.maximumDevices
            else {
                throw ListenerError("规则同步记录无效，未覆盖本机规则。")
            }
            for version in versions {
                guard versionIDs.insert(version.id).inserted, !version.clock.isEmpty,
                    version.clock.count <= Self.maximumDevices,
                    version.clock.allSatisfy({ clock[$0.key] != nil && $0.value > 0 && $0.value <= clock[$0.key]! }),
                    version.rule == nil || version.rule?.id == ruleID
                else {
                    throw ListenerError("规则同步版本无效，未覆盖本机规则。")
                }
                try version.rule?.validate()
            }
        }
    }
    mutating func merge(_ other: Self) throws {
        try other.validate()
        for (device, counter) in other.clock { clock[device] = max(clock[device] ?? 0, counter) }
        for (key, incoming) in other.registers {
            var versions = registers[key] ?? []
            for candidate in incoming {
                if let existing = versions.first(where: { $0.id == candidate.id }) {
                    guard existing == candidate else { throw ListenerError("规则同步版本冲突，已保留本机资料。") }
                } else {
                    versions.append(candidate)
                }
            }
            registers[key] = versions.filter { v in
                !versions.contains { $0.id != v.id && Self.dominates($0.clock, v.clock) }
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        try validate()
    }
    func materialized() -> (rules: [ReminderRule], conflicts: Int) {
        var output: [ReminderRule] = []
        var conflicts = 0
        for key in registers.keys.sorted() {
            let versions = registers[key]!.sorted {
                if ($0.rule == nil) != ($1.rule == nil) { return $0.rule != nil }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard let winner = versions.last else { continue }
            if let rule = winner.rule { output.append(rule) }
            var contents = winner.rule.map { [$0] } ?? []
            for version in versions where version.id != winner.id {
                guard var rule = version.rule, !contents.contains(where: { $0.hasSameContent(as: rule) }) else {
                    continue
                }
                contents.append(rule)
                // The stable version UUID is the conflict copy's ID. An explicit edit/delete of that copy wins.
                guard registers[version.id.uuidString] == nil else { continue }
                rule.id = version.id
                rule.name = String(rule.name.prefix(70)) + "（冲突副本）"
                rule.isEnabled = false
                output.append(rule)
                conflicts += 1
            }
        }
        return (output, conflicts)
    }
}

struct ReminderRuleSyncState: Codable, Equatable {
    var deviceID = UUID()
    var document = ReminderRuleSyncDocument()

    mutating func preserveConflictCopies() throws {
        let copies = document.materialized().rules.filter { document.registers[$0.id.uuidString] == nil }
        if !copies.isEmpty { try record(previous: [], rules: copies) }
    }

    mutating func record(previous: [ReminderRule], rules: [ReminderRule]) throws {
        let before = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        for id in Set(before.keys).union(after.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            if let old = before[id], let new = after[id], old.hasSameContent(as: new) { continue }
            let device = deviceID.uuidString
            let counter = document.clock[device] ?? 0
            guard counter < UInt64.max - 1 else { throw ListenerError("规则同步计数已满。") }
            document.clock[device] = counter + 1
            document.registers[id.uuidString] = [ReminderRuleSyncVersion(clock: document.clock, rule: after[id])]
        }
        try document.validate()
    }
}

extension ReminderRule {
    /// Ignore ephemeral condition IDs so older MCP clients do not create false conflicts on every save.
    func hasSameContent(as other: Self) -> Bool {
        name == other.name && isEnabled == other.isEnabled && matchAll == other.matchAll
            && ignoreCase == other.ignoreCase && quietHours == other.quietHours
            && minimumIntervalSeconds == other.minimumIntervalSeconds && conditions.count == other.conditions.count
            && zip(conditions, other.conditions).allSatisfy {
                $0.field == $1.field && $0.comparison == $1.comparison && $0.value == $1.value
            }
    }
}
