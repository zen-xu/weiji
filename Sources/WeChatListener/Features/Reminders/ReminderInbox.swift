import Darwin
import Foundation
import SwiftUI

struct ReminderEntry: Codable, Identifiable {
    var id: String { hit.id }
    var hit: ReminderHit
    var receivedAt: Date
    var handledAt: Date?
    var snoozedUntil: Date?
    var presentedAt: Date?
    var dueAt: Date
    var isHandled: Bool { handledAt != nil }
}

private struct ReminderInboxSnapshot: Codable {
    var version = 1
    var entries: [ReminderEntry] = []
    var overflow = 0
    var lastPresented: [String: Date] = [:]
    var snoozedUntil: Date?
}

/// A serial writer keeps encoding and disk I/O off the main thread. The final snapshot is flushed on exit.
private final class ReminderInboxPersistence: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var newestWrite = 0
    private let queue = DispatchQueue(label: "local.xzy.WeChatListener.reminder-inbox", qos: .utility)
    init(paths: AppPaths) { url = paths.root.appendingPathComponent("reminder-inbox.json") }
    func load() throws -> ReminderInboxSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReminderInboxSnapshot() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 48 * 1024 * 1024 else { throw ListenerError("提醒收件箱过大。") }
        let snapshot = try JSONDecoder().decode(ReminderInboxSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1, snapshot.entries.count <= ReminderInbox.maximumEntries,
            Set(snapshot.entries.map(\.id)).count == snapshot.entries.count
        else {
            throw ListenerError("提醒收件箱格式无效。")
        }
        return snapshot
    }
    func save(_ snapshot: ReminderInboxSnapshot, completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        newestWrite += 1
        let token = newestWrite
        lock.unlock()
        queue.async { [self, url] in
            lock.lock()
            let current = token == newestWrite
            lock.unlock()
            guard current else { return }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(snapshot)
                guard data.count <= 48 * 1024 * 1024 else { throw ListenerError("提醒内容过大，无法保存。") }
                // Set permissions before atomic replacement; the temporary file never has public access.
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".inbox-\(UUID()).tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard
                    FileManager.default.createFile(
                        atPath: temporary.path, contents: nil,
                        attributes: [.posixPermissions: 0o600])
                else { throw ListenerError("无法保存提醒。") }
                try data.write(to: temporary)
                guard rename(temporary.path, url.path) == 0 else { throw ListenerError("无法替换提醒文件。") }
                completion(true)
            } catch { completion(false) }
        }
    }
    func erase() throws {
        try queue.sync {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    func flush() { queue.sync {} }
}

@MainActor
final class ReminderInbox: ObservableObject {
    nonisolated static let maximumEntries = 1000
    @Published private(set) var entries: [ReminderEntry] = []
    @Published private(set) var overflow = 0
    @Published private(set) var issue: String?
    @Published var expanded = false
    var onChange: (() -> Void)?
    private var lastPresented: [String: Date] = [:]
    private var globalSnoozedUntil: Date?
    private let persistence: ReminderInboxPersistence?
    private var writable = true
    private var generation = 0
    var hits: [ReminderHit] { entries.filter { !$0.isHandled }.map(\.hit) }
    var visibleHits: [ReminderHit] {
        entries.filter { !$0.isHandled && $0.dueAt <= Date() && ($0.snoozedUntil ?? .distantPast) <= Date() }.map(\.hit)
    }
    var count: Int { entries.filter { !$0.isHandled }.count + overflow }
    var nextDue: Date? {
        entries.filter { !$0.isHandled && $0.presentedAt == nil }
            .map { max($0.dueAt, $0.snoozedUntil ?? .distantPast) }.min()
    }
    var snoozedUntil: Date? { entries.filter { !$0.isHandled }.compactMap(\.snoozedUntil).filter { $0 > Date() }.max() }

    init(paths: AppPaths? = nil) {
        persistence = paths.map(ReminderInboxPersistence.init)
        do {
            if let snapshot = try persistence?.load() {
                entries = snapshot.entries
                overflow = snapshot.overflow
                lastPresented = snapshot.lastPresented
                globalSnoozedUntil = snapshot.snoozedUntil
            }
        } catch {
            writable = false
            issue = "无法读取提醒收件箱，原文件已保留。本次提醒暂存内存，请检查数据目录。"
        }
    }
    private func key(_ id: UUID, _ message: Message) -> String { "\(id)|\(message.conversationID)" }
    private func allowed(_ entry: ReminderEntry, rules: [ReminderRule], now: Date, calendar: Calendar) -> Date? {
        if entry.hit.ruleIDs.isEmpty { return now }  // Isolated previews and legacy synthetic callers.
        let matches = rules.filter { $0.isEnabled && entry.hit.ruleIDs.contains($0.id) }
        return matches.map { rule in
            let intervalEnd = (lastPresented[key(rule.id, entry.hit.message)] ?? .distantPast)
                .addingTimeInterval(Double(rule.minimumIntervalSeconds))
            let date = max(now, intervalEnd)
            return rule.quietHours?.nextAllowedDate(after: date, calendar: calendar) ?? date
        }.min()
    }
    func append(
        _ incoming: [ReminderHit], rules: [ReminderRule] = [], now: Date = Date(), calendar: Calendar = .current
    ) {
        var next = entries
        var indices = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element.id, $0.offset) })
        var changed = false
        for hit in incoming {
            if let index = indices[hit.id] {
                // Handled reminders never become unread again because the source notification changed.
                for name in hit.ruleNames where !next[index].hit.ruleNames.contains(name) {
                    next[index].hit.ruleNames.append(name)
                    changed = true
                }
                for id in hit.ruleIDs where !next[index].hit.ruleIDs.contains(id) {
                    next[index].hit.ruleIDs.append(id)
                    changed = true
                }
                continue
            }
            var entry = ReminderEntry(hit: hit, receivedAt: now, dueAt: now)
            entry.snoozedUntil = globalSnoozedUntil.flatMap { $0 > now ? $0 : nil }
            entry.dueAt = allowed(entry, rules: rules, now: now, calendar: calendar) ?? now
            indices[hit.id] = next.count
            next.append(entry)
            changed = true
        }
        if next.count > Self.maximumEntries {
            var removable = next.count - Self.maximumEntries
            next.removeAll { entry in
                if entry.isHandled && removable > 0 {
                    removable -= 1
                    return true
                }
                return false
            }
            if removable > 0 {
                overflow += removable
                next.removeFirst(removable)
            }
        }
        if changed {
            entries = next
            persist()
        }
    }
    /// Evaluate all due messages against one shared clock before recording a presentation, so bursts coalesce.
    func takeDue(rules: [ReminderRule], now: Date = Date(), calendar: Calendar = .current) -> [ReminderHit] {
        var nextEntries = entries
        var due: [ReminderHit] = []
        var changed = false
        for index in nextEntries.indices where !nextEntries[index].isHandled && nextEntries[index].presentedAt == nil {
            guard (nextEntries[index].snoozedUntil ?? .distantPast) <= now else { continue }
            guard let next = allowed(nextEntries[index], rules: rules, now: now, calendar: calendar) else {
                nextEntries[index].presentedAt = now
                changed = true
                continue
            }
            if next > now {
                if nextEntries[index].dueAt != next {
                    nextEntries[index].dueAt = next
                    changed = true
                }
                continue
            }
            nextEntries[index].dueAt = now
            nextEntries[index].presentedAt = now
            nextEntries[index].snoozedUntil = nil
            due.append(nextEntries[index].hit)
            changed = true
        }
        for hit in due {
            for id in hit.ruleIDs { lastPresented[key(id, hit.message)] = now }
        }
        // Cooldowns last at most a day. Bound stale conversation keys as well as reminder bodies.
        lastPresented = lastPresented.filter { now.timeIntervalSince($0.value) < 86400 }
        if changed {
            entries = nextEntries
            persist()
        }
        return due
    }
    func handle(_ id: String? = nil, now: Date = Date()) {
        var nextEntries = entries
        for index in nextEntries.indices where id == nil || nextEntries[index].id == id {
            nextEntries[index].handledAt = now
            nextEntries[index].snoozedUntil = nil
        }
        if id == nil {
            overflow = 0
            globalSnoozedUntil = nil
            expanded = false
        }
        entries = nextEntries
        persist()
    }
    func handleVisible(now: Date = Date()) {
        var next = entries
        for index in next.indices
        where !next[index].isHandled && next[index].dueAt <= now
            && (next[index].snoozedUntil ?? .distantPast) <= now
        {
            next[index].handledAt = now
        }
        expanded = false
        entries = next
        persist()
    }
    func dismissPrompt() {
        if persistence == nil { clear() } else { handleVisible() }
    }
    func restore(_ id: String, now: Date = Date()) {
        var nextEntries = entries
        guard let index = nextEntries.firstIndex(where: { $0.id == id }) else { return }
        nextEntries[index].handledAt = nil
        nextEntries[index].snoozedUntil = nil
        nextEntries[index].dueAt = now
        nextEntries[index].presentedAt = now  // Explicit restore does not interrupt work.
        entries = nextEntries
        persist()
    }
    func snooze(_ id: String? = nil, until: Date) {
        var nextEntries = entries
        if id == nil { globalSnoozedUntil = until }
        for index in nextEntries.indices
        where !nextEntries[index].isHandled && (id == nil || nextEntries[index].id == id) {
            nextEntries[index].snoozedUntil = until
            nextEntries[index].presentedAt = nil
        }
        entries = nextEntries
        persist()
    }
    func erase() throws {
        try persistence?.erase()
        entries = []
        overflow = 0
        expanded = false
        lastPresented = [:]
        globalSnoozedUntil = nil
        writable = true
        issue = nil
        generation += 1
        onChange?()
    }
    func reveal() {
        var nextEntries = entries
        globalSnoozedUntil = nil
        for index in nextEntries.indices where !nextEntries[index].isHandled {
            nextEntries[index].snoozedUntil = nil
            nextEntries[index].dueAt = Date()
            nextEntries[index].presentedAt = Date()
        }
        entries = nextEntries
        persist()
    }
    func clear() {
        if persistence == nil {
            entries = []
            overflow = 0
            expanded = false
            globalSnoozedUntil = nil
            lastPresented = [:]
            onChange?()
        } else {
            handle()
        }
    }
    func flush() { persistence?.flush() }
    func isPersisted(_ id: String) -> Bool {
        guard let persistence else { return false }
        persistence.flush()
        return (try? persistence.load().entries.contains { $0.id == id }) == true
    }
    private func persist() {
        generation += 1
        let token = generation
        if writable, let persistence {
            let snapshot = ReminderInboxSnapshot(
                entries: entries, overflow: overflow, lastPresented: lastPresented, snoozedUntil: globalSnoozedUntil)
            persistence.save(snapshot) { [weak self] success in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.issue = success ? nil : "提醒尚未保存到磁盘，退出前请检查数据目录空间与权限。"
                }
            }
        }
        onChange?()
    }
}
