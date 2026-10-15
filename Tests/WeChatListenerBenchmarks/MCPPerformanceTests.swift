import Foundation
import Testing

@testable import WeChatListener

@Test(
    "Synthetic MCP query performance", .enabled(if: ProcessInfo.processInfo.environment["WECHAT_RUN_BENCHMARKS"] == "1")
)
func mcpQueryPerformance() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("weiji-mcp-benchmark-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let writer = try Archive(paths: paths)
    let date = Date(timeIntervalSince1970: 1_792_000_000)
    var anchor = ""
    try writer.database.transaction {
        for i in 0..<12000 {
            let message = NotificationDecoder.make(
                record: Int64(i + 1), title: i < 10000 ? "合成大群" : "合成会话\(i)", subtitle: "合成发送者",
                body: "基准正文 " + String(repeating: "上下文资料", count: 80),
                chat: i < 10000 ? "benchmark@chatroom" : "peer-\(i)", delivered: date.addingTimeInterval(Double(i)),
                captured: date)
            if i == 5000 { anchor = message.id }
            try writer.database.run(
                "INSERT INTO messages VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                [
                    .text(message.id), .text(message.sourceKey), .text(message.conversationID),
                    .text(message.conversationName), .text(message.conversationKind),
                    .text(message.conversationIDSource), .text(message.title), .text(message.subtitle),
                    .text(message.body), .text(message.deliveredAt!), .text(message.contentHash),
                    .blob(try jsonData(message)),
                ])
        }
    }
    let service = QueryService(paths: paths)
    func measure(_ name: String, _ action: () throws -> [String: Any]) throws -> [String: Any] {
        var timings = [Double]()
        var bytes = 0
        for _ in 0..<7 {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try autoreleasepool(invoking: action)
            bytes = try JSONSerialization.data(withJSONObject: value).count
            timings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        return ["name": name, "median_ms": timings.sorted()[3], "json_bytes": bytes]
    }
    var results = try [
        measure("status") { try service.call("wechat_status", arguments: [:]) },
        measure("conversations_20") { try service.call("wechat_list_conversations", arguments: ["limit": 20]) },
        measure("context_radius_5") {
            try service.call("wechat_get_context", arguments: ["message_id": anchor, "radius": 5])
        },
        measure("messages_50_full") { try service.call("wechat_search_messages", arguments: ["limit": 50]) },
    ]
    results.append(
        try measure("messages_50_compact") {
            try service.call("wechat_search_messages", arguments: ["limit": 50, "detail": "compact"])
        })
    results.append(
        try measure("conversations_20_no_total") {
            try service.call("wechat_list_conversations", arguments: ["limit": 20, "include_total": false])
        })
    print(
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: ["synthetic_messages": 12000, "conversations": 2001, "results": results],
                options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}
