import Foundation
import Testing

@testable import WeChatListener

@Test("Journal mirroring updates pending rows without rewriting already mirrored history")
func journalPendingWorkOnly() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try Archive(paths: AppPaths(override: root.path))
    let message = NotificationDecoder.make(
        record: 1, title: "合成", subtitle: "", body: "合成正文",
        chat: "synthetic-peer", delivered: TestSupport.referenceDate, captured: TestSupport.referenceDate)
    try archive.ingest(message)
    try archive.flushJournal()
    try archive.database.transaction {
        for _ in 0..<1000 {
            try archive.database.run(
                "INSERT INTO events(message_id,kind,recorded_at,payload,mirrored) VALUES(?,?,?,?,1)",
                [.text(message.id), .text("inserted"), .text(message.updatedAt), .blob(try jsonData(message))])
        }
    }
    var changed = message
    changed.body = "修改正文"
    changed.contentHash = digest("synthetic-change")
    try archive.ingest(changed)
    func changes() throws -> Int64 { try archive.database.rows("SELECT total_changes() AS n").first!.int("n")! }
    let before = try changes()
    try archive.flushJournal()
    #expect(try changes() - before == 1)
    #expect(try archive.database.rows("SELECT COUNT(*) AS n FROM events WHERE mirrored=0").first?.int("n") == 0)
    let after = try changes()
    let log = try Data(contentsOf: archive.paths.journal)
    try archive.flushJournal()
    #expect(try changes() == after && Data(contentsOf: archive.paths.journal) == log)
    let plan = try archive.database.rows(
        "EXPLAIN QUERY PLAN SELECT * FROM events WHERE mirrored=0 ORDER BY seq LIMIT 500")
    #expect(plan.contains { $0.string("detail")?.contains("events_pending") == true })
}
