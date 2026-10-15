import Foundation

struct ImageAssociation: Identifiable {
    let file: DiscoveredFile
    let scope: String
    let format: String
    let family: String
    let secondsFromNotification: Double
    let nearbyNotificationIDs: [String]
    var preview: ImagePreview? = nil
    var anchorFileIDs: [String] = []
    var imageNotificationCaptured = true
    var matchesTimeWindow: Bool { abs(secondsFromNotification) <= ImageAssociations.window }
    var groupKey: String {
        file.root + "|" + scope + "|" + (file.relativePath as NSString).deletingLastPathComponent + "|" + family
    }
    var isThumbnail: Bool {
        ["_t", "_t_M", "_thumb"].contains {
            URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent.hasSuffix($0)
        }
    }
    var id: String { file.id }
    var formatLabel: String {
        switch format {
        case "wechat_v2_dat", "wechat_dat": return "微信图片文件（DAT）"
        case "jpeg": return "JPEG"
        case "png": return "PNG"
        case "gif": return "GIF"
        case "unreadable": return "未读取文件格式"
        default: return "图片文件"
        }
    }
    func objectValue(paths: AppPaths? = nil) throws -> [String: Any] {
        var value = try file.objectValue()
        value["source"] = "wechat_image_directory"
        value["association_basis"] =
            matchesTimeWindow ? "conversation_directory_and_timestamp" : "same_asset_family_as_timestamp_candidate"
        value["within_time_window"] = matchesTimeWindow
        value["image_notification_captured"] = imageNotificationCaptured
        value["notification_anchor_kind"] =
            imageNotificationCaptured ? "image_notification" : "nearby_conversation_notification"
        value["message_link_verified"] = false
        value["sender_verified"] = false
        value["image_message_direction"] = "unknown_from_directory"
        value["anchor_file_ids"] = anchorFileIDs
        value["asset_variant"] = isThumbnail ? "thumbnail" : "larger_or_standard_variant"
        value["conversation_directory_id"] = scope
        value["format_hint"] = format
        value["file_family"] = family
        value["seconds_from_notification"] = secondsFromNotification
        value["window_seconds"] = ImageAssociations.window
        value["timestamp_source"] = "notification_delivered_at"
        value["nearby_image_notification_ids"] = nearbyNotificationIDs
        value["assessment_by"] = "ai_client"
        value["content_returned"] = false
        value["preview"] = preview?.objectValue(paths: paths) ?? ["state": "not_prepared"]
        return value
    }
}

struct ImageAssociationGroup: Identifiable {
    let id: String
    let versions: [ImageAssociation]
    var preferred: ImageAssociation { versions[0] }
}

struct ImageAssociationScan: Codable {
    var state: String
    var files: Int
    var messages: Int
    var anchorNotifications: Int? = nil
    var failures: Int
    var complete: Bool
    var scannedAt: String
    enum CodingKeys: String, CodingKey {
        case state, files, messages, failures, complete
        case scannedAt = "scanned_at"
        case anchorNotifications = "anchor_notifications"
    }
}
