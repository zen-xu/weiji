import CommonCrypto
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import WeChatListener

@Test("ImagePreview")
func imagePreview() throws {
    let directory = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = TestSupport.referenceDate
    func rejects(_ action: () throws -> Void) -> Bool {
        do {
            try action()
            return false
        } catch { return true }
    }
    func hex(_ value: String) -> Data {
        var bytes = [UInt8]()
        var i = value.startIndex
        while i < value.endIndex {
            let end = value.index(i, offsetBy: 2)
            bytes.append(UInt8(value[i..<end], radix: 16)!)
            i = end
        }
        return Data(bytes)
    }
    let nonexistent = AppPaths(override: directory.appendingPathComponent("space dir/uncreated").path)
    let pending = ImagePreview(
        fileID: digest("path-test"), stamp: digest("stamp"), token: digest("token"), state: "pending")
    try #require(
        try pending.url(paths: nonexistent).path.hasSuffix("image.png"),
        "preview paths with spaces work before the cache directory exists")
    let aesKey = hex("2b7e151628aed2a6abf7158809cf4f3c")
    try #require(
        try ImageDecoder.crypt(hex("3ad77bb40d7a3660a89ecaf32466ef97"), key: aesKey, padded: false)
            == hex("6bc1bee22e409f96e93d7e117393172a"), "AES matches NIST ECB known-answer vector")
    let root = directory.appendingPathComponent("preview-fixture")
    let account = root.appendingPathComponent("Documents/xwechat_files/fixture-peer_abcd")
    let cache = root.appendingPathComponent("Documents/app_data/net/kvcomm")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data().write(to: cache.appendingPathComponent("key_12345_fixture.statistic"))
    let keys = ImageKeys.candidates(account: account)
    let key = keys.first!
    try #require(
        keys.count == 2 && keys.allSatisfy { $0.xor == UInt8(12345 & 255) },
        "image keys derive from selected account cache filenames without process or database access")
    let out = root.appendingPathComponent("synthetic.jpg")
    let context = CGContext(
        data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
    try ImagePreviewWriter.write(context.makeImage()!, to: out, type: "public.jpeg")
    let jpeg = try Data(contentsOf: out)
    var dat = Data([7, 8, 86, 50, 8, 7])
    for n: UInt32 in [64, 32] {
        var little = n.littleEndian
        withUnsafeBytes(of: &little) { dat.append(contentsOf: $0) }
    }
    dat.append(1)
    dat.append(try ImageDecoder.crypt(Data(jpeg.prefix(64)), key: key.aes, operation: CCOperation(kCCEncrypt)))
    dat.append(jpeg.subdata(in: 64..<(jpeg.count - 32)))
    dat.append(contentsOf: jpeg.suffix(32).map { $0 ^ key.xor })
    let restored = try ImageDecoder.payload(dat, keys: keys)
    try #require(
        restored.0 == jpeg && restored.1 == "v2_aes_xor",
        "V2 AES/raw/XOR reconstruction returns exact original synthetic image bytes")
    try #require(
        rejects { _ = try ImageDecoder.payload(dat, keys: []) },
        "missing V2 key is reported without fabricating a preview")
    var broken = dat
    broken[94] ^= 0xff
    try #require(rejects { _ = try ImageDecoder.payload(broken, keys: keys) }, "invalid PKCS7 padding is rejected")
    let xor = Data(jpeg.map { $0 ^ 0x87 })
    try #require(try ImageDecoder.payload(xor, keys: []).0 == jpeg, "legacy XOR DAT is decoded without external tools")
    let raster = try ImageDecoder.image(restored.0)
    try #require(raster.width == 60 && raster.height == 40, "ImageIO verifies and decodes the complete restored image")
    try #require(
        rejects { _ = try ImageDecoder.image(Data([255, 216, 255, 0])) },
        "invalid image contents are rejected after signature detection")
    var invalid = Data(repeating: 0xff, count: 31)
    invalid.replaceSubrange(0..<6, with: [7, 8, 86, 50, 8, 7])
    try #require(
        rejects { _ = try ImageDecoder.payload(invalid, keys: keys) },
        "malformed DAT segment lengths cannot overrun the input")
    let chat = "fixture-preview@chatroom"
    let scope = mediaDirectoryID(chat)
    let files = account.appendingPathComponent("msg/file")
    let img = account.appendingPathComponent("msg/attach/\(scope)/2026-10/Img")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: img, withIntermediateDirectories: true)
    let source = img.appendingPathComponent("fixture.dat")
    try dat.write(to: source)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
    let paths = AppPaths(override: root.appendingPathComponent("archive").path)
    let archive = try Archive(paths: paths)
    let message = NotificationDecoder.make(
        record: 10, title: "fixture-group", subtitle: "fixture-sender", body: "[图片]", chat: chat, delivered: date,
        captured: date)
    try archive.ingest(message)
    try archive.scanFiles(in: account)
    try archive.scanImageAssociations(fileRoot: files)
    let prepared = try archive.prepareImagePreviews()
    let association = try archive.imageAssociations(for: message).first!
    let preview = association.preview!
    try #require(
        prepared["ready"] == 1 && preview.state == "ready" && preview.width == 60 && preview.height == 40,
        "associated DAT gains a verified local preview through the archive scan pipeline")
    let imageURL = try preview.validFile(paths: paths)
    let thumb = try preview.validFile(paths: paths, name: "thumbnail.png")
    let permissions = (try FileManager.default.attributesOfItem(atPath: imageURL.path)[.posixPermissions] as! NSNumber)
        .intValue
    try #require(
        permissions == 0o600 && FileManager.default.fileExists(atPath: thumb.path),
        "image previews and thumbnails are stored with owner-only permissions")
    let ro = try Archive(paths: paths, readOnly: true)
    let fetched = try ro.cachedImage(messageID: message.id, fileID: association.id)
    try #require(
        fetched.0.starts(with: [255, 216, 255]) && fetched.0.count <= 2 * 1024 * 1024,
        "read-only MCP retrieves a bounded JPEG from the local preview cache")
    try #require(
        rejects { _ = try ro.cachedImage(messageID: digest("other-message"), fileID: association.id) }
            && rejects { _ = try ro.cachedImage(messageID: message.id, fileID: digest("other-file")) },
        "image access requires a file associated with the requested message")
    try #require(rejects { _ = try ro.prepareImagePreviews() }, "read-only MCP cannot decrypt or populate image caches")
    let mcp = MCPServer(paths: paths)
    _ = mcp.response(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
    let rpc =
        mcp.response([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": [
                "name": "wechat_get_image", "arguments": ["message_id": message.id, "file_id": association.id],
            ],
        ])!["result"] as! [String: Any]
    let content = rpc["content"] as! [[String: Any]]
    try #require(
        content.count == 2 && content[1]["type"] as? String == "image"
            && content[1]["mimeType"] as? String == "image/jpeg",
        "MCP returns actual image content for AI visual inspection")
    let search = try archive.messageObjects([message])
    let associations = search[0]["image_associations"] as! [[String: Any]]
    try #require(
        associations[0]["content_returned"] as? Bool == false && associations[0]["preview"] != nil
            && associations[0]["confidence"] == nil,
        "message search includes preview metadata without inline image bytes or confidence scores")
    try FileManager.default.removeItem(at: thumb)
    try FileManager.default.createSymbolicLink(at: thumb, withDestinationURL: out)
    try #require(
        rejects { _ = try preview.validFile(paths: paths, name: "thumbnail.png") },
        "cache symlinks cannot expose arbitrary files")
    try FileManager.default.removeItem(at: thumb)
    _ = try archive.prepareImagePreviews()
    let cachedTime = try imageURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    _ = try archive.prepareImagePreviews()
    try #require(
        try imageURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == cachedTime,
        "unchanged image caches are reused without redundant decoding")
    try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(0.25)], ofItemAtPath: source.path)
    try archive.scanImageAssociations(fileRoot: files)
    try #require(
        try archive.imageAssociations(for: message).first?.preview == nil,
        "source timestamp changes invalidate stale cached previews")
    try archive.clear()
    let sourceAfterClear = try Data(contentsOf: source)
    try #require(
        !FileManager.default.fileExists(atPath: ImagePreview.directory(paths: paths).path)
            && sourceAfterClear == dat,
        "clearing the archive removes decoded caches and leaves original DAT untouched")
    try #require(
        try WXGFDecoder.units(Data("wxgf".utf8) + Data([0, 0, 0, 1, 64, 1, 12, 0, 0, 0, 1, 66, 1, 99])).count == 2,
        "WXGF Annex-B splitter recognizes distinct parameter sets")
    try #require(
        rejects { _ = try WXGFDecoder.decode(Data("wxgf-invalid".utf8)) },
        "malformed WXGF fails cleanly rather than creating a blank preview")
    func syntheticSPS(chroma: String) -> Data {
        var bits = "00000001" + String(repeating: "0", count: 96) + "1" + chroma
        while bits.count % 8 != 0 { bits += "0" }
        var bytes = [UInt8](arrayLiteral: 66, 1)
        for offset in stride(from: 0, to: bits.count, by: 8) {
            let begin = bits.index(bits.startIndex, offsetBy: offset)
            let end = bits.index(begin, offsetBy: 8)
            bytes.append(UInt8(bits[begin..<end], radix: 2)!)
        }
        return Data(bytes)
    }
    try #require(
        WXGFDecoder.chromaFormat(syntheticSPS(chroma: "1")) == 0
            && WXGFDecoder.chromaFormat(syntheticSPS(chroma: "010")) == 1,
        "HEVC SPS distinguishes grayscale mask streams from color image streams")
    let smallFit = ImagePreviewSizing.size(
        width: 300, height: 400, displayScale: 2, available: CGSize(width: 800, height: 600), fit: true, zoom: 1)
    try #require(
        smallFit == CGSize(width: 150, height: 200),
        "fit-to-window does not enlarge a low-resolution thumbnail beyond its physical pixels")
    let native = ImagePreviewSizing.size(
        width: 2400, height: 3200, displayScale: 2, available: CGSize(width: 800, height: 600), fit: false, zoom: 1)
    try #require(
        native == CGSize(width: 1200, height: 1600),
        "100 percent zoom maps source pixels to screen pixels on Retina displays")
    let fitted = ImagePreviewSizing.size(
        width: 2400, height: 3200, displayScale: 2, available: CGSize(width: 800, height: 600), fit: true, zoom: 1)
    try #require(
        fitted == CGSize(width: 450, height: 600),
        "large previews fit the viewport without changing the cached source resolution")
    let sharp = root.appendingPathComponent("lossless-thumbnail.png")
    try ImagePreviewWriter.write(context.makeImage()!, to: sharp, type: "public.png", maximum: 1024)
    try #require(
        try Data(contentsOf: sharp).starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
        "list previews use lossless PNG instead of an extra JPEG compression pass")
}
