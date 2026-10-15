import Foundation

final class NotificationSource {
    let database: SQLite
    private let sourceIdentity: String
    init(url: URL) throws {
        sourceIdentity = url.standardizedFileURL.path
        database = try SQLite(url.path, readOnly: true)
        let columns = try database.rows("PRAGMA table_info(record)").compactMap { $0.string("name") }
        guard Set(["rec_id", "data", "app_id", "delivered_date", "uuid"]).isSubset(of: Set(columns)) else {
            throw ListenerError("当前 macOS 通知数据库结构尚未适配。")
        }
    }
    func snapshot() throws -> [[String: SQLValue]] {
        // Read one consistent snapshot. Never write, copy, or alter the system database/WAL.
        try database.run("BEGIN")
        do {
            var rows = [[String: SQLValue]]()
            var offset = 0
            while true {
                let page = try database.rows(
                    """
                    SELECT r.rec_id, r.uuid, r.delivered_date, r.data
                    FROM record r JOIN app a ON a.app_id=r.app_id
                    WHERE a.identifier = ? COLLATE NOCASE ORDER BY r.rec_id LIMIT 500 OFFSET ?
                    """, [.text("com.tencent.xinwechat"), .integer(Int64(offset))])
                rows.append(contentsOf: page)
                if page.count < 500 { break }
                offset += page.count
            }
            try database.run("COMMIT")
            return rows
        } catch {
            try? database.run("ROLLBACK")
            throw error
        }
    }
    func capture(to archive: Archive) throws -> CaptureResult {
        let version = try archive.database.rows("PRAGMA data_version").first?.int("data_version") ?? 0
        let cached = archive.notificationCaptureCache.reusable(
            source: sourceIdentity, revision: archive.notificationRevision, dataVersion: version)
        let rows = try snapshot()
        let retainedIDs = Set(rows.suffix(NotificationCaptureCache.limit).compactMap { $0.int("rec_id") })
        var next: [Int64: Data] = [:]
        var result = CaptureResult(sourceRows: rows.count)
        for row in rows {
            let fingerprint = NotificationCaptureCache.fingerprint(row)
            if let (id, value) = fingerprint, cached[id] == value {
                result.reusedRows += 1
                if retainedIDs.contains(id) { next[id] = value }
                continue
            }
            do {
                result.decodedRows += 1
                let message = try NotificationDecoder.decode(row)
                let disposition = try archive.ingestDisposition(message)
                switch disposition {
                case .inserted: result.inserted += 1
                case .updated: result.updated += 1
                default: break
                }
                // Without a stable identity or delivery date, retain the existing fallback behavior.
                if disposition.matchesSource, let (id, value) = fingerprint, retainedIDs.contains(id),
                    message.notificationIdentity != nil || message.deliveredAt != nil
                {
                    next[id] = value
                }
            } catch { result.failed += 1 }
        }
        let finalVersion = try archive.database.rows("PRAGMA data_version").first?.int("data_version") ?? 0
        archive.notificationCaptureCache.replace(
            next, source: sourceIdentity, revision: archive.notificationRevision,
            dataVersion: finalVersion == version ? version : nil)
        do { try archive.flushJournal() } catch { result.journalError = true }
        return result
    }
}
