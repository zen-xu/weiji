import Foundation

enum FileDiscovery {
    static let excludedExtensions: Set<String> = [
        "dat", "db", "sqlite", "sqlite3", "tmp", "part", "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp",
        "tiff", "ico",
    ]
    static func directory(_ selected: URL) throws -> URL {
        let selected = selected.resolvingSymlinksInPath().standardizedFileURL
        let result: URL
        if selected.lastPathComponent == "file", selected.deletingLastPathComponent().lastPathComponent == "msg" {
            result = selected
        } else {
            result = selected.appendingPathComponent("msg/file", isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: result.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw ListenerError("未找到 msg/file。请选择微信账号目录或它下面的 msg/file 文件夹。")
        }
        // Do not traverse an account's database, image or cache directories.
        return result.resolvingSymlinksInPath().standardizedFileURL
    }
}
