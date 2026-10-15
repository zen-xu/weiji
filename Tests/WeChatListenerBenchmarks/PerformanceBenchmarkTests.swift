import Foundation
import Testing

@testable import WeChatListener

/// Uses only a disposable synthetic account; never opens the real WeChat directory.
@Test(
    "Synthetic catalog performance", .enabled(if: ProcessInfo.processInfo.environment["WECHAT_RUN_BENCHMARKS"] == "1"))
func catalogPerformance() throws {
    let fileCount = 10_000
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wechat-performance-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let account = root.appendingPathComponent("synthetic-account")
    let files = account.appendingPathComponent("msg/file")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    let date = Date(timeIntervalSince1970: 1_792_000_000)
    let header = Data([7, 8, 86, 50, 8, 7])
    for scope in 0..<100 {
        let folder = account.appendingPathComponent("msg/attach/\(mediaDirectoryID("synthetic-\(scope)"))/2026-10/Img")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in stride(from: scope * 2, to: fileCount, by: 200) {
            for (offset, suffix) in [(0, ""), (1, "_t")] where index + offset < fileCount {
                let url = folder.appendingPathComponent("asset-\(index)\(suffix).dat")
                try header.write(to: url)
                try FileManager.default.setAttributes(
                    [.modificationDate: date.addingTimeInterval(Double(index))], ofItemAtPath: url.path)
            }
        }
    }
    for index in 0..<1000 { try Data("synthetic".utf8).write(to: files.appendingPathComponent("file-\(index).pdf")) }
    let archive = try Archive(paths: AppPaths(override: root.appendingPathComponent("archive").path))
    func elapsed<T>(_ action: () throws -> T) rethrows -> (T, Double) {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try autoreleasepool(invoking: action)
        return (result, (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    let cold = try elapsed {
        _ = try archive.scanFiles(in: files)
        return try archive.scanImageAssociations(fileRoot: files)
    }
    guard cold.0.files == fileCount, cold.0.complete else { throw ListenerError("Incomplete benchmark fixture") }
    var scanMS = [Double]()
    var writes = [Int64]()
    var galleryMS = [Double]()
    func changes() throws -> Int64 { try archive.database.rows("SELECT total_changes() AS n").first!.int("n")! }
    for _ in 0..<3 {
        let before = try changes()
        let scan = try elapsed {
            _ = try archive.scanFiles(in: files)
            _ = try archive.scanImageAssociations(fileRoot: files)
        }
        scanMS.append(scan.1)
        writes.append(try changes() - before)
    }
    let reader = try Archive(paths: archive.paths, readOnly: true)
    for _ in 0..<20 {
        let page = try elapsed { (try reader.directoryImageGroups(), try reader.directoryImageGroupCount()) }
        guard page.0.0.count == 60, page.0.1 == fileCount / 2 else {
            throw ListenerError("Invalid gallery benchmark result")
        }
        galleryMS.append(page.1)
    }
    let result: [String: Any] = [
        "synthetic_images": fileCount, "ordinary_files": 1000,
        "cold_scan_ms": cold.1, "unchanged_scan_ms": scanMS.sorted()[1], "unchanged_scan_row_writes": writes,
        "gallery_page_ms": galleryMS.sorted()[galleryMS.count / 2],
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
