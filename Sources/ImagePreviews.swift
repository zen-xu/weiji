import Foundation
import ImageIO

struct ImagePreview: Codable, Identifiable {
    let fileID: String
    let stamp: String
    let token: String
    var state: String
    var errorCode: String?
    var width = 0
    var height = 0
    var updatedAt = Dates.string(Date())
    var id: String { fileID }
    var label: String { errorCode.flatMap(ImageDecodeError.init(rawValue:))?.label ?? "正在准备图片预览" }
    static func stamp(_ file: DiscoveredFile) -> String { digest("preview-v2|\(file.id)|\(file.bytes)|\(file.modifiedAt)") }
    static func directory(paths: AppPaths) -> URL { paths.root.appendingPathComponent("ImagePreviews", isDirectory: true) }
    func url(paths: AppPaths, name: String = "image.png") throws -> URL {
        guard token.count == 64, token.allSatisfy({ $0.isHexDigit }), ["image.png", "thumbnail.jpg", "thumbnail.png", "mcp.jpg"].contains(name) else { throw ImageDecodeError.invalidData }
        let root = Self.directory(paths: paths).standardizedFileURL
        let url = root.appendingPathComponent(token, isDirectory: true).appendingPathComponent(name).standardizedFileURL
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              url.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw ImageDecodeError.invalidData }
        return url
    }
    func objectValue(paths: AppPaths?) -> [String: Any] {
        var value: [String: Any] = ["state": state, "width": width, "height": height, "updated_at": updatedAt,
            "preview_kind": "static_image", "mime_type": "image/png"]
        if let errorCode { value["error_code"] = errorCode }
        if state == "ready", let paths, let local = try? url(paths: paths) { value["local_path"] = local.path }
        return value
    }
    func validFile(paths: AppPaths, name: String = "image.png") throws -> URL {
        guard state == "ready" else { throw ImageDecodeError.invalidData }
        let url = try self.url(paths: paths, name: name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize,
              bytes > 0, bytes <= 16 * 1024 * 1024 else { throw ImageDecodeError.invalidData }
        return url
    }
}

