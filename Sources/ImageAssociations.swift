import Foundation

struct ImageAssociation: Identifiable {
    let file: DiscoveredFile
    let scope: String
    let format: String
    let family: String
    let secondsFromNotification: Double
    let nearbyNotificationIDs: [String]
    var preview: ImagePreview? = nil
    var anchorFileIDs: [String] = []
    var imageNotificationCaptured = true
    var matchesTimeWindow: Bool { abs(secondsFromNotification) <= ImageAssociations.window }
    var groupKey: String { file.root + "|" + scope + "|" + (file.relativePath as NSString).deletingLastPathComponent + "|" + family }
    var isThumbnail: Bool { ["_t", "_t_M", "_thumb"].contains { URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent.hasSuffix($0) } }
    var id: String { file.id }
    var formatLabel: String {
        switch format {
        case "wechat_v2_dat", "wechat_dat": return "微信图片文件（DAT）"
        case "jpeg": return "JPEG"
        case "png": return "PNG"
        case "gif": return "GIF"
        case "unreadable": return "未读取文件格式"
        default: return "图片文件"
        }
    }
    func objectValue(paths: AppPaths? = nil) throws -> [String: Any] {
        var value = try file.objectValue()
        value["source"] = "wechat_image_directory"
        value["association_basis"] = matchesTimeWindow ? "conversation_directory_and_timestamp" : "same_asset_family_as_timestamp_candidate"
        value["within_time_window"] = matchesTimeWindow
        value["image_notification_captured"] = imageNotificationCaptured
        value["notification_anchor_kind"] = imageNotificationCaptured ? "image_notification" : "nearby_conversation_notification"
        value["message_link_verified"] = false
        value["sender_verified"] = false
        value["image_message_direction"] = "unknown_from_directory"
        value["anchor_file_ids"] = anchorFileIDs
        value["asset_variant"] = isThumbnail ? "thumbnail" : "larger_or_standard_variant"
        value["conversation_directory_id"] = scope
        value["format_hint"] = format
        value["file_family"] = family
        value["seconds_from_notification"] = secondsFromNotification
        value["window_seconds"] = ImageAssociations.window
        value["timestamp_source"] = "notification_delivered_at"
        value["nearby_image_notification_ids"] = nearbyNotificationIDs
        value["assessment_by"] = "ai_client"
        value["content_returned"] = false
        value["preview"] = preview?.objectValue(paths: paths) ?? ["state": "not_prepared"]
        return value
    }
}

struct ImageAssociationGroup: Identifiable {
    let id: String
    let versions: [ImageAssociation]
    var preferred: ImageAssociation { versions[0] }
}

struct ImageAssociationScan: Codable {
    var state: String
    var files: Int
    var messages: Int
    var anchorNotifications: Int? = nil
    var failures: Int
    var complete: Bool
    var scannedAt: String
    enum CodingKeys: String, CodingKey { case state, files, messages, failures, complete; case scannedAt = "scanned_at"; case anchorNotifications = "anchor_notifications" }
}

