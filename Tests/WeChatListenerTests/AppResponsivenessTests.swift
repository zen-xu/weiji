import Foundation
import Testing

@testable import WeChatListener

private func responsivenessFixture(_ root: URL) throws -> AppPaths {
    let paths = AppPaths(override: root.appendingPathComponent("archive").path)
    let archive = try Archive(paths: paths)
    for (record, body) in [(1, "旧记录"), (2, "新关键词")] {
        try archive.ingest(
            NotificationDecoder.make(
                record: Int64(record), title: "合成测试", subtitle: "", body: body,
                chat: "synthetic-peer", delivered: TestSupport.referenceDate, captured: TestSupport.referenceDate))
    }
    return paths
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ListenerError("Synthetic GUI operation timed out")
}

@Test("GUI queries remain responsive while the writer is busy scanning")
@MainActor
func guiReadsBypassScanning() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(paths: try responsivenessFixture(root), allowNotificationCapture: false)
    let blocked = DispatchSemaphore(value: 0)
    defer { blocked.signal() }
    model.worker.perform { _ in
        _ = blocked.wait(timeout: .now() + 3)
    } completion: { _ in
    }
    model.refresh()
    model.refreshFiles()
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.messages.count == 2 && model.stats?.messages == 2)
    blocked.signal()
    try await eventually { !model.loading }
}

@Test("Changing search text invalidates previous results before the debounce fires")
@MainActor
func guiSearchInvalidatesImmediately() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(paths: try responsivenessFixture(root), allowNotificationCapture: false)
    model.refresh()
    model.search = "新关键词"
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.messages.isEmpty)
    try await eventually { model.messages.count == 1 && !model.loading }
    #expect(model.messages.first?.body == "新关键词")
}

@Test("Stopping directory work suppresses queued scans and late status updates")
@MainActor
func stoppedScansStayStopped() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try responsivenessFixture(root)
    let folder = root.appendingPathComponent("account/msg/file")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("Synthetic only".utf8).write(to: folder.appendingPathComponent("test.pdf"))
    let model = AppModel(paths: paths, allowNotificationCapture: false)
    model.preferences.fileDirectory = folder.path
    let blocked = DispatchSemaphore(value: 0)
    defer { blocked.signal() }
    model.worker.perform { _ in
        _ = blocked.wait(timeout: .now() + 3)
    } completion: { _ in
    }
    model.scanFiles()
    model.stopDirectoryMonitoring()
    model.fileScanStatus = "已停止测试"
    blocked.signal()
    try await eventually { !model.fileScanBusy }
    #expect(model.fileScanStatus == "已停止测试")
    #expect(try Archive(paths: paths, readOnly: true).discoveredFileCount() == 0)
}

@Test("Read work coalesces queued requests and suppresses completions already waiting on main")
@MainActor
func guiReadCoalescing() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let reader = LibraryWorker(paths: try responsivenessFixture(root), readOnly: true)
    let blocked = DispatchSemaphore(value: 0)
    defer { blocked.signal() }
    reader.perform { _ in
        _ = blocked.wait(timeout: .now() + 3)
    } completion: { _ in
    }
    var results = [Int]()
    var executed = [Int]()
    for number in 0..<50 {
        reader.performLatest(.messages) { _ in
            executed.append(number)
            return number
        } completion: { result in
            if case .success(let value) = result { results.append(value) }
        }
    }
    blocked.signal()
    try await eventually { !results.isEmpty }
    #expect(results == [49])
    #expect(executed == [49])
    let finished = DispatchSemaphore(value: 0)
    reader.performLatest(.messages) { _ in
        finished.signal()
        return 99
    } completion: { _ in
        results.append(99)
    }
    // Hold the main actor only to reproduce a completion waiting behind an input event.
    #expect(finished.wait(timeout: .now() + 1) == .success)
    reader.invalidate(.messages)
    try await Task.sleep(for: .milliseconds(30))
    #expect(results == [49])
}

