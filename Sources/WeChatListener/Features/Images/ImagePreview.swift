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
    static func stamp(_ file: DiscoveredFile) -> String {
        digest("preview-v2|\(file.id)|\(file.bytes)|\(file.modifiedAt)")
    }
    static func directory(paths: AppPaths) -> URL {
        paths.root.appendingPathComponent("ImagePreviews", isDirectory: true)
    }
    func url(paths: AppPaths, name: String = "image.png") throws -> URL {
        guard token.count == 64, token.allSatisfy({ $0.isHexDigit }),
            ["image.png", "thumbnail.jpg", "thumbnail.png", "mcp.jpg"].contains(name)
        else { throw ImageDecodeError.invalidData }
        let root = Self.directory(paths: paths).standardizedFileURL
        let url = root.appendingPathComponent(token, isDirectory: true).appendingPathComponent(name).standardizedFileURL
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
            url.path == url.resolvingSymlinksInPath().standardizedFileURL.path
        else { throw ImageDecodeError.invalidData }
        return url
    }
    func objectValue(paths: AppPaths?) -> [String: Any] {
        var value: [String: Any] = [
            "state": state, "width": width, "height": height, "updated_at": updatedAt,
            "preview_kind": "static_image", "mime_type": "image/png",
        ]
        if let errorCode { value["error_code"] = errorCode }
        if state == "ready", let paths, let local = try? url(paths: paths) { value["local_path"] = local.path }
        return value
    }
    func validFile(paths: AppPaths, name: String = "image.png") throws -> URL {
        guard state == "ready" else { throw ImageDecodeError.invalidData }
        let url = try self.url(paths: paths, name: name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize,
            bytes > 0, bytes <= 16 * 1024 * 1024
        else { throw ImageDecodeError.invalidData }
        return url
    }
}
