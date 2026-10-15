import Foundation

struct DiscoveredFile: Codable, Identifiable, Equatable {
    let id: String
    let root: String
    let relativePath: String
    let name: String
    let bytes: Int64
    let modifiedAt: String
    let available: Bool
    enum CodingKeys: String, CodingKey {
        case id, root, name, bytes, available
        case relativePath = "relative_path", modifiedAt = "modified_at"
    }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    func url() throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw ListenerError("文件索引路径无效。") }
        let directory = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let file = directory.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(directory.path + "/") else { throw ListenerError("文件已移出探测目录。") }
        return file
    }
    func objectValue() throws -> [String: Any] {
        ["id": id, "name": name, "bytes": bytes, "modified_at": modifiedAt,
         "local_path": try url().path, "available_at_last_scan": available, "source": "wechat_file_directory"]
    }
}

struct FileScanResult: Codable {
    let root: String
    let scannedAt: String
    let files: Int
    let complete: Bool
    let failures: Int
    enum CodingKeys: String, CodingKey { case root, files, complete, failures; case scannedAt = "scanned_at" }
}

extension Message {
    var notifiedFileName: String? {
        let body = presentation.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("[文件]") else { return nil }
        let name = body.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains("\0"), !name.contains(where: { $0.isNewline }) else { return nil }
        return name.precomposedStringWithCanonicalMapping
    }
}