enum ImageAssociations {
    static let window: TimeInterval = 30
    static func validScope(_ scope: String) -> Bool { scope.count == 32 && scope.allSatisfy { $0.isHexDigit } }
    static func family(_ name: String) -> String {
        var stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        for suffix in ["_t_M", "_h_M", "_thumb", "_hd", "_t", "_h", "_b", "_w", "_c", "_M"] {
            if stem.hasSuffix(suffix) { stem.removeLast(suffix.count); break }
        }
        return stem
    }
    static func groups(_ items: [ImageAssociation]) -> [ImageAssociationGroup] {
        Dictionary(grouping: items, by: { $0.groupKey }).map { key, values in
            let sorted = values.sorted {
                let a = $0.preview, b = $1.preview
                if (a?.state == "ready") != (b?.state == "ready") { return a?.state == "ready" }
                let pixelsA = (a?.width ?? 0) * (a?.height ?? 0), pixelsB = (b?.width ?? 0) * (b?.height ?? 0)
                if pixelsA != pixelsB { return pixelsA > pixelsB }
                if $0.isThumbnail != $1.isThumbnail { return !$0.isThumbnail }
                if $0.file.bytes != $1.file.bytes { return $0.file.bytes > $1.file.bytes }
                return $0.id < $1.id
            }
            return ImageAssociationGroup(id: key, versions: sorted)
        }.sorted {
            let a = $0.versions.map { abs($0.secondsFromNotification) }.min() ?? .infinity
            let b = $1.versions.map { abs($0.secondsFromNotification) }.min() ?? .infinity
            return a == b ? $0.id < $1.id : a < b
        }
    }
    static func familyKey(_ file: DiscoveredFile) -> String { (file.relativePath as NSString).deletingLastPathComponent + "|" + family(file.name) }
    static func format(_ url: URL) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { return "unreadable" }
        defer { try? file.close() }
        let head = (try? file.read(upToCount: 6)) ?? Data()
        if head.starts(with: [7, 8, 86, 50, 8, 7]) { return "wechat_v2_dat" }
        if head.starts(with: [255, 216, 255]) { return "jpeg" }
        if head.starts(with: [137, 80, 78, 71]) { return "png" }
        if head.starts(with: Array("GIF8".utf8)) { return "gif" }
        return url.pathExtension.lowercased() == "dat" ? "wechat_dat" : "image_file"
    }
}

extension Message {
    var isImageNotification: Bool { presentation.body.trimmingCharacters(in: .whitespacesAndNewlines) == "[图片]" }
}

