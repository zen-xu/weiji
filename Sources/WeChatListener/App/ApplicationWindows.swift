import AppKit
import SwiftUI

@MainActor
enum ApplicationWindows {
    static let startupSize = NSSize(width: 600, height: 600)
    static let libraryMinimum = NSSize(width: 820, height: 580)

    static func startup(model: AppModel, startup: StartupCoordinator) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.title = ApplicationInfo.name
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        let controller = host(ApplicationRootView(model: model, startup: startup))
        window.contentViewController = controller
        window.contentMinSize = startupSize
        window.setContentSize(startupSize)
        window.center()
        return window
    }

    static func library(_ window: NSWindow, autosaveName: String? = "WeChatListenerMainWindow") {
        window.styleMask.insert(.resizable)
        window.contentMinSize = libraryMinimum
        let restored = autosaveName.map { window.setFrameUsingName($0) } ?? false
        if !restored {
            window.setContentSize(NSSize(width: 1160, height: 800))
            window.center()
        }
        // Recheck restored geometry too: older builds may have saved an unusable frame.
        let size = window.contentRect(forFrameRect: window.frame).size
        window.setContentSize(
            NSSize(width: max(size.width, libraryMinimum.width), height: max(size.height, libraryMinimum.height)))
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
    }

    static func settings(model: AppModel) -> NSWindow {
        let size = NSSize(width: 560, height: 560)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let controller = host(SettingsView(model: model).frame(width: size.width, height: size.height))
        window.contentViewController = controller
        window.contentMinSize = size
        window.setContentSize(size)
        window.center()
        return window
    }

    private static func host<Content: View>(_ content: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: content)
        // Propagate only the explicit minimum in the root view. A transient
        // preferred size must never resize AppKit's startup/restored window.
        controller.sizingOptions = [.minSize]
        (controller.view as? NSHostingView<Content>)?.sizingOptions = [.minSize]
        return controller
    }

    static func reminderRules(model: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 580), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "提醒规则"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentViewController = host(ReminderRulesView(model: model))
        window.contentMinSize = NSSize(width: 640, height: 500)
        window.setContentSize(NSSize(width: 720, height: 580))
        window.center()
        return window
    }
}