@Test("Clear cancels queued media work, closes images and cannot be undone by a late scan")
@MainActor
func guiClearCancelsPendingWork() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try responsivenessFixture(root)
    let folder = root.appendingPathComponent("account/msg/file")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("Synthetic".utf8).write(to: folder.appendingPathComponent("test.pdf"))
    let model = AppModel(paths: paths, allowNotificationCapture: false)
    model.preferences.fileDirectory = folder.path
    model.selectedImage = ImagePreview(
        fileID: digest("synthetic"), stamp: "fixture", token: digest("token"), state: "ready")
    let blocked = DispatchSemaphore(value: 0)
    defer { blocked.signal() }
    model.worker.perform { _ in
        _ = blocked.wait(timeout: .now() + 3)
    } completion: { _ in
    }
    model.scanFiles()
    model.refresh()
    model.clearLocalArchive()
    #expect(model.selectedImage == nil && model.messages.isEmpty && model.files.isEmpty)
    blocked.signal()
    try await eventually { !model.isWorking && !model.fileScanBusy && model.stats?.messages == 0 }
    let archive = try Archive(paths: paths, readOnly: true)
    #expect(try archive.count() == 0 && archive.discoveredFileCount() == 0)
    #expect(model.fileScanStatus != "正在探测本地文件…")
    model.shutDown()
}

@Test("Startup establishes the archive before read connections and shutdown invalidates queued startup")
@MainActor
func guiStartupAndShutdown() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(
        paths: AppPaths(override: root.appendingPathComponent("new").path), allowNotificationCapture: false)
    model.startUp()
    try await eventually { model.stats != nil && !model.loading }
    #expect(model.errorText == nil && model.stats?.messages == 0)
    model.shutDown()
    let other = AppModel(paths: try responsivenessFixture(root), allowNotificationCapture: false)
    let blocked = DispatchSemaphore(value: 0)
    defer { blocked.signal() }
    other.worker.perform { _ in
        _ = blocked.wait(timeout: .now() + 3)
    } completion: { _ in
    }
    other.startUp()
    other.shutDown()
    blocked.signal()
    try await Task.sleep(for: .milliseconds(50))
    other.refresh()
    other.refreshFiles()
    other.refreshDirectoryImages()
    other.startUp()
    #expect(other.stats == nil && !other.loading && !other.filesLoading && !other.directoryImagesLoading)
    #expect(!other.isCollecting && other.isShuttingDown)
}

@Test("Runtime heartbeat batches unchanged writes but promptly reports errors and state changes")
@MainActor
func guiRuntimeWriteCoalescing() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try responsivenessFixture(root)
    let model = AppModel(paths: paths, allowNotificationCapture: false)
    let runtime = paths.root.appendingPathComponent("runtime.json")
    let marker = Date(timeIntervalSince1970: 100)
    func modified() throws -> Date {
        try FileManager.default.attributesOfItem(atPath: runtime.path)[.modificationDate] as! Date
    }
    model.saveRuntime("collecting", uptime: 100)
    try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: runtime.path)
    model.saveRuntime("collecting", uptime: 110)
    #expect(try modified() == marker)
    model.parseErrors = 1
    model.saveRuntime("collecting", uptime: 111)
    #expect(try modified() != marker)
    try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: runtime.path)
    model.saveRuntime("collecting", uptime: 125)
    #expect(try modified() == marker)
    model.saveRuntime("collecting", uptime: 126)
    #expect(try modified() != marker)
    let permissions = try FileManager.default.attributesOfItem(atPath: runtime.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test("Switching accounts drops the earlier queued scan and indexes the new account")
@MainActor
func guiDirectorySwitchUsesCurrentScope() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(paths: try responsivenessFixture(root), allowNotificationCapture: false)
    defer { model.stopDirectoryMonitoring() }
    let old = root.appendingPathComponent("old/msg/file")
    let new = root.appendingPathComponent("new/msg/file")
    for folder in [old, new] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Synthetic".utf8).write(to: folder.appendingPathComponent("test.pdf"))
    }
    let blocked = DispatchSemaphore(value: 0)
    defer { blocked.signal() }
    model.worker.perform { _ in
        _ = blocked.wait(timeout: .now() + 3)
    } completion: { _ in
    }
    model.preferences.fileDirectory = old.path
    model.files = [
        DiscoveredFile(
            id: digest("old-file"), root: old.path, relativePath: "test.pdf", name: "test.pdf",
            bytes: 9, modifiedAt: Dates.string(TestSupport.referenceDate), available: true)
    ]
    model.scanFiles()
    try model.selectFileDirectory(new.path)
    #expect(model.files.isEmpty && model.directoryImages.isEmpty && model.filesLoading)
    blocked.signal()
    for _ in 0..<400 {
        if model.files.first?.root == new.path { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.files.count == 1 && model.files.first?.root == new.path)
    let all = try Archive(paths: model.paths, readOnly: true).database.rows("SELECT root FROM discovered_files")
    #expect(all.allSatisfy { $0.string("root") == new.path })
}

