import Foundation
import ImageIO
import Testing

@testable import WeChatListener

@Test("DirectoryImageGallery")
func directoryImageGallery() throws {
    let directory = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = TestSupport.referenceDate
    let root = directory.appendingPathComponent("independent-image-gallery")
    let account = root.appendingPathComponent("arbitrary-account")
    let files = account.appendingPathComponent("msg/file")
    let img = account.appendingPathComponent("msg/attach/\(mediaDirectoryID("unseen-peer"))/2026-10/Img")
    for path in [files, img] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    func image(_ path: URL, width: Int, height: Int) throws {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try ImagePreviewWriter.write(ctx.makeImage()!, to: path, type: "public.png")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
    }
    let original = img.appendingPathComponent("independent.dat")
    let thumb = img.appendingPathComponent("independent_t.dat")
    let other = img.appendingPathComponent("another.dat")
    try image(original, width: 64, height: 48)
    try image(thumb, width: 8, height: 6)
    try image(other, width: 32, height: 24)
    let paths = AppPaths(override: root.appendingPathComponent("archive").path)
    let archive = try Archive(paths: paths)
    let scanned = try archive.scanImageAssociations(fileRoot: files)
    try #require(
        scanned.files == 3 && scanned.messages == 0 && (try archive.count()) == 0,
        "image directory discovery works with zero notification records and does not create chat messages")
    try #require(
        try archive.directoryImageGroupCount() == 2,
        "independent gallery groups file variants while keeping distinct image assets separate")
    let prepared = try archive.prepareImagePreviews()
    try #require(
        prepared["ready"] == 3 && prepared["unavailable"] == 0,
        "images without notification anchors are decoded and cached automatically")
    let gallery = try archive.directoryImageGroups(query: "independent")
    try #require(
        gallery.count == 1 && gallery[0].versions.count == 2 && gallery[0].preferred.preview?.width == 64,
        "directory gallery selects the largest decoded version without needing a message identity")
    try #require(
        try archive.directoryImageGroupCount(query: "another") == 1 && archive.directoryImageGroups(offset: 60).isEmpty,
        "directory gallery supports filename filtering and bounded pagination")
    let readOnly = try Archive(paths: paths, readOnly: true)
    try #require(
        try readOnly.directoryImageGroups().count == 2 && readOnly.count() == 0,
        "independent image records remain separate from the read-only notification archive")
    let result = try archive.prepareImagePreviews(fileIDs: [digest("nonexistent-file")])
    try #require(
        result["ready"] == 0, "on-demand preview generation accepts catalog IDs and cannot select arbitrary paths")
    try FileManager.default.removeItem(at: original)
    _ = try archive.scanImageAssociations(fileRoot: files)
    try #require(
        try archive.directoryImageGroups(query: "independent")[0].preferred.preview?.width == 8,
        "gallery falls back to the remaining thumbnail after a larger file is removed")
    try #require(
        DirectoryMonitor.isMediaPath("/fixture/msg/attach/hash/2026/Img/a.dat", root: "/fixture/msg")
            && DirectoryMonitor.isMediaPath("/fixture/msg/file/report.pdf", root: "/fixture/msg"),
        "recursive directory watcher accepts file and image changes below the selected account")
    try #require(
        !DirectoryMonitor.isMediaPath("/fixture/db_storage/message.db", root: "/fixture/msg")
            && !DirectoryMonitor.isMediaPath("/fixture/msg/attachment-other/a", root: "/fixture/msg"),
        "directory watcher excludes database paths and unrelated sibling names")
    let bytes = try Data(contentsOf: thumb)
    try archive.clear()
    try #require(
        try Data(contentsOf: thumb) == bytes && archive.directoryImageGroupCount() == 0,
        "clearing the independent image index leaves WeChat source files intact")
}
