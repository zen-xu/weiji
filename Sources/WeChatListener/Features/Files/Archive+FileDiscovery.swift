import Foundation

extension Archive {
    func fileScanInfo() throws -> [String: Any] {
        guard let data = try database.rows("SELECT value FROM metadata WHERE key='file_scan'").first?.string("value"),
            let bytes = data.data(using: .utf8),
            let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else {
            return ["state": "not_configured", "files": 0]
        }
        return value
    }
    func fileRoot() throws -> String? {
        try database.rows("SELECT value FROM metadata WHERE key='file_root'").first?.string("value")
    }
    private func recordFileScan(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try database.run(
            "INSERT INTO metadata VALUES('file_scan',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [.text(String(decoding: data, as: UTF8.self))])
    }
    @discardableResult func scanFiles(in selected: URL, entryLimit: Int = 50_000) throws -> FileScanResult {
        guard !readOnly else { throw ListenerError("MCP 只读连接不能扫描或更新文件索引。") }
        let root: URL
        do { root = try FileDiscovery.directory(selected) } catch {
            try recordFileScan([
                "state": "blocked", "root": selected.path, "scanned_at": Dates.string(Date()), "files": 0,
            ])
            throw error
        }
        try database.run(
            "INSERT INTO metadata VALUES('file_root',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [.text(root.path)])
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            .isPackageKey,
        ]
        var failures = 0
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    failures += 1
                    return true
                })
        else {
            try recordFileScan(["state": "blocked", "root": root.path, "scanned_at": Dates.string(Date()), "files": 0])
            throw ListenerError("无法读取微信文件目录，请检查目录访问权限。")
        }
        var files = [DiscoveredFile]()
        var entries = 0
        var capped = false
        for case let url as URL in enumerator {
            entries += 1
            if entries > entryLimit {
                capped = true
                break
            }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true, values.isPackage != true else { continue }
                let ext = url.pathExtension.lowercased()
                guard !ext.isEmpty, !FileDiscovery.excludedExtensions.contains(ext) else { continue }
                let resolved = url.standardizedFileURL
                guard resolved.path.hasPrefix(root.path + "/") else { continue }
                let relative = String(resolved.path.dropFirst(root.path.count + 1))
                let file = DiscoveredFile(
                    id: digest("wechat-file-v1|\(root.path)|\(relative)"), root: root.path,
                    relativePath: relative, name: url.lastPathComponent, bytes: Int64(values.fileSize ?? 0),
                    modifiedAt: Dates.string(values.contentModificationDate ?? .distantPast), available: true)
                _ = try file.url()
                files.append(file)
            } catch { failures += 1 }
        }
        let result = FileScanResult(
            root: root.path, scannedAt: Dates.string(Date()), files: files.count,
            complete: !capped && failures == 0, failures: failures)
        let scan = UUID().uuidString
        try database.transaction {
            let previous = Dictionary(
                uniqueKeysWithValues: try database.rows(
                    "SELECT id,bytes,modified_at,available FROM discovered_files WHERE root=?", [.text(root.path)]
                ).map { ($0.string("id")!, $0) })
            let seen = Set(files.map { $0.id })
            for file in files {
                if let old = previous[file.id], old.int("available") == 1,
                    old.int("bytes") == file.bytes, old.string("modified_at") == file.modifiedAt
                {
                    continue
                }
                try database.run(
                    """
                    INSERT INTO discovered_files VALUES(?,?,?,?,?,?,?,?,1)
                    ON CONFLICT(id) DO UPDATE SET name=excluded.name,match_name=excluded.match_name,
                    bytes=excluded.bytes,modified_at=excluded.modified_at,scan=excluded.scan,available=1
                    """,
                    [
                        .text(file.id), .text(file.root), .text(file.relativePath), .text(file.name),
                        .text(file.name.precomposedStringWithCanonicalMapping), .integer(file.bytes),
                        .text(file.modifiedAt), .text(scan),
                    ])
            }
            if result.complete {
                for (id, old) in previous where old.int("available") == 1 && !seen.contains(id) {
                    try database.run("UPDATE discovered_files SET available=0 WHERE id=?", [.text(id)])
                }
            }
            var info = try object(result) as! [String: Any]
            info["state"] = result.complete ? "ready" : "partial"
            try recordFileScan(info)
        }
        return result
    }
    private func fileFilter(_ query: String, name: String? = nil) throws -> (String, [SQLValue]) {
        guard hasFileCatalog, let root = try fileRoot() else { return ("0", []) }
        var clause = "root=? AND available=1"
        var args: [SQLValue] = [.text(root)]
        if !query.isEmpty {
            clause += " AND instr(lower(name),lower(?))>0"
            args.append(.text(query))
        }
        if let name {
            clause += " AND match_name=?"
            args.append(.text(name.precomposedStringWithCanonicalMapping))
        }
        return (clause, args)
    }
    func discoveredFiles(query: String = "", name: String? = nil, limit: Int = 100, offset: Int = 0) throws
        -> [DiscoveredFile]
    {
        guard hasFileCatalog else { return [] }
        let (clause, args) = try fileFilter(query, name: name)
        return try database.rows(
            "SELECT * FROM discovered_files WHERE \(clause) ORDER BY modified_at DESC,id LIMIT ? OFFSET ?",
            args + [.integer(Int64(max(1, min(limit, 201)))), .integer(Int64(max(0, offset)))]
        ).map { row in
            DiscoveredFile(
                id: row.string("id")!, root: row.string("root")!, relativePath: row.string("relative_path")!,
                name: row.string("name")!, bytes: row.int("bytes")!, modifiedAt: row.string("modified_at")!,
                available: row.int("available") == 1)
        }
    }
    func discoveredFileCount(query: String = "", name: String? = nil) throws -> Int {
        guard hasFileCatalog else { return 0 }
        let (clause, args) = try fileFilter(query, name: name)
        return Int(
            try database.rows("SELECT COUNT(*) AS n FROM discovered_files WHERE \(clause)", args).first?.int("n") ?? 0)
    }
    func fileCandidates(for message: Message) throws -> [[String: Any]] {
        guard message.notificationPlatform == .wechat, let name = message.notifiedFileName else { return [] }
        let files = try discoveredFiles(name: name, limit: 20)
        let count = try discoveredFileCount(name: name)
        return try files.sorted {
            abs((Dates.parse($0.modifiedAt) ?? .distantPast).timeIntervalSince(message.date))
                < abs((Dates.parse($1.modifiedAt) ?? .distantPast).timeIntervalSince(message.date))
        }.map { file in
            var value = try file.objectValue()
            value["match_basis"] = "exact_notification_filename"
            value["same_name_count"] = count
            value["message_link_verified"] = false
            value["seconds_from_notification"] = (Dates.parse(file.modifiedAt) ?? .distantPast).timeIntervalSince(
                message.date)
            return value
        }
    }
}
