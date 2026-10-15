import Foundation

enum MCPQueryError: LocalizedError {
    case invalidArguments(String)
    case archiveUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        case .archiveUnavailable: "尚无本地档案，请先打开\(ApplicationInfo.name)完成启动设置，采集通知或导入旧数据。"
        }
    }
    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .archiveUnavailable: "archive_not_available"
        }
    }
    var nextAction: String {
        switch self {
        case .invalidArguments: "按工具 inputSchema 修正参数后重试。"
        case .archiveUnavailable: "请用户在\(ApplicationInfo.name)中完成启动设置并采集或导入；重复查询不会创建档案。"
        }
    }
}