extension Archive {
    private func indexedMediaAnchors() throws -> (items: [Message], capped: Bool) {
        let rows = try database.rows("SELECT payload FROM messages ORDER BY sort_at DESC LIMIT 5001")
        let items: [Message] = try rows.prefix(5000).compactMap {
            guard let payload = $0.data("payload") else { return nil }
            let message = try JSONDecoder().decode(Message.self, from: payload)
            return message
        }
        return (items, rows.count > 5000)
    }
    func imageScanInfo() throws -> [String: Any] {
        guard let value = try database.rows("SELECT value FROM metadata WHERE key='image_scan'").first?.string("value"),
              let data = value.data(using: .utf8), let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["state": "not_scanned", "files": 0]
        }
        return info
    }
    private func saveImageScan(_ result: ImageAssociationScan) throws {
        try database.run("INSERT INTO metadata VALUES('image_scan',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                         [.text(String(decoding: try jsonData(result), as: UTF8.self))])
    }
    @discardableResult func scanImageAssociations(fileRoot: URL, entryLimit: Int = 50_000) throws -> ImageAssociationScan {
        guard !readOnly else { throw ListenerError("MCP 只读连接不能更新图片关联索引。") }
        let directory = try FileDiscovery.directory(fileRoot)
        let account = directory.deletingLastPathComponent().deletingLastPathComponent()
        let attach = account.appendingPathComponent("msg/attach", isDirectory: true)
        let messages = try indexedMediaAnchors()
        let eligible = messages.items.filter { $0.deliveredAt != nil && $0.mediaDirectoryID.map(ImageAssociations.validScope) == true }
        let byScope = Dictionary(grouping: eligible, by: { $0.mediaDirectoryID! })
        let stamp = UUID().uuidString
        var indexed = [(DiscoveredFile, String, String)](), failures = 0, entries = 0, capped = messages.capped
        try database.run("INSERT INTO metadata VALUES('image_root',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(account.path)])
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let previous = Dictionary(uniqueKeysWithValues: try database.rows("SELECT id,bytes,modified_at,format,available FROM image_files WHERE root=?", [.text(account.path)]).map { ($0.string("id")!, $0) })
        var scopes = Set(byScope.keys)
        if let folders = try? FileManager.default.contentsOfDirectory(at: attach, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for folder in folders where ImageAssociations.validScope(folder.lastPathComponent) {
                let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isDirectory == true && values?.isSymbolicLink != true { scopes.insert(folder.lastPathComponent) }
            }
        }
        for scope in scopes.sorted() {
            let folder = attach.appendingPathComponent(scope, isDirectory: true)
            let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path == folder.standardizedFileURL.path else { failures += 1; continue }
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in failures += 1; return true }) else { failures += 1; continue }
            var discovered = [DiscoveredFile]()
            for case let url as URL in enumerator {
                entries += 1
                if entries > entryLimit { capped = true; break }
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    guard values.isRegularFile == true, let modified = values.contentModificationDate,
                          ["dat", "png", "jpg", "jpeg", "gif", "webp", "heic"].contains(url.pathExtension.lowercased()),
                          url.pathComponents.contains("Img") else { continue }
                    let path = url.standardizedFileURL.path
                    guard path.hasPrefix(account.path + "/") else { failures += 1; continue }
                    let relative = String(path.dropFirst(account.path.count + 1))
                    let file = DiscoveredFile(id: digest("wechat-image-association-v1|\(account.path)|\(relative)"), root: account.path,
                        relativePath: relative, name: url.lastPathComponent, bytes: Int64(values.fileSize ?? 0),
                        modifiedAt: Dates.string(modified), available: true)
                    _ = try file.url()
                    discovered.append(file)
                } catch { failures += 1 }
            }
            for file in discovered {
                if let old = previous[file.id], old.int("bytes") == file.bytes,
                   old.string("modified_at") == file.modifiedAt, let format = old.string("format"), format != "unreadable" {
                    indexed.append((file, scope, format))
                }
                else if let url = try? file.url() { indexed.append((file, scope, ImageAssociations.format(url))) }
                else { failures += 1 }
            }
            if entries > entryLimit { break }
        }
        var result = ImageAssociationScan(state: capped || failures > 0 ? "partial" : "ready", files: indexed.count,
            messages: eligible.filter { $0.isImageNotification }.count, failures: failures, complete: !capped && failures == 0, scannedAt: Dates.string(Date()))
        result.anchorNotifications = eligible.count
        try database.transaction {
            let seen = Set(indexed.map { $0.0.id })
            for (file, scope, format) in indexed {
                if let old = previous[file.id], old.int("available") == 1, old.int("bytes") == file.bytes,
                   old.string("modified_at") == file.modifiedAt, old.string("format") == format { continue }
                try database.run("""
                    INSERT INTO image_files VALUES(?,?,?,?,?,?,?,?,?,?,1)
                    ON CONFLICT(id) DO UPDATE SET bytes=excluded.bytes,modified_at=excluded.modified_at,
                    format=excluded.format,scan=excluded.scan,available=1
                    """, [.text(file.id), .text(file.root), .text(scope), .text(file.relativePath), .text(file.name),
                           .integer(file.bytes), .text(file.modifiedAt), .text(format), .text(ImageAssociations.family(file.name)), .text(stamp)])
            }
            if result.complete {
                for (id, old) in previous where old.int("available") == 1 && !seen.contains(id) {
                    try database.run("UPDATE image_files SET available=0 WHERE id=?", [.text(id)])
                }
            }
            try saveImageScan(result)
        }
        return result
    }
    func imageAssociations(for message: Message) throws -> [ImageAssociation] {
        guard hasImageCatalog, message.deliveredAt != nil,
              let scope = message.mediaDirectoryID, ImageAssociations.validScope(scope),
              let root = try database.rows("SELECT value FROM metadata WHERE key='image_root'").first?.string("value") else { return [] }
        let from = Dates.string(message.date.addingTimeInterval(-ImageAssociations.window))
        let to = Dates.string(message.date.addingTimeInterval(ImageAssociations.window))
        let nearby = try database.rows("SELECT id,payload FROM messages WHERE conversation_id=? AND sort_at>=? AND sort_at<=? AND id<>? AND instr(body,'[图片]')>0 ORDER BY sort_at,id LIMIT 100",
            [.text(message.conversationID), .text(from), .text(to), .text(message.id)]).compactMap { row -> String? in
                guard let bytes = row.data("payload"), let item = try? JSONDecoder().decode(Message.self, from: bytes), item.isImageNotification else { return nil }
                return row.string("id")
            }
        let anchors = try database.rows("SELECT * FROM image_files WHERE root=? AND scope=? AND available=1 AND modified_at>=? AND modified_at<=? ORDER BY modified_at,id LIMIT 100",
            [.text(root), .text(scope), .text(from), .text(to)])
        func file(_ row: [String: SQLValue]) -> DiscoveredFile {
            DiscoveredFile(id: row.string("id")!, root: root, relativePath: row.string("relative_path")!, name: row.string("name")!,
                bytes: row.int("bytes")!, modifiedAt: row.string("modified_at")!, available: true)
        }
        // A directory observation is a candidate near an existing notification, never a fabricated image message.
        let potential: [Message]
        if message.isImageNotification { potential = [] }
        else {
            let lower = Dates.string(message.date.addingTimeInterval(-ImageAssociations.window * 2))
            let upper = Dates.string(message.date.addingTimeInterval(ImageAssociations.window * 2))
            potential = try database.rows("SELECT payload FROM messages WHERE conversation_id=? AND sort_at>=? AND sort_at<=? ORDER BY sort_at,id LIMIT 1001",
                [.text(message.conversationID), .text(lower), .text(upper)]).compactMap { row in
                    guard let data = row.data("payload"), let item = try? JSONDecoder().decode(Message.self, from: data),
                          item.deliveredAt != nil, item.mediaDirectoryID == scope else { return nil }
                    return item
                }
            // In a heavily merged conversation leave ambiguous overflow unassigned.
            if potential.count > 1000 { return [] }
        }
        let anchorGroups = Dictionary(grouping: anchors, by: { ImageAssociations.familyKey(file($0)) })
        var results = [ImageAssociation]()
        for key in anchorGroups.keys.sorted() {
            let group = anchorGroups[key]!
            let family = group[0].string("family")!
            let variants = try database.rows("SELECT * FROM image_files WHERE root=? AND scope=? AND family=? AND available=1 ORDER BY modified_at,id LIMIT 100",
                [.text(root), .text(scope), .text(family)]).filter { ImageAssociations.familyKey(file($0)) == key }
            if !message.isImageNotification {
                guard let firstSeen = variants.compactMap({ $0.string("modified_at").flatMap(Dates.parse) }).min(),
                      abs(firstSeen.timeIntervalSince(message.date)) <= ImageAssociations.window else { continue }
                let possible = potential.filter { abs(firstSeen.timeIntervalSince($0.date)) <= ImageAssociations.window }
                if possible.contains(where: { $0.isImageNotification }) { continue }
                let nearest = possible.min {
                    let a = abs(firstSeen.timeIntervalSince($0.date)), b = abs(firstSeen.timeIntervalSince($1.date))
                    return a == b ? $0.id < $1.id : a < b
                }
                guard nearest?.id == message.id else { continue }
            }
            for row in variants {
                let candidate = file(row)
                results.append(ImageAssociation(file: candidate, scope: scope, format: row.string("format")!, family: family,
                    secondsFromNotification: (Dates.parse(candidate.modifiedAt) ?? .distantPast).timeIntervalSince(message.date), nearbyNotificationIDs: nearby,
                    preview: try imagePreview(for: candidate), anchorFileIDs: group.compactMap { $0.string("id") }.sorted(), imageNotificationCaptured: message.isImageNotification))
            }
        }
        return results.sorted { abs($0.secondsFromNotification) < abs($1.secondsFromNotification) }.prefix(200).map { $0 }
    }
}
