import Foundation

final class NotificationSource {
    let database: SQLite
    init(url: URL) throws {
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
        let rows = try snapshot()
        var result = CaptureResult(sourceRows: rows.count)
        for row in rows {
            do {
                let message = try NotificationDecoder.decode(row)
                switch try archive.ingest(message) {
                case "inserted": result.inserted += 1
                case "updated": result.updated += 1
                default: break
                }
            } catch { result.failed += 1 }
        }
        do { try archive.flushJournal() } catch { result.journalError = true }
        return result
    }
}