@Test("Continuous directory events cannot indefinitely postpone a scan")
@MainActor
func guiDirectoryEventsDoNotStarve() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(paths: try responsivenessFixture(root), allowNotificationCapture: false)
    defer { model.stopDirectoryMonitoring() }
    let folder = root.appendingPathComponent("account/msg/file")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("Synthetic".utf8).write(to: folder.appendingPathComponent("test.pdf"))
    model.preferences.fileDirectory = folder.path
    for _ in 0..<25 {
        model.scheduleDirectoryScan()
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(model.files.count == 1)
}

@Test("Preview batches let queued capture run between images and stop after cancellation")
@MainActor
func guiPreviewBatchesYieldToCapture() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let worker = LibraryWorker(paths: try responsivenessFixture(root))
    let blocked = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    defer { blocked.signal() }
    // Both the recorder and the synthetic decoder run on the same serial writer.
    var events = [String]()
    var batches = 0
    let preparer = PreviewPreparation(worker: worker) { _, limit, _ in
        batches += 1
        events.append("batch\(batches)")
        if batches == 1 {
            entered.signal()
            _ = blocked.wait(timeout: .now() + 3)
        }
        return ["attempted": batches == 1 ? limit : 0]
    }
    let token = BackgroundWorkToken()
    preparer.prepareRecent(token: token, onBatch: {}, onFailure: { _ in Issue.record("Unexpected synthetic failure") })
    #expect(entered.wait(timeout: .now() + 1) == .success)
    worker.perform { _ in
        events.append("capture")
    } completion: { _ in
    }
    blocked.signal()
    try await eventually { !preparer.isRunning }
    #expect(events == ["batch1", "capture", "batch2"])
    let cancelled = BackgroundWorkToken()
    cancelled.cancel()
    preparer.prepareRecent(
        token: cancelled, onBatch: { Issue.record("Cancelled work delivered a batch") }, onFailure: { _ in })
    #expect(!preparer.isRunning)
    let enteredAgain = DispatchSemaphore(value: 0)
    let releaseAgain = DispatchSemaphore(value: 0)
    defer { releaseAgain.signal() }
    var attemptedBatches = 0
    let active = PreviewPreparation(worker: worker) { _, limit, _ in
        attemptedBatches += 1
        enteredAgain.signal()
        _ = releaseAgain.wait(timeout: .now() + 3)
        return ["attempted": limit]
    }
    let activeToken = BackgroundWorkToken()
    active.prepareRecent(
        token: activeToken, onBatch: { Issue.record("Cancelled batch reached the UI") }, onFailure: { _ in })
    #expect(enteredAgain.wait(timeout: .now() + 1) == .success)
    activeToken.cancel()
    releaseAgain.signal()
    try await eventually { !active.isRunning }
    #expect(attemptedBatches == 1)
}

@Test("Failed settings writes preserve the previous UI state and directory configuration")
@MainActor
func guiPreferencesSaveBeforeApplying() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try responsivenessFixture(root)
    let model = AppModel(paths: paths, allowNotificationCapture: false)
    try FileManager.default.createDirectory(at: paths.preferences, withIntermediateDirectories: true)
    model.setCollectOnLaunch(true)
    #expect(!model.preferences.collectOnLaunch && model.errorText != nil)
    #expect(throws: (any Error).self) {
        try model.updatePreferences { $0.fileDirectory = "/synthetic/new-account" }
    }
    #expect(model.preferences.fileDirectory == nil)
    try FileManager.default.removeItem(at: paths.preferences)
    model.setCollectOnLaunch(true)
    #expect(model.preferences.collectOnLaunch && Preferences.load(paths).collectOnLaunch)
}
