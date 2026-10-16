import AppKit
import SwiftUI

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation
{
    let model: AppModel
    let startup: StartupCoordinator
    var window: NSWindow!
    var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    init(paths: AppPaths, allowNotificationCapture: Bool = true) {
        let model = AppModel(paths: paths, allowNotificationCapture: allowNotificationCapture)
        self.model = model
        let source = paths.source
        startup = StartupCoordinator(
            setupCompleted: model.preferences.onboardingCompleted == true,
            demo: !allowNotificationCapture,
            checkAccess: {
                await Task.detached(priority: .userInitiated) { NotificationAccessChecker.check(source) }.value
            },
            persistCompletion: { try model.completeStartupSetup() })
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = ApplicationWindows.startup(model: model, startup: startup)
        window.delegate = self
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于\(ApplicationInfo.name)", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "显示窗口", action: #selector(showWindow), keyEquivalent: "0")
        appMenu.addItem(withTitle: "开始 / 暂停通知采集", action: #selector(toggle), keyEquivalent: "k")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏\(ApplicationInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "退出\(ApplicationInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "导入通知…", action: #selector(importNotifications), keyEquivalent: "o")
        let exportItem = fileMenu.addItem(withTitle: "导出通知为 JSONL…", action: #selector(exportJSONL), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "导出通知为 Markdown…", action: #selector(exportMarkdown), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for item in fileMenu.items where item.action != #selector(NSWindow.performClose(_:)) && item.action != nil {
            item.target = self
        }
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        for (name, selector, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a"),
        ] {
            editMenu.addItem(withTitle: name, action: selector, keyEquivalent: key)
        }
        editMenu.addItem(.separator())
        let find = editMenu.addItem(withTitle: "搜索", action: #selector(focusSearch), keyEquivalent: "f")
        find.target = self
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        let sidebar = viewMenu.addItem(
            withTitle: "显示 / 隐藏边栏", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: ApplicationInfo.name)
        statusItem.button?.toolTip = ApplicationInfo.name
        let statusMenu = NSMenu()
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        model.onStatusChange = { [weak self] in self?.statusItem.button?.toolTip = self?.model.statusText }
        model.onOpenSettings = { [weak self] in self?.showSettings() }
        startup.onStageChange = { [weak self] stage in
            guard let self else { return }
            self.statusItem.button?.toolTip = stage == .ready ? self.model.statusText : "等待完成启动设置"
            if stage == .ready { self.configureMainWindow() }
        }
        startup.onReady = { [weak self] in self?.model.startUp() }
        // Historical MCP queries remain available while first-run access is being configured.
        model.startMCPServer()
        startup.start()
        showWindow()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: startup.isReady ? model.statusText : "等待完成启动设置", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: startup.isReady ? "打开消息档案" : "完成启动设置…", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: model.isCollecting ? "暂停采集" : "开始采集", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "退出\(ApplicationInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for item in menu.items where item.action != nil {
            item.target = item.action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        }
    }
    private func configureMainWindow() {
        ApplicationWindows.library(window)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if !startup.isReady { startup.recheck() }
    }
    @objc func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showSettings() {
        guard startup.isReady else {
            showWindow()
            return
        }
        if settingsWindow == nil {
            settingsWindow = ApplicationWindows.settings(model: model)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(focusSearch) {
            return startup.isReady && [.archive, .files, .images].contains(model.page)
        }
        if let action = item.action,
            [
                #selector(importNotifications), #selector(exportJSONL), #selector(exportMarkdown), #selector(toggle),
                #selector(showSettings),
            ].contains(action)
        {
            return startup.isReady && !model.isWorking
        }
        return true
    }
    @objc func importNotifications() { model.importArchive() }
    @objc func focusSearch() {
        guard startup.isReady, [.archive, .files, .images].contains(model.page) else { return }
        showWindow()
        model.searchPresented = true
    }
    @objc func exportJSONL() { model.exportArchive(markdown: false) }
    @objc func exportMarkdown() { model.exportArchive(markdown: true) }
    @objc func toggle() {
        guard startup.isReady else {
            showWindow()
            return
        }
        model.toggleCollection()
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: ApplicationInfo.name, .applicationVersion: ApplicationInfo.version,
            .credits: NSAttributedString(string: "本机通知归档与只读 MCP 查询。通知不是完整聊天记录。"),
        ])
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        startup.cancel()
        model.stopMCPServer()
        model.shutDown()
        guard model.hasStartedLibrary else { return .terminateNow }
        model.worker.perform {
            try $0.flushJournal()
        } completion: { _ in
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
