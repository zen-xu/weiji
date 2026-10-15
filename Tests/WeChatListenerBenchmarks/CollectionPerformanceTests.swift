import Foundation
import Testing

@testable import WeChatListener

@Test(
    "Synthetic unchanged notification capture performance",
    .enabled(if: ProcessInfo.processInfo.environment["WECHAT_RUN_BENCHMARKS"] == "1"))
func collectionPerformance() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "weiji-capture-benchmark-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("source.sqlite")
    let sourceDB = try SQLite(sourceURL.path)
    try sourceDB.run("CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT)")
    try sourceDB.run(
        "CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,delivered_date REAL,data BLOB)")
    try sourceDB.run("INSERT INTO app VALUES(1,'com.tencent.xinwechat')")
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    try sourceDB.transaction {
        for id in 0..<500 {
            let metadata = try NSKeyedArchiver.archivedData(
                withRootObject: ["chatname": "synthetic@chatroom", "unique_id": "capture-\(id)"],
                requiringSecureCoding: true)
            let payload = try PropertyListSerialization.data(
                fromPropertyList: [
                    "req": [
                        "titl": "合成测试群", "subt": "合成发送者", "body": String(repeating: "合成通知正文", count: 50),
                        "usda": metadata,
                    ]
                ], format: .binary, options: 0)
            try sourceDB.run(
                "INSERT INTO record VALUES(?,1,NULL,?,?)",
                [.integer(Int64(id)), .real(now.timeIntervalSinceReferenceDate + Double(id)), .blob(payload)])
        }
    }
    let archive = try Archive(paths: AppPaths(override: root.appendingPathComponent("archive").path))
    _ = try NotificationSource(url: sourceURL).capture(to: archive)
    func median(_ action: () throws -> Void) throws -> Double {
        var values = [Double]()
        for _ in 0..<7 {
            let begin = ProcessInfo.processInfo.systemUptime
            try autoreleasepool(invoking: action)
            values.append((ProcessInfo.processInfo.systemUptime - begin) * 1000)
        }
        return values.sorted()[3]
    }
    // Same snapshot, decoder and ingest path as the previous full-replay implementation.
    let fullReplay = try median {
        let rows = try NotificationSource(url: sourceURL).snapshot()
        for row in rows { try archive.ingest(NotificationDecoder.decode(row)) }
        try archive.flushJournal()
    }
    _ = try NotificationSource(url: sourceURL).capture(to: archive)
    let reused = try median {
        let result = try NotificationSource(url: sourceURL).capture(to: archive)
        #expect(result.sourceRows == 500 && result.reusedRows == 500 && result.decodedRows == 0)
        #expect(result.inserted == 0 && result.updated == 0 && result.failed == 0)
    }
    print(
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: [
                    "synthetic_notifications": 500, "full_replay_ms": fullReplay, "fingerprint_reuse_ms": reused,
                    "decoded_rows_before": 500, "decoded_rows_after": 0,
                ], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}
