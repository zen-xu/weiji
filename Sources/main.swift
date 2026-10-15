import AppKit
import SwiftUI
import Darwin

func output(_ value: Any) throws {
    var bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    bytes.append(10); try FileHandle.standardOutput.write(contentsOf: bytes)
}

func cli(_ args: [String], paths: AppPaths) throws {
    let service = QueryService(paths: paths)
    let command = args.first ?? "help"
    func option(_ name: String) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.count else { throw ListenerError("\(name) 缺少值。") }
        return args[index + 1]
    }
    func queryArguments() throws -> [String: Any] {
        var value = [String: Any]()
        for (flag, key) in [("--query", "query"), ("--conversation", "conversation_id"), ("--from", "from"), ("--to", "to")] {
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
    case "status": try output(service.status())
    case "conversations":
        var values = try queryArguments(); values.removeValue(forKey: "conversation_id"); values.removeValue(forKey: "from"); values.removeValue(forKey: "to")
        try output(service.call("wechat_list_conversations", arguments: values))
    case "search", "messages": try output(service.call("wechat_search_messages", arguments: queryArguments()))
    case "files":
        var values = try queryArguments(); values.removeValue(forKey: "conversation_id"); values.removeValue(forKey: "from"); values.removeValue(forKey: "to")
        try output(service.call("wechat_search_files", arguments: values))
    case "scan-files":
        guard let directory = try option("--directory") else { throw ListenerError("请传入 --directory 微信账号目录或 msg/file。") }
        let archive = try Archive(paths: paths)
        let files = try archive.scanFiles(in: URL(fileURLWithPath: directory))
        var value = try object(files) as! [String: Any]
        value["image_associations"] = try object(archive.scanImageAssociations(fileRoot: URL(fileURLWithPath: files.root)))
        value["image_previews"] = try archive.prepareImagePreviews()
        try output(value)
    case "context":
        guard let id = try option("--message") else { throw ListenerError("请传入 --message 消息ID。") }
        var values: [String: Any] = ["message_id": id]
        if let radius = try option("--radius") {
            guard let n = Int(radius) else { throw ListenerError("radius 必须为整数。") }; values["radius"] = n
        }
        try output(service.call("wechat_get_context", arguments: values))
    case "import":
        guard let input = try option("--input") else { throw ListenerError("请传入 --input JSONL文件或目录。") }
        let result = try Archive(paths: paths).importJSONL(from: URL(fileURLWithPath: input))
        try output(["inserted": result.inserted, "updated": result.updated, "unchanged": result.unchanged, "failed": result.failed])
    case "capture-once":
        let result = try NotificationSource(url: paths.source).capture(to: Archive(paths: paths))
        try output(["source_rows": result.sourceRows, "inserted": result.inserted, "updated": result.updated, "failed": result.failed, "journal_error": result.journalError])
    case "source-status":
        let count = try NotificationSource(url: paths.source).snapshot().count
        try output(["readable": true, "wechat_notifications": count, "content_printed": false])
    case "--help", "help":
        print("""
        微信消息监听 1.4.3
        无参数：打开应用；mcp：MCP stdio 服务（只读本地档案）
        status | conversations [--query 名称] | search [--query 关键词] [--conversation ID]
        search 还支持 --from YYYY-MM-DD --to YYYY-MM-DD --limit 1..200 --offset N
        context --message ID [--radius 0..20]
        import --input JSONL文件或旧数据目录
        scan-files --directory 微信账号目录：只读探测文件，更新本机索引并生成图片预览
        files [--query 文件名]：查询已探测的普通文件，不读取内容
        source-status：只检查系统通知访问权限与数量
        capture-once：读取一次当前系统保留的微信通知并保存
        --self-test：仅使用合成数据运行测试
        --demo --data-dir 目录：使用独立合成数据打开界面
        所有命令支持 --data-dir 目录。通知档案不等于完整聊天记录。
        """)
    default: throw ListenerError("未知命令。使用 --help 查看用法。")
    }
}

