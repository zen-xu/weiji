import Foundation

enum DemoData {
    static func populate(paths: AppPaths) throws {
        let archive = try Archive(paths: paths)
        guard try archive.count() == 0 else { return }
        let fixtures: [(String, String, String, String)] = [
            ("fixture-product@chatroom", "产品讨论 · 示例", "林同学", "下周三的版本评审安排在下午三点，记得提前准备演示材料。"),
            ("fixture-design", "设计同学 · 示例", "", "首页的新版设计稿已更新，重点调整了搜索和空状态。"),
            ("fixture-product@chatroom", "产品讨论 · 示例", "陈同学", "报价单收到，周五前一起确认最终范围。"),
            ("fixture-family@chatroom", "家人 · 示例", "家人", "周末聚餐改到六点，看到后记一下。"),
            ("fixture-design", "设计同学 · 示例", "", "交互说明里也加了通知权限的引导，明天可以一起看。"),
        ]
        for (index, fixture) in fixtures.enumerated() {
            let date = Date().addingTimeInterval(Double(-index * 480))
            try archive.ingest(
                NotificationDecoder.make(
                    record: Int64(index + 1), title: fixture.1, subtitle: fixture.2, body: fixture.3,
                    chat: fixture.0, identity: "fixture-demo-\(index)", delivered: date, captured: date))
        }
        try archive.flushJournal()
    }

}
