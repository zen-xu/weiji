import Foundation

enum Page: String, CaseIterable, Hashable {
    case archive = "消息档案"
    case files = "微信文件"
    case images = "目录图片"
    case overview = "采集状态"
    case mcp = "连接 Codex"
}
enum DateScope: String, CaseIterable {
    case all = "全部时间"
    case today = "今天"
    case week = "最近 7 天"
    case custom = "自定义"
}

enum SidebarSelection: Hashable {
    case page(Page)
    case conversation(String)
}
