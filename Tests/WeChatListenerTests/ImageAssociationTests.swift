import Foundation
import Testing

@testable import WeChatListener

@Test("ImageAssociation")
func imageAssociation() throws {
    let directory = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = TestSupport.referenceDate
    let base = directory.appendingPathComponent("image-association-fixture")
    let account = base.appendingPathComponent("account")
    let fileRoot = account.appendingPathComponent("msg/file")
    let scope = mediaDirectoryID("fixture-images@chatroom")
    let img = account.appendingPathComponent("msg/attach/\(scope)/2026-10/Img")
    for path in [fileRoot, img] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    let bytes = Data([7, 8, 86, 50, 8, 7]) + Data("SYNTHETIC_IMAGE_CONTENT_NOT_FOR_MCP".utf8)
    let original = img.appendingPathComponent("fixtureasset.dat")
    let thumb = img.appendingPathComponent("fixtureasset_t.dat")
    let outsideWindow = img.appendingPathComponent("oldasset.dat")
    for (file, offset) in [(original, 0.125), (thumb, 0.025), (outsideWindow, 30.5)] {
        try bytes.write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: date.addingTimeInterval(offset)], ofItemAtPath: file.path)
    }
    let paths = AppPaths(override: base.appendingPathComponent("archive").path)
    let archive = try Archive(paths: paths)
    let image = NotificationDecoder.make(
        record: 1, title: "合成图片群", subtitle: "成员", body: "[图片] ", chat: "fixture-images@chatroom",
        identity: "image-fixture-id", delivered: date, captured: date)
    try #require(
        image.mediaDirectoryID == scope && scope.count == 32,
        "notification chat metadata derives the image conversation directory without storing raw chat identifiers")
    var legacy = image
    legacy.mediaDirectoryID = nil
    try archive.ingest(legacy)
    let initial = try archive.scanImageAssociations(fileRoot: fileRoot)
    try #require(
        initial.files == 3 && (try archive.imageAssociations(for: legacy)).isEmpty,
        "old notifications without conversation directory evidence are not matched across unrelated folders")
    let sourcePath = base.appendingPathComponent("source.sqlite")
    let sourceDB = try SQLite(sourcePath.path)
    try sourceDB.run("CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT)")
    try sourceDB.run(
        "CREATE TABLE record(rec_id INTEGER PRIMARY KEY,app_id INTEGER,uuid BLOB,delivered_date REAL,data BLOB)")
    try sourceDB.run("INSERT INTO app VALUES(1,'com.tencent.xinWeChat')")
    let info = try NSKeyedArchiver.archivedData(
        withRootObject: ["chatname": "fixture-images@chatroom", "unique_id": "image-fixture-id"],
        requiringSecureCoding: true)
    let blob = try PropertyListSerialization.data(
        fromPropertyList: ["req": ["titl": "合成图片群", "subt": "成员", "body": "[图片] ", "usda": info]], format: .binary,
        options: 0)
    let historicalBlob = try PropertyListSerialization.data(
        fromPropertyList: ["req": ["titl": "历史合成通知", "body": "过去保留的通知"]], format: .binary, options: 0)
    try sourceDB.run(
        "INSERT INTO record VALUES(1,1,?,?,?)",
        [.blob(Data([1])), .real(date.timeIntervalSinceReferenceDate), .blob(blob)])
    try sourceDB.run(
        "INSERT INTO record VALUES(2,1,?,?,?)",
        [.blob(Data([2])), .real(date.addingTimeInterval(-7200).timeIntervalSinceReferenceDate), .blob(historicalBlob)])
    let source = try NotificationSource(url: sourcePath)
    let backfill = try source.capture(to: archive)
    let saved = try archive.messages(MessageFilter(conversation: image.conversationID)).first!
    try #require(
        backfill.inserted == 1 && backfill.updated == 1 && saved.mediaDirectoryID == scope,
        "startup-style backfill imports retained history and enriches previously archived image metadata")
    try #require(
        saved.id == legacy.id && saved.body == legacy.body && saved.capturedAt == legacy.capturedAt
            && saved.updatedAt == legacy.updatedAt,
        "directory metadata enrichment preserves message identity, original text and timestamps")
    let repeated = try source.capture(to: archive)
    try #require(
        repeated.inserted == 0 && repeated.updated == 0 && (try archive.count()) == 2,
        "repeated historical backfills deduplicate without fabricating cleared history")
    try #require(
        try archive.messages().contains(where: { $0.date == date.addingTimeInterval(-7200) }),
        "retained notifications older than app startup are included in backfill")
    let scan = try archive.scanImageAssociations(fileRoot: fileRoot)
    let links = try archive.imageAssociations(for: saved)
    try #require(
        scan.complete && scan.files == 3 && links.count == 2,
        "image associations require matching conversation directory and a bounded timestamp window")
    try #require(
        links.allSatisfy { $0.format == "wechat_v2_dat" && $0.family == "fixtureasset" },
        "original and thumbnail variants preserve file-family and format evidence")
    try #require(
        abs(links[0].secondsFromNotification - 0.025) < 0.002 && abs(links[1].secondsFromNotification - 0.125) < 0.002,
        "association evidence retains signed subsecond time differences")
    let objects = try archive.messageObjects([saved])
    let associations = objects[0]["image_associations"] as! [[String: Any]]
    try #require(
        associations.allSatisfy {
            $0["confidence"] == nil && $0["assessment_by"] as? String == "ai_client"
                && $0["association_basis"] as? String == "conversation_directory_and_timestamp"
        }, "application provides association evidence without assigning AI credibility scores")
    try #require(
        !String(decoding: JSONSerialization.data(withJSONObject: objects), as: UTF8.self).contains(
            "SYNTHETIC_IMAGE_CONTENT_NOT_FOR_MCP"), "image associations return no encrypted image bytes or keys")
    let nearby = NotificationDecoder.make(
        record: 3, title: "合成图片群", subtitle: "另一成员", body: "[图片]", chat: "fixture-images@chatroom",
        identity: "nearby-image", delivered: date.addingTimeInterval(1), captured: date)
    try archive.ingest(nearby)
    try #require(
        try archive.imageAssociations(for: saved).allSatisfy { $0.nearbyNotificationIDs.contains(nearby.id) },
        "nearby image-message identifiers are supplied for AI ambiguity assessment")
    let other = NotificationDecoder.make(
        record: 4, title: "同名群", subtitle: "成员", body: "[图片]", chat: "other-images@chatroom", identity: "other-image",
        delivered: date, captured: date)
    try archive.ingest(other)
    let otherFolder = account.appendingPathComponent("msg/attach/\(other.mediaDirectoryID!)/2026-10/Img")
    try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
    let otherFile = otherFolder.appendingPathComponent("otherasset.dat")
    try bytes.write(to: otherFile)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: otherFile.path)
    _ = try archive.scanImageAssociations(fileRoot: fileRoot)
    try #require(
        try archive.imageAssociations(for: saved).count == 2 && archive.imageAssociations(for: other).count == 1,
        "same-time images from different conversation directories remain isolated")
    try FileManager.default.setAttributes(
        [.modificationDate: date.addingTimeInterval(30)], ofItemAtPath: outsideWindow.path)
    _ = try archive.scanImageAssociations(fileRoot: fileRoot)
    try #require(
        try archive.imageAssociations(for: saved).count == 3, "association time-window boundaries are inclusive")
    let partial = try archive.scanImageAssociations(fileRoot: fileRoot, entryLimit: 1)
    try #require(
        !partial.complete && (try archive.imageAssociations(for: saved)).count == 3,
        "partial image scans do not erase associations for unvisited files")
    var untimed = saved
    untimed.deliveredAt = nil
    try #require(
        try archive.imageAssociations(for: untimed).isEmpty,
        "capture time is not substituted for a missing notification delivery time")
    var unsafe = image
    unsafe.mediaDirectoryID = "../../outside"
    var rejected = false
    do { _ = try archive.ingest(unsafe) } catch { rejected = true }
    try #require(rejected, "imported conversation directory identifiers cannot escape the selected account")
    rejected = false
    do { _ = try Archive(paths: paths, readOnly: true).scanImageAssociations(fileRoot: fileRoot) } catch {
        rejected = true
    }
    try #require(rejected, "MCP cannot trigger image directory scans")
    let late = img.appendingPathComponent("fixtureasset_h.dat")
    try bytes.write(to: late)
    try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(300)], ofItemAtPath: late.path)
    let differentMonth = account.appendingPathComponent("msg/attach/\(scope)/2026-09/Img")
    try FileManager.default.createDirectory(at: differentMonth, withIntermediateDirectories: true)
    let unrelated = img.appendingPathComponent("unrelatedlate.dat")
    let wrongMonth = differentMonth.appendingPathComponent("fixtureasset_h.dat")
    let wrongRoom = otherFolder.appendingPathComponent("fixtureasset_h.dat")
    for path in [unrelated, wrongMonth, wrongRoom] {
        try bytes.write(to: path)
        try FileManager.default.setAttributes(
            [.modificationDate: date.addingTimeInterval(300)], ofItemAtPath: path.path)
    }
    _ = try archive.scanImageAssociations(fileRoot: fileRoot)
    let expanded = try archive.imageAssociations(for: saved)
    let lateLink = expanded.first { $0.file.name == "fixtureasset_h.dat" }!
    try #require(
        expanded.count == 4 && !lateLink.matchesTimeWindow && abs(lateLink.secondsFromNotification - 300) < 0.002,
        "a later-downloaded image variant is linked through its timestamp-matched asset family")
    let lateEvidence = try lateLink.objectValue()
    try #require(
        lateEvidence["association_basis"] as? String == "same_asset_family_as_timestamp_candidate"
            && (lateEvidence["anchor_file_ids"] as? [String])?.count == 2,
        "late variant evidence identifies the timestamp anchors instead of claiming a direct time match")
    try #require(
        !expanded.contains { $0.file.name == "unrelatedlate.dat" || $0.file.relativePath.contains("2026-09") }
            && (try archive.imageAssociations(for: other)).count == 1,
        "asset expansion never crosses image folders, months, conversation directories or unrelated names")
    let groups = ImageAssociations.groups(expanded)
    try #require(
        groups.count == 2 && groups.first(where: { $0.preferred.family == "fixtureasset" })?.versions.count == 3,
        "thumbnail and larger variants form one card without merging different asset families")
    var large = lateLink
    var tiny = expanded.first { $0.isThumbnail }!
    large.preview = ImagePreview(
        fileID: large.id, stamp: "fixture", token: digest("large"), state: "ready", width: 3000, height: 4000)
    tiny.preview = ImagePreview(
        fileID: tiny.id, stamp: "fixture", token: digest("tiny"), state: "ready", width: 300, height: 400)
    try #require(
        ImageAssociations.groups([tiny, large])[0].preferred.id == large.id,
        "preferred preview uses decoded pixel dimensions rather than nearest download time")
    large.preview = nil
    try #require(
        ImageAssociations.groups([large, tiny])[0].preferred.id == tiny.id,
        "an unavailable larger variant falls back to a decoded thumbnail")
    try FileManager.default.removeItem(at: late)
    _ = try archive.scanImageAssociations(fileRoot: fileRoot)
    try #require(
        !(try archive.imageAssociations(for: saved)).contains(where: { $0.file.name == "fixtureasset_h.dat" }),
        "deleted larger variants are removed after a complete scan")
    let sourceBytes = try Data(contentsOf: original)
    try archive.clear()
    try #require(
        try Data(contentsOf: original) == sourceBytes && source.snapshot().count == 2,
        "clearing associations leaves original image files and source notifications unchanged")
    let oldPaths = AppPaths(override: base.appendingPathComponent("old-schema").path)
    let old = try Archive(paths: oldPaths)
    try old.database.run("DROP TABLE image_files")
    try #require(
        try Archive(paths: oldPaths, readOnly: true).imageAssociations(for: image).isEmpty,
        "old archives remain queryable before image-association schema upgrade")
}
