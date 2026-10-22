import Foundation

/// Notification provenance, independent of transport and any inferred conversation identity.
enum NotificationPlatform: String, CaseIterable, Codable, Identifiable {
    case wechat, feishu
    var id: String { rawValue }
    var name: String { self == .wechat ? "微信" : "飞书" }
    var bundleID: String { self == .wechat ? "com.tencent.xinwechat" : "com.electron.lark" }
    static func platform(for bundleID: String) -> Self? {
        allCases.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

extension Message {
    var notificationPlatform: NotificationPlatform? { NotificationPlatform.platform(for: appBundleID) }
    var platformName: String { notificationPlatform?.name ?? "Agent" }
}
