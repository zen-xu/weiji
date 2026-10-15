import Foundation

enum Page: String, CaseIterable {
    case archive = "消息档案"
    case files = "微信文件"
    case images = "目录图片"
    case overview = "采集状态"
    case mcp = "连接 Codex"
    case settings = "设置"
}
enum DateScope: String, CaseIterable {
    case all = "全部时间"
    case today = "今天"
    case week = "最近 7 天"
    case custom = "自定义"
}
