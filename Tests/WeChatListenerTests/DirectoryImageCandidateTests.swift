import Foundation
import Testing

@testable import WeChatListener

@Test("DirectoryImageCandidate")
func directoryImageCandidate() throws {
    let directory = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let date = TestSupport.referenceDate
    let root = directory.appendingPathComponent("directory-image-candidates")
    let account = root.appendingPathComponent("dynamic-account")
    let files = account.appendingPathComponent("msg/file")
    let chat = "fixture-directory-peer"
    let scope = mediaDirectoryID(chat)
    let img = account.appendingPathComponent("msg/attach/\(scope)/2026-10/Img")
    for path in [files, img] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    let payload = Data([7, 8, 86, 50, 8, 7]) + Data("synthetic-only".utf8)
    for (name, delta) in [
        ("newasset_t.dat", 0.6), ("newasset.dat", 2.7), ("newasset_h.dat", 120.0), ("unrelated.dat", 120.0),
    ] {
        let path = img.appendingPathComponent(name)
        try payload.write(to: path)
        try FileManager.default.setAttributes(
            [.modificationDate: date.addingTimeInterval(delta)], ofItemAtPath: path.path)
    }
    let paths = AppPaths(override: root.appendingPathComponent("archive").path)
    let archive = try Archive(paths: paths)
    let text = NotificationDecoder.make(
        record: 1, title: "fixture-peer", subtitle: "", body: "合成发布文字", chat: chat, identity: "text-anchor",
        delivered: date, captured: date)
    try archive.ingest(text)
    let scan = try archive.scanImageAssociations(fileRoot: files)
    let candidates = try archive.imageAssociations(for: text)
    try #require(
        scan.files == 4 && candidates.count == 3 && scan.messages == 0 && scan.anchorNotifications == 1,
        "local images are discovered near a text notification even when no image notification was retained")
    try #require(
        candidates.allSatisfy { !$0.imageNotificationCaptured },
        "directory image observations are explicitly distinguished from captured image notifications")
    try #require(
        try archive.count() == 1 && archive.messages()[0].body == text.body
            && !archive.messages()[0].isImageNotification,
        "directory discovery never fabricates a chat message or alters notification text")
    let objects = try archive.messageObjects([text])
    let associations = objects[0]["image_associations"] as! [[String: Any]]
    try #require(
        associations.allSatisfy {
            $0["notification_anchor_kind"] as? String == "nearby_conversation_notification"
                && $0["message_link_verified"] as? Bool == false && $0["sender_verified"] as? Bool == false
                && $0["image_message_direction"] as? String == "unknown_from_directory"
        }, "fallback evidence does not claim the text sender or message direction as verified image ownership")
    let larger = associations.first { ($0["name"] as? String)?.hasSuffix("_h.dat") == true }!
    try #require(
        larger["within_time_window"] as? Bool == false
            && larger["association_basis"] as? String == "same_asset_family_as_timestamp_candidate",
        "later-downloaded versions inherit a directory candidate with explicit indirect evidence")
    try #require(
        !candidates.contains { $0.file.name == "unrelated.dat" },
        "a neighboring text does not capture unrelated image files outside the time window")
    let earlier = NotificationDecoder.make(
        record: 2, title: "fixture-peer", subtitle: "", body: "更早的文字", chat: chat, identity: "earlier-text",
        delivered: date.addingTimeInterval(-10), captured: date)
    try archive.ingest(earlier)
    try #require(
        try archive.imageAssociations(for: earlier).isEmpty && archive.imageAssociations(for: text).count == 3,
        "directory candidates are assigned to the nearest known conversation notification instead of every nearby text")
    let closer = NotificationDecoder.make(
        record: 3, title: "fixture-peer", subtitle: "", body: "更近的文字", chat: chat, identity: "closer-text",
        delivered: date.addingTimeInterval(0.5), captured: date)
    try archive.ingest(closer)
    try #require(
        try archive.imageAssociations(for: closer).count == 3 && archive.imageAssociations(for: text).isEmpty,
        "nearest candidate selection is deterministic when several text notifications exist")
    let image = NotificationDecoder.make(
        record: 4, title: "fixture-peer", subtitle: "", body: "[图片]", chat: chat, identity: "explicit-image",
        delivered: date.addingTimeInterval(1), captured: date)
    try archive.ingest(image)
    try #require(
        try archive.imageAssociations(for: closer).isEmpty
            && archive.imageAssociations(for: image).allSatisfy { $0.imageNotificationCaptured },
        "an explicit image notification takes precedence over a nearby text fallback")
    let other = NotificationDecoder.make(
        record: 5, title: "fixture-other", subtitle: "", body: "其他会话", chat: "other-peer", identity: "other-text",
        delivered: date, captured: date)
    try archive.ingest(other)
    try #require(
        try archive.imageAssociations(for: other).isEmpty,
        "text fallback observations never cross conversation directories")
    var noTime = text
    noTime.deliveredAt = nil
    try #require(
        try archive.imageAssociations(for: noTime).isEmpty,
        "fallback requires an actual delivery timestamp rather than capture time")
    let countBefore = try archive.count()
    _ = try archive.scanImageAssociations(fileRoot: files)
    try #require(try archive.count() == countBefore, "repeated directory scans leave notification counts unchanged")
}
