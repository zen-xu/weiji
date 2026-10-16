import Foundation

enum MCPQueryError: LocalizedError {
    case invalidArguments(String)
    case archiveUnavailable
    case reminderConflict

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        case .archiveUnavailable: "尚无本地档案，请先打开\(ApplicationInfo.name)完成启动设置，采集通知或导入旧数据。"
        case .reminderConflict: "提醒规则已被其他客户端修改或正在保存，请重新读取后合并修改。"
        }
    }
    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .archiveUnavailable: "archive_not_available"
        case .reminderConflict: "reminder_revision_conflict"
        }
    }
    var nextAction: String {
        switch self {
        case .invalidArguments: "按工具 inputSchema 修正参数后重试。"
        case .archiveUnavailable: "请用户在\(ApplicationInfo.name)中完成启动设置并采集或导入；重复查询不会创建档案。"
        case .reminderConflict:
            "调用 wechat_list_reminder_rules 取得最新 revision 和规则，合并用户要求后以新 expected_revision 重试；不要覆盖其他规则。"
        }
    }
}
