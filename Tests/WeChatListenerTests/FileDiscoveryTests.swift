import Foundation
import Testing

@testable import WeChatListener

@Test("FileDiscovery")
func fileDiscovery() throws {
    let directory = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = TestSupport.referenceDate
    let base = directory.appendingPathComponent("file-discovery-fixture")
    let account = base.appendingPathComponent("account")
    let root = account.appendingPathComponent("msg/file")
    let month = root.appendingPathComponent("2026-10")
    let previous = root.appendingPathComponent("2026-09")
    for path in [month, previous, account.appendingPathComponent("db_storage")] {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    let first = month.appendingPathComponent("会议报价.pdf")
    let second = previous.appendingPathComponent("会议报价.pdf")
    let doc = month.appendingPathComponent("会议说明.docx")
    let content = Data("SYNTHETIC_FILE_CONTENT_MUST_NOT_APPEAR_IN_MCP".utf8)
    for path in [
        first, second, doc, month.appendingPathComponent("image.png"), month.appendingPathComponent("encrypted.dat"),
        month.appendingPathComponent(".hidden.pdf"), month.appendingPathComponent("internal"),
        account.appendingPathComponent("db_storage/never-scan.pdf"),
    ] {
        try content.write(to: path)
    }
    try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(2)], ofItemAtPath: first.path)
    try FileManager.default.setAttributes(
        [.modificationDate: date.addingTimeInterval(-3600)], ofItemAtPath: second.path)
    let outside = base.appendingPathComponent("outside.pdf")
    try content.write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: month.appendingPathComponent("escape.pdf"), withDestinationURL: outside)
    let paths = AppPaths(override: base.appendingPathComponent("archive").path)
    let store = try Archive(paths: paths)
    let result = try store.scanFiles(in: account)
    try #require(
        result.complete && result.files == 3 && (try store.discoveredFileCount()) == 3,
        "scan discovers ordinary files only inside the selected account msg/file")
    try #require(
        try FileDiscovery.directory(root) == root.standardizedFileURL,
        "scanner also accepts explicit msg/file directory")
    try #require(
        try Data(contentsOf: first) == content
            && first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                == date.addingTimeInterval(2),
        "metadata scanning leaves source file contents and modification times unchanged")
    try #require(
        try store.discoveredFileCount(query: "报价") == 2 && store.discoveredFiles(query: "' OR 1=1 --").isEmpty,
        "file-name search is literal and preserves same-name candidates")
    let message = NotificationDecoder.make(
        record: 800, title: "合成群", subtitle: "合成人", body: "[文件] 会议报价.pdf", chat: "fixture-file-group@chatroom",
        delivered: date, captured: date)
    try store.ingest(message)
    let candidates = try store.fileCandidates(for: message)
    try #require(
        candidates.count == 2
            && candidates.allSatisfy {
                $0["message_link_verified"] as? Bool == false && $0["same_name_count"] as? Int == 2
            }, "matching filenames return unverified candidates without choosing a message owner")
    try #require(
        candidates.first?["seconds_from_notification"] as? Double == 2,
        "candidate order prioritizes closeness in time without treating it as proof")
    var prefixed = message
    prefixed.subtitle = ""
    prefixed.senderDisplayName = nil
    prefixed.body = "合成人: [文件] 会议报价.pdf"
    try #require(
        prefixed.notifiedFileName == "会议报价.pdf", "group sender prefix is separated before extracting notified filename")
    var malformed = message
    malformed.body = "[文件] ../outside.pdf"
    try #require(malformed.notifiedFileName == nil, "notification filenames cannot traverse directories")
    malformed.body = "[文件] 会议报价.pdf\n额外内容"
    try #require(malformed.notifiedFileName == nil, "multiline file descriptions are not guessed as a filename")
    let service = QueryService(paths: paths)
    let output = try service.call("wechat_search_files", arguments: ["query": "报价", "limit": 1])
    try #require(
        output["total"] as? Int == 2 && output["has_more"] as? Bool == true && (output["files"] as? [Any])?.count == 1,
        "file MCP search supports bounded pagination")
    try #require(
        !String(decoding: JSONSerialization.data(withJSONObject: output), as: UTF8.self).contains(
            String(decoding: content, as: UTF8.self)), "MCP returns file metadata without reading or returning contents"
    )
    let enriched = try service.call("wechat_search_messages", arguments: ["query": "会议报价"])
    try #require(
        ((enriched["messages"] as? [[String: Any]])?.first?["file_candidates"] as? [[String: Any]])?.count == 2,
        "message MCP results include filename candidates with provenance")
    var rejected = false
    do { _ = try service.call("wechat_search_files", arguments: ["directory": account.path]) } catch { rejected = true }
    try #require(rejected, "MCP cannot request arbitrary directory scans")
    rejected = false
    do { _ = try Archive(paths: paths, readOnly: true).scanFiles(in: account) } catch { rejected = true }
    try #require(rejected, "read-only catalog connection cannot scan or mutate the index")
    try FileManager.default.removeItem(at: first)
    _ = try store.scanFiles(in: account)
    try #require(
        try store.discoveredFileCount() == 2 && store.fileCandidates(for: message).count == 1,
        "completed rescans mark removed files unavailable")
    let partial = try store.scanFiles(in: account, entryLimit: 1)
    try #require(
        !partial.complete && (try store.discoveredFileCount()) == 2, "partial scans never mark unvisited files missing")
    let record = try store.discoveredFiles(query: "说明").first!
    try FileManager.default.removeItem(at: doc)
    try FileManager.default.createSymbolicLink(at: doc, withDestinationURL: outside)
    rejected = false
    do { _ = try record.url() } catch { rejected = true }
    try #require(rejected, "indexed file later replaced with an escaping symlink cannot be opened")
    let bad = DiscoveredFile(
        id: "fixture", root: root.path, relativePath: "../outside.pdf", name: "outside.pdf", bytes: 1,
        modifiedAt: Dates.string(date), available: true)
    rejected = false
    do { _ = try bad.url() } catch { rejected = true }
    try #require(rejected, "stored relative paths cannot escape the configured root")
    rejected = false
    do { _ = try store.scanFiles(in: account.appendingPathComponent("db_storage")) } catch { rejected = true }
    try #require(rejected, "selecting a database folder does not trigger a broad recursive scan")
    try #require(
        try store.fileScanInfo()["state"] as? String == "blocked",
        "failed directory scans report blocked status instead of retaining a successful scan state")
    let other = base.appendingPathComponent("another-account/msg/file")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try content.write(to: other.appendingPathComponent("另一账号.pdf"))
    _ = try store.scanFiles(in: other)
    try #require(
        try store.discoveredFileCount() == 1 && store.discoveredFileCount(query: "报价") == 0,
        "switching configured account hides files from previous accounts")
    let beforeClear = try Data(contentsOf: other.appendingPathComponent("另一账号.pdf"))
    try store.clear()
    try #require(
        try store.discoveredFileCount() == 0
            && Data(contentsOf: other.appendingPathComponent("另一账号.pdf")) == beforeClear,
        "clearing the catalog never deletes source files")
    let oldPreferences = Data("{\"collectOnLaunch\":true,\"pollSeconds\":2}".utf8)
    try #require(
        try JSONDecoder().decode(Preferences.self, from: oldPreferences).fileDirectory == nil,
        "existing preferences retain collection settings without enabling an unchosen directory")
}
