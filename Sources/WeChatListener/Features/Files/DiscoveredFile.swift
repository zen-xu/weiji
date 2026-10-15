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
        case relativePath = "relative_path"
        case modifiedAt = "modified_at"
    }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    func url() throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0"),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw ListenerError("文件索引路径无效。") }
        let directory = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let file = directory.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(directory.path + "/") else { throw ListenerError("文件已移出探测目录。") }
        return file
    }
    func objectValue() throws -> [String: Any] {
        [
            "id": id, "name": name, "bytes": bytes, "modified_at": modifiedAt,
            "local_path": try url().path, "available_at_last_scan": available, "source": "wechat_file_directory",
        ]
    }
}