extension Archive {
    func imagePreview(for file: DiscoveredFile) throws -> ImagePreview? {
        guard hasPreviewCatalog else { return nil }
        return imagePreview(for: file, payload: try database.rows("SELECT payload FROM image_previews WHERE file_id=?", [.text(file.id)]).first?.data("payload"))
    }
    func imagePreview(for file: DiscoveredFile, payload: Data?) -> ImagePreview? {
        guard let payload, var value = try? JSONDecoder().decode(ImagePreview.self, from: payload), value.fileID == file.id,
              value.stamp == ImagePreview.stamp(file) else { return nil }
        if value.state == "ready", (try? value.validFile(paths: paths)) == nil { value.state = "pending" }
        return value
    }
    func imagePreviewStatus() throws -> [String: Any] {
        guard hasPreviewCatalog else { return ["state": "not_prepared", "ready": 0] }
        var ready = 0, failed = 0
        for row in try database.rows("SELECT p.payload FROM image_previews p JOIN image_files i ON p.file_id=i.id WHERE i.available=1 AND i.root=(SELECT value FROM metadata WHERE key='image_root')") {
            if let bytes = row.data("payload"), let item = try? JSONDecoder().decode(ImagePreview.self, from: bytes) {
                if item.state == "ready" { ready += 1 } else { failed += 1 }
            }
        }
        return ["state": "prepared", "ready": ready, "unavailable": failed, "content_storage": "local_plaintext_cache"]
    }
    @discardableResult func prepareImagePreviews(limit: Int = 100, fileIDs: [String]? = nil) throws -> [String: Int] {
        guard !readOnly else { throw ListenerError("MCP 不能解密或写入图片缓存，请在应用中扫描。") }
        guard let root = try database.rows("SELECT value FROM metadata WHERE key='image_root'").first?.string("value") else { return ["ready": 0, "unavailable": 0] }
        let rows: [[String: SQLValue]]
        if let fileIDs {
            let ids = Array(Set(fileIDs)).sorted().prefix(100)
            guard !ids.isEmpty else { return ["ready": 0, "unavailable": 0] }
            rows = try database.rows("SELECT * FROM image_files WHERE root=? AND available=1 AND id IN (" + ids.map { _ in "?" }.joined(separator: ",") + ") ORDER BY modified_at DESC", [.text(root)] + ids.map { .text($0) })
        } else {
            rows = try database.rows("SELECT * FROM image_files WHERE root=? AND available=1 ORDER BY modified_at DESC LIMIT 200", [.text(root)])
        }
        let account = URL(fileURLWithPath: root, isDirectory: true)
        var keys: [ImageKey]?
        var ready = 0, unavailable = 0, attempts = 0
        for row in rows {
            let file = DiscoveredFile(id: row.string("id")!, root: root, relativePath: row.string("relative_path")!, name: row.string("name")!,
                bytes: row.int("bytes")!, modifiedAt: row.string("modified_at")!, available: true)
            if let old = try imagePreview(for: file) {
                if old.state == "ready", (try? old.validFile(paths: paths, name: "thumbnail.png")) != nil,
                    (try? old.validFile(paths: paths, name: "mcp.jpg")) != nil { ready += 1; continue }
                if old.state == "unavailable", Date().timeIntervalSince(Dates.parse(old.updatedAt) ?? .distantPast) < 60 { unavailable += 1; continue }
            }
            guard attempts < limit else { continue }; attempts += 1
            // Release ImageIO/VideoToolbox buffers after each image, rather than after an entire scan batch.
            try autoreleasepool {
                let stamp = ImagePreview.stamp(file)
                var preview = ImagePreview(fileID: file.id, stamp: stamp, token: digest("image-cache|" + stamp), state: "unavailable")
                do {
                    guard file.bytes > 0, file.bytes <= ImageDecoder.maxBytes else { throw ImageDecodeError.tooLarge }
                    let url = try file.url()
                    let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                    guard attributes.isRegularFile == true, attributes.fileSize == Int(file.bytes),
                          attributes.contentModificationDate.map(Dates.string) == file.modifiedAt else { throw ImageDecodeError.sourceChanged }
                    let handle = try FileHandle(forReadingFrom: url)
                    let data: Data
                    do { data = try handle.read(upToCount: ImageDecoder.maxBytes + 1) ?? Data(); try handle.close() }
                    catch { try? handle.close(); throw error }
                    guard data.count == file.bytes else { throw ImageDecodeError.sourceChanged }
                    if data.starts(with: [7, 8, 86, 50, 8, 7]), keys == nil { keys = ImageKeys.candidates(account: account) }
                    let (payload, _) = try ImageDecoder.payload(data, keys: keys ?? [])
                    let image = try ImageDecoder.image(payload)
                    let output = try preview.url(paths: paths)
                    for directory in [ImagePreview.directory(paths: paths), output.deletingLastPathComponent()] {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                    }
                    try ImagePreviewWriter.write(image, to: output, type: "public.png")
                    try ImagePreviewWriter.write(image, to: preview.url(paths: paths, name: "thumbnail.png"), type: "public.png", maximum: 1024)
                    try ImagePreviewWriter.write(image, to: preview.url(paths: paths, name: "mcp.jpg"), type: "public.jpeg", maximum: 1280)
                    preview.state = "ready"; preview.width = image.width; preview.height = image.height; ready += 1
                } catch {
                    preview.errorCode = (error as? ImageDecodeError ?? .invalidData).rawValue; unavailable += 1
                }
                try database.run("INSERT INTO image_previews VALUES(?,?) ON CONFLICT(file_id) DO UPDATE SET payload=excluded.payload",
                                 [.text(file.id), .blob(try jsonData(preview))])
            }
        }
        return ["ready": ready, "unavailable": unavailable]
    }
    func cachedImage(messageID: String, fileID: String) throws -> (Data, [String: Any]) {
        guard let payload = try database.rows("SELECT payload FROM messages WHERE id=?", [.text(messageID)]).first?.data("payload"),
              let message = try? JSONDecoder().decode(Message.self, from: payload) else { throw ListenerError("未找到图片消息。") }
        guard let association = try imageAssociations(for: message).first(where: { $0.id == fileID }), let preview = association.preview,
              preview.state == "ready" else { throw ListenerError("该消息尚无可用图片预览，请在应用中重新扫描。") }
        let url = try preview.validFile(paths: paths, name: "mcp.jpg")
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 2 * 1024 * 1024, bytes.starts(with: [255,216,255]) else { throw ListenerError("图片预览无效或过大。") }
        return (bytes, ["message_id": messageID, "file_id": fileID, "mime_type": "image/jpeg", "association": try association.objectValue(paths: paths)])
    }
    func clearImagePreviews() throws {
        let root = ImagePreview.directory(paths: paths)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else { throw ImageDecodeError.invalidData }
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

enum ImagePreviewWriter {
    static func write(_ image: CGImage, to url: URL, type: String, maximum: Int = 4096) throws {
        let scale = min(1, Double(maximum) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageDecodeError.invalidData }
        context.setFillColor(CGColor.white); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let resized = context.makeImage() else { throw ImageDecodeError.invalidData }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw ImageDecodeError.invalidData }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 16 * 1024 * 1024 else { throw ImageDecodeError.tooLarge }
        try (data as Data).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
