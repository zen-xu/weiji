import CommonCrypto
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import VideoToolbox

struct ImageKey {
    let aes: Data
    let xor: UInt8
}

/// Keys are derived from local cache filenames, tested against the actual image, and never persisted or logged.
enum ImageKeys {
    static func directories(account: URL) -> [URL] {
        let documents = account.deletingLastPathComponent().deletingLastPathComponent()
        let container = documents.deletingLastPathComponent()
        return [
            documents.appendingPathComponent("app_data/net/kvcomm"),
            documents.appendingPathComponent("xwechat/net/kvcomm"),
            container.appendingPathComponent("Library/Application Support/com.tencent.xinWeChat/xwechat/net/kvcomm"),
            container.appendingPathComponent("Library/Application Support/com.tencent.xinWeChat/net/kvcomm"),
        ]
    }
    static func candidates(account: URL) -> [ImageKey] {
        var codes = Set<UInt32>()
        for directory in directories(account: account) {
            guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL,
                let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            else { continue }
            for name in names.prefix(2000) where name.hasPrefix("key_") && name.hasSuffix(".statistic") {
                let parts = name.split(separator: "_")
                if parts.count >= 3, let code = UInt32(parts[1]) { codes.insert(code) }
            }
        }
        let raw = account.lastPathComponent
        let normalized: String
        if raw.lowercased().hasPrefix("wxid_") {
            normalized = raw.split(separator: "_").prefix(2).joined(separator: "_")
        } else {
            normalized = raw.replacingOccurrences(of: "_[a-zA-Z0-9]{4}$", with: "", options: .regularExpression)
        }
        return codes.sorted().flatMap { code in
            Set([raw, normalized]).sorted().map { name in
                let hex = Insecure.MD5.hash(data: Data("\(code)\(name)".utf8)).map { String(format: "%02x", $0) }
                    .joined()
                return ImageKey(aes: Data(hex.prefix(16).utf8), xor: UInt8(code & 255))
            }
        }
    }
}