@MainActor final class ListenerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model: AppModel
    var window: NSWindow!
    var statusItem: NSStatusItem!
    init(paths: AppPaths, allowNotificationCapture: Bool = true) { model = AppModel(paths: paths, allowNotificationCapture: allowNotificationCapture) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "微信消息监听"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 920, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ListenerView(model: model).padding(.top, 12))
        window.setFrameAutosaveName("WeChatListenerMainWindow")
        window.center()
        let mainMenu = NSMenu(), appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于微信消息监听", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "显示窗口", action: #selector(showWindow), keyEquivalent: "0")
        appMenu.addItem(withTitle: "开始 / 暂停通知采集", action: #selector(toggle), keyEquivalent: "k")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏微信消息监听", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出微信消息监听", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editItem = NSMenuItem(), editMenu = NSMenu(title: "编辑")
        for (name, selector, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: name, action: selector, keyEquivalent: key)
        }
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "微信消息监听")
        statusItem.button?.toolTip = "微信消息监听"
        let statusMenu = NSMenu(); statusMenu.delegate = self; statusItem.menu = statusMenu
        model.onStatusChange = { [weak self] in self?.statusItem.button?.toolTip = self?.model.statusText }
        showWindow()
        model.startUp()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: ""); status.isEnabled = false; menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开消息档案", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: model.isCollecting ? "暂停采集" : "开始采集", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出微信消息监听", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for item in menu.items where item.action != nil { item.target = item.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
    }
    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func toggle() { model.toggleCollection() }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "微信消息监听", .applicationVersion: "1.4.3", .credits: NSAttributedString(string: "本机通知归档与只读 MCP 查询。通知不是完整聊天记录。")])
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.stop(); model.stopDirectoryMonitoring()
        model.worker.perform({ try $0.flushJournal() }) { _ in sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

func seedDemo(paths: AppPaths) throws {
    let archive = try Archive(paths: paths)
    guard try archive.count() == 0 else { return }
    let fixtures: [(String, String, String, String)] = [
        ("fixture-product@chatroom", "产品讨论 · 示例", "林同学", "下周三的版本评审安排在下午三点，记得提前准备演示材料。"),
        ("fixture-design", "设计同学 · 示例", "", "首页的新版设计稿已更新，重点调整了搜索和空状态。"),
        ("fixture-product@chatroom", "产品讨论 · 示例", "陈同学", "报价单收到，周五前一起确认最终范围。"),
        ("fixture-family@chatroom", "家人 · 示例", "家人", "周末聚餐改到六点，看到后记一下。"),
        ("fixture-design", "设计同学 · 示例", "", "交互说明里也加了通知权限的引导，明天可以一起看。")
    ]
    for (index, fixture) in fixtures.enumerated() {
        let date = Date().addingTimeInterval(Double(-index * 480))
        try archive.ingest(NotificationDecoder.make(record: Int64(index + 1), title: fixture.1, subtitle: fixture.2, body: fixture.3,
            chat: fixture.0, identity: "fixture-demo-\(index)", delivered: date, captured: date))
    }
    try archive.flushJournal()
}

umask(0o077)
var arguments = Array(CommandLine.arguments.dropFirst())
var override: String?
if let index = arguments.firstIndex(of: "--data-dir") {
    guard index + 1 < arguments.count else { fputs("--data-dir 缺少目录\n", stderr); exit(2) }
    override = arguments[index + 1]; arguments.removeSubrange(index...index + 1)
}
let paths = AppPaths(override: override)
do {
    if arguments.first == "--self-test" { try runSelfTests(); exit(0) }
    let demo = arguments.first == "--demo"
    if demo {
        guard override != nil else { throw ListenerError("演示模式必须指定独立的 --data-dir，避免混入真实档案。") }
        try seedDemo(paths: paths)
    }
    if !arguments.isEmpty && !demo { try cli(arguments, paths: paths); exit(0) }
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows]); exit(0)
        }
        let delegate = ListenerDelegate(paths: paths, allowNotificationCapture: !demo)
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
} catch {
    try? output(["ok": false, "error": error.localizedDescription]); exit(1)
}
