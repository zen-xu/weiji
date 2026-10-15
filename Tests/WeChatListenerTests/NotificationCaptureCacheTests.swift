import Foundation
import Testing

@testable import WeChatListener

@Test("Warm capture reuses only unchanged successful rows and retries failures")
func notificationCaptureReuse() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("source.sqlite")
    let sourceDB = try SQLite(url.path)
    try sourceDB.run("CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT)")
    try sourceDB.run(
        "CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,delivered_date REAL,data BLOB)")
    try sourceDB.run("INSERT INTO app VALUES(1,'com.tencent.xinwechat')")
    func payload(_ body: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["req": ["titl": "合成通知", "body": body]], format: .binary, options: 0)
    }
    for id in 1...2 {
        try sourceDB.run(
            "INSERT INTO record VALUES(?,1,NULL,?,?)",
            [
                .integer(Int64(id)), .real(TestSupport.referenceDate.timeIntervalSinceReferenceDate),
                .blob(try payload("正文\(id)")),
            ])
    }
    let paths = AppPaths(override: root.appendingPathComponent("archive").path)
    let archive = try Archive(paths: paths)
    let first = try NotificationSource(url: url).capture(to: archive)
    #expect(first.inserted == 2 && first.decodedRows == 2 && first.reusedRows == 0)
    let warm = try NotificationSource(url: url).capture(to: archive)
    #expect(warm.sourceRows == 2 && warm.decodedRows == 0 && warm.reusedRows == 2)
    #expect(warm.inserted == 0 && warm.updated == 0 && warm.failed == 0)
    try sourceDB.run("UPDATE record SET data=? WHERE rec_id=1", [.blob(try payload("修改正文"))])
    let modified = try NotificationSource(url: url).capture(to: archive)
    #expect(modified.decodedRows == 1 && modified.reusedRows == 1 && modified.updated == 1)
    #expect(try archive.messages().contains { $0.body == "修改正文" })
    try sourceDB.run("INSERT INTO record VALUES(3,1,NULL,0,?)", [.blob(Data("INVALID".utf8))])
    for _ in 0..<2 {
        let retry = try NotificationSource(url: url).capture(to: archive)
        #expect(retry.failed == 1 && retry.decodedRows == 1 && retry.reusedRows == 2)
    }
    // Changes to the source identity must be rechecked even when the body is unchanged.
    try sourceDB.run("UPDATE record SET uuid=? WHERE rec_id=2", [.blob(Data([1, 2, 3]))])
    let changedIdentity = try NotificationSource(url: url).capture(to: archive)
    #expect(changedIdentity.decodedRows == 2 && changedIdentity.reusedRows == 1)
    try archive.clear()
    let restored = try NotificationSource(url: url).capture(to: archive)
    #expect(restored.inserted == 2 && restored.reusedRows == 0 && restored.failed == 1)
    let external = try Archive(paths: paths)
    try external.clear()
    let externalRestore = try NotificationSource(url: url).capture(to: archive)
    #expect(externalRestore.inserted == 2 && externalRestore.reusedRows == 0)
    // Importing a future version must not make an old source row permanently cacheable.
    var future = try #require(try archive.messages().first)
    future.body = "导入的较新版本"
    future.contentHash = digest("synthetic-future-version")
    future.updatedAt = Dates.string(Date().addingTimeInterval(3600))
    try archive.ingest(future)
    let afterImport = try NotificationSource(url: url).capture(to: archive)
    #expect(afterImport.reusedRows == 0)
    let next = try NotificationSource(url: url).capture(to: archive)
    #expect(next.decodedRows == 2 && next.failed == 1 && next.reusedRows == 1)
    #expect(try archive.messages().contains { $0.body == "导入的较新版本" })
}

@Test("Capture fingerprints are bounded and invalidate on local revisions, other writers and source changes")
func notificationCaptureCacheBounds() throws {
    let cache = NotificationCaptureCache()
    let records = Dictionary(
        uniqueKeysWithValues: (0...NotificationCaptureCache.limit).map { (Int64($0), Data(repeating: 1, count: 32)) })
    cache.replace(records, source: "/synthetic", revision: 1, dataVersion: 1)
    #expect(cache.reusable(source: "/synthetic", revision: 1, dataVersion: 1).count == NotificationCaptureCache.limit)
    #expect(cache.reusable(source: "/other", revision: 1, dataVersion: 1).isEmpty)
    #expect(cache.reusable(source: "/synthetic", revision: 2, dataVersion: 1).isEmpty)
    #expect(cache.reusable(source: "/synthetic", revision: 1, dataVersion: 2).isEmpty)
    var row: [String: SQLValue] = ["rec_id": .integer(1), "data": .blob(Data("synthetic".utf8))]
    let initial = try #require(NotificationCaptureCache.fingerprint(row)?.1)
    row["uuid"] = .blob(Data())
    #expect(NotificationCaptureCache.fingerprint(row)?.1 != initial)
}

@Test("Malformed source timestamps cannot crash decoding and empty UUIDs do not merge records")
func notificationMalformedTimestamps() throws {
    let bytes = try PropertyListSerialization.data(
        fromPropertyList: ["req": ["titl": "合成", "body": "正文"]], format: .binary, options: 0)
    var row: [String: SQLValue] = ["rec_id": .integer(1), "data": .blob(bytes), "uuid": .blob(Data())]
    for value in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude] {
        row["delivered_date"] = .real(value)
        #expect(throws: ListenerError.self) { try NotificationDecoder.decode(row) }
    }
    row["delivered_date"] = .real(0)
    let first = try NotificationDecoder.decode(row)
    row["rec_id"] = .integer(2)
    #expect(try NotificationDecoder.decode(row).id != first.id)
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        _ = try Archive(paths: AppPaths(override: root.appendingPathComponent("absent").path), readOnly: true)
        Issue.record("Opening an absent read-only archive succeeded")
    } catch {
        #expect(error.localizedDescription.contains("本地档案") && !error.localizedDescription.contains("完全磁盘"))
    }
}
