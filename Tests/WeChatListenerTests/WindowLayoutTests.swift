import AppKit
import SwiftUI
import Testing

@testable import WeChatListener

@Test("The real AppKit startup window retains its size through access checks")
@MainActor
func startupWindowRetainsUsableSize() async throws {
    _ = NSApplication.shared
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(paths: AppPaths(override: root.path), allowNotificationCapture: false)
    let startup = StartupCoordinator(setupCompleted: false, checkAccess: { .denied }, persistCompletion: {})
    let window = ApplicationWindows.startup(model: model, startup: startup)
    defer {
        startup.cancel()
        model.shutDown()
        window.close()
    }
    startup.start()
    for _ in 0..<50 {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(startup.stage == .accessRequired(.denied))
    let content = try #require(window.contentView)
    #expect(content.bounds.width >= 600)
    #expect(content.bounds.height >= 600)
    #expect(window.minSize.width >= 600)
    #expect(window.minSize.height >= 600)
    startup.recheck()
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(content.bounds.width >= 600 && content.bounds.height >= 600)
}

@Test("The startup window expands into the actual library without saving test geometry")
@MainActor
func startupWindowTransitionsToLibrary() async throws {
    _ = NSApplication.shared
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(paths: AppPaths(override: root.path), allowNotificationCapture: false)
    let startup = StartupCoordinator(setupCompleted: false, checkAccess: { .readable }, persistCompletion: {})
    let window = ApplicationWindows.startup(model: model, startup: startup)
    defer {
        startup.cancel()
        model.shutDown()
        window.close()
    }
    startup.onStageChange = { stage in
        if stage == .ready { ApplicationWindows.library(window, autosaveName: nil) }
    }
    startup.start()
    for _ in 0..<50 where startup.stage != .configuration { try await Task.sleep(for: .milliseconds(10)) }
    #expect(startup.stage == .configuration)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(window.minSize.width >= 600 && window.minSize.height >= 600)
    startup.finishSetup()
    for _ in 0..<50 {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(startup.isReady)
    #expect(window.styleMask.contains(.resizable))
    #expect(window.minSize.width >= 820 && window.minSize.height >= 580)
    #expect(window.contentView!.bounds.width >= 820 && window.contentView!.bounds.height >= 580)
}

@Test("Settings retains its content size when a notice changes its layout")
@MainActor
func settingsWindowRetainsUsableSize() async throws {
    _ = NSApplication.shared
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(paths: AppPaths(override: root.path), allowNotificationCapture: false)
    let window = ApplicationWindows.settings(model: model)
    defer {
        model.shutDown()
        window.close()
    }
    model.errorText = String(repeating: "合成的设置错误说明。", count: 12)
    for _ in 0..<50 {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(window.contentView!.bounds.width >= 560 && window.contentView!.bounds.height >= 560)
    #expect(window.minSize.width >= 560 && window.minSize.height >= 560)
}