enum FileDiscovery {
    static let excludedExtensions: Set<String> = ["dat", "db", "sqlite", "sqlite3", "tmp", "part", "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "ico"]
    static func directory(_ selected: URL) throws -> URL {
        let selected = selected.resolvingSymlinksInPath().standardizedFileURL
        let result: URL
        if selected.lastPathComponent == "file", selected.deletingLastPathComponent().lastPathComponent == "msg" { result = selected }
        else { result = selected.appendingPathComponent("msg/file", isDirectory: true) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: result.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ListenerError("未找到 msg/file。请选择微信账号目录或它下面的 msg/file 文件夹。")
        }
        // Do not traverse an account's database, image or cache directories.
        return result.resolvingSymlinksInPath().standardizedFileURL
    }
}

extension Archive {
    func fileScanInfo() throws -> [String: Any] {
        guard let data = try database.rows("SELECT value FROM metadata WHERE key='file_scan'").first?.string("value"),
              let bytes = data.data(using: .utf8), let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            return ["state": "not_configured", "files": 0]
        }
        return value
    }
    func fileRoot() throws -> String? {
        try database.rows("SELECT value FROM metadata WHERE key='file_root'").first?.string("value")
    }
    private func recordFileScan(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try database.run("INSERT INTO metadata VALUES('file_scan',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                         [.text(String(decoding: data, as: UTF8.self))])
    }
    @discardableResult func scanFiles(in selected: URL, entryLimit: Int = 50_000) throws -> FileScanResult {
        guard !readOnly else { throw ListenerError("MCP 只读连接不能扫描或更新文件索引。") }
        let root: URL
        do { root = try FileDiscovery.directory(selected) }
        catch {
            try recordFileScan(["state": "blocked", "root": selected.path, "scanned_at": Dates.string(Date()), "files": 0])
            throw error
        }
        try database.run("INSERT INTO metadata VALUES('file_root',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(root.path)])
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        var failures = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in failures += 1; return true }) else {
            try recordFileScan(["state": "blocked", "root": root.path, "scanned_at": Dates.string(Date()), "files": 0])
            throw ListenerError("无法读取微信文件目录，请检查目录访问权限。")
        }
        var files = [DiscoveredFile](), entries = 0, capped = false
        for case let url as URL in enumerator {
            entries += 1
            if entries > entryLimit { capped = true; break }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true, values.isPackage != true else { continue }
                let ext = url.pathExtension.lowercased()
                guard !ext.isEmpty, !FileDiscovery.excludedExtensions.contains(ext) else { continue }
                let resolved = url.standardizedFileURL
                guard resolved.path.hasPrefix(root.path + "/") else { continue }
                let relative = String(resolved.path.dropFirst(root.path.count + 1))
                let file = DiscoveredFile(id: digest("wechat-file-v1|\(root.path)|\(relative)"), root: root.path,
                    relativePath: relative, name: url.lastPathComponent, bytes: Int64(values.fileSize ?? 0),
                    modifiedAt: Dates.string(values.contentModificationDate ?? .distantPast), available: true)
                _ = try file.url()
                files.append(file)
            } catch { failures += 1 }
        }
        let result = FileScanResult(root: root.path, scannedAt: Dates.string(Date()), files: files.count,
                                    complete: !capped && failures == 0, failures: failures)
        let scan = UUID().uuidString
        try database.transaction {
            for file in files {
                try database.run("""
                    INSERT INTO discovered_files VALUES(?,?,?,?,?,?,?,?,1)
                    ON CONFLICT(id) DO UPDATE SET name=excluded.name,match_name=excluded.match_name,
                    bytes=excluded.bytes,modified_at=excluded.modified_at,scan=excluded.scan,available=1
                    """, [.text(file.id), .text(file.root), .text(file.relativePath), .text(file.name),
                           .text(file.name.precomposedStringWithCanonicalMapping), .integer(file.bytes), .text(file.modifiedAt), .text(scan)])
            }
            if result.complete {
                try database.run("UPDATE discovered_files SET available=0 WHERE root=? AND scan<>?", [.text(root.path), .text(scan)])
            }
            var info = try object(result) as! [String: Any]
            info["state"] = result.complete ? "ready" : "partial"
            try recordFileScan(info)
        }
        return result
    }
    private func fileFilter(_ query: String, name: String? = nil) throws -> (String, [SQLValue]) {
        guard hasFileCatalog, let root = try fileRoot() else { return ("0", []) }
        var clause = "root=? AND available=1", args: [SQLValue] = [.text(root)]
        if !query.isEmpty { clause += " AND instr(lower(name),lower(?))>0"; args.append(.text(query)) }
        if let name { clause += " AND match_name=?"; args.append(.text(name.precomposedStringWithCanonicalMapping)) }
        return (clause, args)
    }
    func discoveredFiles(query: String = "", name: String? = nil, limit: Int = 100, offset: Int = 0) throws -> [DiscoveredFile] {
        guard hasFileCatalog else { return [] }
        let (clause, args) = try fileFilter(query, name: name)
        return try database.rows("SELECT * FROM discovered_files WHERE \(clause) ORDER BY modified_at DESC,id LIMIT ? OFFSET ?",
            args + [.integer(Int64(max(1, min(limit, 200)))), .integer(Int64(max(0, offset)))]).map { row in
                DiscoveredFile(id: row.string("id")!, root: row.string("root")!, relativePath: row.string("relative_path")!,
                    name: row.string("name")!, bytes: row.int("bytes")!, modifiedAt: row.string("modified_at")!, available: row.int("available") == 1)
            }
    }
    func discoveredFileCount(query: String = "", name: String? = nil) throws -> Int {
        guard hasFileCatalog else { return 0 }
        let (clause, args) = try fileFilter(query, name: name)
        return Int(try database.rows("SELECT COUNT(*) AS n FROM discovered_files WHERE \(clause)", args).first?.int("n") ?? 0)
    }
    func fileCandidates(for message: Message) throws -> [[String: Any]] {
        guard let name = message.notifiedFileName else { return [] }
        let files = try discoveredFiles(name: name, limit: 20)
        let count = try discoveredFileCount(name: name)
        return try files.sorted {
            abs((Dates.parse($0.modifiedAt) ?? .distantPast).timeIntervalSince(message.date)) < abs((Dates.parse($1.modifiedAt) ?? .distantPast).timeIntervalSince(message.date))
        }.map { file in
            var value = try file.objectValue()
            value["match_basis"] = "exact_notification_filename"
            value["same_name_count"] = count
            value["message_link_verified"] = false
            value["seconds_from_notification"] = (Dates.parse(file.modifiedAt) ?? .distantPast).timeIntervalSince(message.date)
            return value
        }
    }
}
