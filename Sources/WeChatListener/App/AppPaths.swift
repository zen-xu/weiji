import Foundation

struct AppPaths {
    let root: URL
    let logs: URL
    var database: URL { root.appendingPathComponent("archive.sqlite") }
    var journal: URL { root.appendingPathComponent("events.jsonl") }
    var exports: URL { root.appendingPathComponent("Exports", isDirectory: true) }
    var preferences: URL { root.appendingPathComponent("preferences.json") }
    var source: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Group Containers/group.com.apple.usernoted/db2/db")
    }
    init(override: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        root =
            override.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? home.appendingPathComponent("Library/Application Support/WeChatListener", isDirectory: true)
        logs =
            override == nil
            ? home.appendingPathComponent("Library/Logs/WeChatListener", isDirectory: true)
            : root.appendingPathComponent("Logs", isDirectory: true)
    }
    func prepare() throws {
        for url in [root, logs, exports] {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }
    func log(_ code: String) {
        // Callers supply fixed diagnostic codes only, never message text or source errors.
        let url = logs.appendingPathComponent("listener.log")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            let previous = logs.appendingPathComponent("listener.previous.log")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(Dates.string(Date())) \(code)\n".utf8))
    }
}
