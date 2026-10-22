import Foundation

enum CommandLineInterface {
    static func writeJSON(_ value: Any) throws {
        var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }

    static func run(_ args: [String], paths: AppPaths) throws {
        let service = QueryService(paths: paths)
        let command = args.first ?? "help"
        func option(_ name: String) throws -> String? {
            guard let index = args.firstIndex(of: name) else { return nil }
            guard index + 1 < args.count else { throw ListenerError("\(name) 缺少值。") }
            return args[index + 1]
        }
        func queryArguments() throws -> [String: Any] {
            var value = [String: Any]()
            for (flag, key) in [
                ("--query", "query"), ("--conversation", "conversation_id"), ("--from", "from"), ("--to", "to"),
                ("--source", "source"),
            ] {
                if let text = try option(flag) { value[key] = text }
            }
            for flag in ["limit", "offset"] {
                if let raw = try option("--" + flag) {
                    guard let number = Int(raw) else { throw ListenerError("\(flag) 必须为整数。") }
                    value[flag] = number
                }
            }
            return value
        }
        switch command {
        case "mcp": MCPServer(paths: paths).run()
        case "mcp-http":
            let raw = try option("--port") ?? String(MCPHTTPServer.defaultPort)
            guard let port = UInt16(raw), port > 0 else { throw ListenerError("端口必须是 1…65535 的整数。") }
            let server = MCPHTTPServer(paths: paths)
            server.start(port: port) { state in
                switch state {
                case .listening(let port):
                    fputs("MCP listening at http://127.0.0.1:\(port)/mcp\n", stderr)
                case .failed(let message):
                    fputs("MCP HTTP: \(message)\n", stderr)
                    exit(1)
                default: break
                }
            }
            withExtendedLifetime(server) { dispatchMain() }
        case "status": try writeJSON(service.status())
        case "conversations":
            var values = try queryArguments()
            values.removeValue(forKey: "conversation_id")
            values.removeValue(forKey: "from")
            values.removeValue(forKey: "to")
            try writeJSON(service.call("wechat_list_conversations", arguments: values))
        case "search", "messages": try writeJSON(service.call("wechat_search_messages", arguments: queryArguments()))
        case "files":
            var values = try queryArguments()
            values.removeValue(forKey: "conversation_id")
            values.removeValue(forKey: "from")
            values.removeValue(forKey: "to")
            values.removeValue(forKey: "source")
            try writeJSON(service.call("wechat_search_files", arguments: values))
        case "scan-files":
            guard let directory = try option("--directory") else {
                throw ListenerError("请传入 --directory 微信账号目录或 msg/file。")
            }
            let archive = try Archive(paths: paths)
            let files = try archive.scanFiles(in: URL(fileURLWithPath: directory))
            var value = try object(files) as! [String: Any]
            value["image_associations"] = try object(
                archive.scanImageAssociations(fileRoot: URL(fileURLWithPath: files.root)))
            value["image_previews"] = try archive.prepareImagePreviews()
            try writeJSON(value)
        case "context":
            guard let id = try option("--message") else { throw ListenerError("请传入 --message 消息ID。") }
            var values: [String: Any] = ["message_id": id]
            if let radius = try option("--radius") {
                guard let n = Int(radius) else { throw ListenerError("radius 必须为整数。") }
                values["radius"] = n
            }
            try writeJSON(service.call("wechat_get_context", arguments: values))
        case "import":
            guard let input = try option("--input") else { throw ListenerError("请传入 --input JSONL文件或目录。") }
            let result = try Archive(paths: paths).importJSONL(from: URL(fileURLWithPath: input))
            try writeJSON([
                "inserted": result.inserted, "updated": result.updated, "unchanged": result.unchanged,
                "failed": result.failed,
            ])
        case "capture-once":
            let result = try NotificationSource(url: paths.source).capture(to: Archive(paths: paths))
            try writeJSON([
                "source_rows": result.sourceRows, "inserted": result.inserted, "updated": result.updated,
                "failed": result.failed, "journal_error": result.journalError,
            ])
        case "source-status":
            let rows = try NotificationSource(url: paths.source).snapshot()
            let counts = Dictionary(grouping: rows, by: { $0.string("app_bundle_id") ?? "" }).mapValues(\.count)
            try writeJSON([
                "readable": true, "notifications": rows.count,
                "wechat_notifications": counts[NotificationPlatform.wechat.bundleID] ?? 0,
                "feishu_notifications": counts[NotificationPlatform.feishu.bundleID] ?? 0,
                "content_printed": false,
            ])
        case "--version": print(ApplicationInfo.version)
        case "--self-test": throw ListenerError("自测已移至独立测试目标，请运行 bash Scripts/test.sh。")
        case "--help", "help":
            print(
                """
                \(ApplicationInfo.name) \(ApplicationInfo.version)
                无参数：打开应用，自动提供本地 HTTP MCP 服务
                mcp-http [--port 18765]：独立运行本地 HTTP MCP 服务（档案只读，可管理提醒规则）
                mcp：兼容旧版 MCP stdio 接入
                status | conversations [--query 名称] | search [--query 关键词] [--conversation ID]
                conversations / search 可传 --source wechat|feishu，省略为全部来源
                search 还支持 --from YYYY-MM-DD --to YYYY-MM-DD --limit 1..200 --offset N
                context --message ID [--radius 0..20]
                import --input JSONL文件或旧数据目录
                scan-files --directory 微信账号目录：只读探测文件，更新本机索引并生成图片预览
                files [--query 文件名]：查询已探测的普通文件，不读取内容
                source-status：只检查系统通知访问权限与数量
                capture-once：读取一次当前系统保留的微信和飞书通知文字并保存
                --demo --data-dir 目录：使用独立合成数据打开界面
                所有命令支持 --data-dir 目录。通知档案不等于完整聊天记录。
                """)
        default: throw ListenerError("未知命令。使用 --help 查看用法。")
        }
    }

}
