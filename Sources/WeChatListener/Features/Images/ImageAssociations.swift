import Foundation

enum ImageAssociations {
    static let window: TimeInterval = 30
    static func validScope(_ scope: String) -> Bool { scope.count == 32 && scope.allSatisfy { $0.isHexDigit } }
    static func family(_ name: String) -> String {
        var stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        for suffix in ["_t_M", "_h_M", "_thumb", "_hd", "_t", "_h", "_b", "_w", "_c", "_M"] {
            if stem.hasSuffix(suffix) {
                stem.removeLast(suffix.count)
                break
            }
        }
        return stem
    }
    static func groups(_ items: [ImageAssociation]) -> [ImageAssociationGroup] {
        Dictionary(grouping: items, by: { $0.groupKey }).map { key, values in
            let sorted = values.sorted {
                let a = $0.preview
                let b = $1.preview
                if (a?.state == "ready") != (b?.state == "ready") { return a?.state == "ready" }
                let pixelsA = (a?.width ?? 0) * (a?.height ?? 0)
                let pixelsB = (b?.width ?? 0) * (b?.height ?? 0)
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
    static func familyKey(_ file: DiscoveredFile) -> String {
        (file.relativePath as NSString).deletingLastPathComponent + "|" + family(file.name)
    }
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
