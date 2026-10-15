import Foundation
import ImageIO

func runPerformanceRegressionTests(directory: URL, date: Date) throws -> Int {
    var passed = 0
    func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw ListenerError("FAIL: \(label)") }
        passed += 1; print("PASS: \(label)")
    }
    try check(digest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" &&
        mediaDirectoryID("abc") == "900150983cd24fb0d6963f7d28e17f72", "faster hex conversion preserves existing message, file and conversation identities")
    let lock = NSLock()
    var failures = 0
    DispatchQueue.concurrentPerform(iterations: 128) { index in
        let value = date.addingTimeInterval(Double(index))
        let valid = Dates.parse(Dates.string(value)) == value && Dates.parse("2026-10-15T09:00:00+08:00") == date
        if !valid { lock.lock(); failures += 1; lock.unlock() }
    }
    try check(failures == 0, "date formatter reuse preserves fractional and timezone parsing across concurrent workers")

    let root = directory.appendingPathComponent("performance-regression")
    let files = root.appendingPathComponent("account/msg/file")
    let scope = mediaDirectoryID("synthetic-performance-peer")
    let img = root.appendingPathComponent("account/msg/attach/\(scope)/2026-10/Img")
    for path in [files, img] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    let image = img.appendingPathComponent("asset.dat"), doc = files.appendingPathComponent("fixture.pdf")
    try Data([7, 8, 86, 50, 8, 7]).write(to: image)
    try Data("synthetic-document".utf8).write(to: doc)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: image.path)
    let archive = try Archive(paths: AppPaths(override: root.appendingPathComponent("archive").path))
    _ = try archive.scanFiles(in: files); _ = try archive.scanImageAssociations(fileRoot: files)
    func changes() throws -> Int64 { try archive.database.rows("SELECT total_changes() AS n").first!.int("n")! }
    let before = try changes()
    _ = try archive.scanFiles(in: files); _ = try archive.scanImageAssociations(fileRoot: files)
    try check(try changes() - before == 4, "an unchanged rescan writes only four metadata rows and does not rewrite file catalogs")
    let beforeChange = try changes()
    try Data([137, 80, 78, 71, 13, 10]).write(to: image)
    try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(2)], ofItemAtPath: image.path)
    _ = try archive.scanImageAssociations(fileRoot: files)
    try check(try changes() - beforeChange == 3 && archive.database.rows("SELECT format FROM image_files").first?.string("format") == "png",
        "a changed file is re-probed and only its own catalog row is updated")
    try archive.database.run("UPDATE image_files SET format='unreadable'")
    _ = try archive.scanImageAssociations(fileRoot: files)
    try check(try archive.database.rows("SELECT format FROM image_files").first?.string("format") == "png", "previously unreadable headers are retried even when metadata is unchanged")
    let content = try Data(contentsOf: image)
    let attributes = try image.resourceValues(forKeys: [.contentModificationDateKey])
    try FileManager.default.removeItem(at: image); try FileManager.default.removeItem(at: doc)
    _ = try archive.scanFiles(in: files); _ = try archive.scanImageAssociations(fileRoot: files)
    try check(try archive.discoveredFileCount() == 0 && archive.directoryImageGroupCount() == 0, "differential scans still remove missing image and document records")
    try content.write(to: image); try Data("synthetic-document".utf8).write(to: doc)
    try FileManager.default.setAttributes([.modificationDate: attributes.contentModificationDate!], ofItemAtPath: image.path)
    _ = try archive.scanFiles(in: files); _ = try archive.scanImageAssociations(fileRoot: files)
    try check(try archive.discoveredFileCount() == 1 && archive.directoryImageGroupCount() == 1, "files that reappear with identical metadata become available again")

    // Add enough catalog rows to exercise pagination and variant limits without decoding many images.
    let account = files.deletingLastPathComponent().deletingLastPathComponent().path
    let timestamp = Dates.string(date)
    try archive.database.transaction {
        for index in 0..<65 {
            try archive.database.run("INSERT INTO image_files VALUES(?,?,?,?,?,?,?,?,?,?,1)",
                [.text("extra-\(index)"), .text(account), .text(scope), .text("msg/attach/\(scope)/2026-10/Img/extra-\(index).dat"),
                 .text("extra-\(index).dat"), .integer(6), .text(timestamp), .text("wechat_dat"), .text("extra-\(index)"), .text("fixture")])
        }
        for index in 0..<105 {
            try archive.database.run("INSERT INTO image_files VALUES(?,?,?,?,?,?,?,?,?,?,1)",
                [.text("variant-\(index)"), .text(account), .text(scope), .text("msg/attach/\(scope)/2026-10/Img/bounded-\(index).dat"),
                 .text("bounded-\(index).dat"), .integer(6), .text(timestamp), .text("wechat_dat"), .text("bounded"), .text("fixture")])
        }
    }
    let first = try archive.directoryImageGroups(), second = try archive.directoryImageGroups(offset: 60)
    try check(first.count == 60 && second.count == 7 && Set(first.map { $0.id }).isDisjoint(with: second.map { $0.id }),
        "batched gallery queries keep deterministic page boundaries for equal timestamps")
    try check(try archive.directoryImageGroups(query: "bounded-1").first?.versions.count == 100,
        "filename filtering selects whole image families and retains the 100-variant limit")
    try archive.database.run("DROP TABLE image_previews")
    let old = try Archive(paths: archive.paths, readOnly: true)
    try check(try old.directoryImageGroups().count == 60, "gallery reads remain compatible with older archives lacking preview storage")

    let preview = ImagePreview(fileID: "display", stamp: "display", token: digest("display-fixture"), state: "ready", width: 8, height: 6)
    let url = try preview.url(paths: archive.paths, name: "thumbnail.png")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    try ImagePreviewWriter.write(context.makeImage()!, to: url, type: "public.png")
    final class ImageBox: @unchecked Sendable { var image: CGImage? }
    func load() throws -> CGImage? {
        let done = DispatchSemaphore(value: 0), box = ImageBox()
        Task.detached {
            box.image = await PreviewImageLoader.load(preview, paths: archive.paths, name: "thumbnail.png")
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else { throw ListenerError("Preview display worker timed out") }
        return box.image
    }
    try check(try load()?.width == 8 && load()?.height == 6, "background preview loading decodes cached images and supports repeat reads")
    try FileManager.default.removeItem(at: url)
    try check(try load() == nil, "in-memory display cache does not bypass missing-file validation")
    return passed
}
