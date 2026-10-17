import AppKit
import Foundation
import SwiftUI

private struct ReminderRuleSyncSettings: Codable {
    var enabled = false
    var bookmark: Data?
    static func url(_ paths: AppPaths) -> URL { paths.root.appendingPathComponent("reminder-sync.json") }
    func save(_ paths: AppPaths) throws {
        try FileManager.default.createDirectory(
            at: paths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = Self.url(paths)
        let temporary = paths.root.appendingPathComponent(".sync-settings-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard
            FileManager.default.createFile(
                atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw ListenerError("无法保存同步设置。") }
        try jsonData(self).write(to: temporary)
        guard rename(temporary.path, file.path) == 0 else { throw ListenerError("无法保存同步设置。") }
    }
}

private final class ReminderSyncPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    let changed: () -> Void
    init(url: URL, changed: @escaping () -> Void) {
        presentedItemURL = url
        self.changed = changed
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
    }
    func presentedItemDidChange() { changed() }
    func presentedSubitemDidChange(at url: URL) { changed() }
    func presentedSubitemDidAppear(at url: URL) { changed() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { changed() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        changed()
        completionHandler(nil)
    }
    func presentedItemDidMove(to newURL: URL) { changed() }
}

@MainActor final class ReminderRuleSync: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "未开启 iCloud Drive 同步"
    @Published private(set) var issue: String?
    var onRulesChanged: (() -> Void)?
    private let paths: AppPaths
    private let worker: ReminderRuleSyncWorker
    private let queue = DispatchQueue(label: "local.xzy.WeChatListener.rule-sync", qos: .utility)
    private var settings = ReminderRuleSyncSettings()
    private var work = BackgroundWorkToken()
    private var timer: Timer?
    private var presenter: ReminderSyncPresenter?
    private var scheduled: DispatchWorkItem?
    private var pending = false
    private var generation = 0
    private var running = false
    init(paths: AppPaths) {
        self.paths = paths
        worker = ReminderRuleSyncWorker(paths: paths)
        let url = ReminderRuleSyncSettings.url(paths)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                settings = try JSONDecoder().decode(ReminderRuleSyncSettings.self, from: Data(contentsOf: url))
                enabled = settings.enabled
            } catch { issue = "无法读取同步设置，请重新选择文件夹；本机规则保持不变。" }
        }
    }
    func start() {
        guard !running else { return }
        running = true
        guard enabled else { return }
        request()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.request() }
        }
        timer?.tolerance = 10
    }
    func stop() {
        running = false
        generation += 1
        work.cancel()
        worker.cancel()
        work = BackgroundWorkToken()
        timer?.invalidate()
        timer = nil
        scheduled?.cancel()
        scheduled = nil
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        presenter = nil
        worker.setPresenter(nil)
        busy = false
        pending = false
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择 iCloud Drive 同步文件夹"
        panel.message = "每台 Mac 选择同一个 iCloud Drive 文件夹。仅同步提醒规则，不包含消息、收件箱或其他设置；已有规则会合并。"
        panel.prompt = "开启同步"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do { try configure(folder: folder) } catch { issue = "无法保存同步文件夹，请重试；本机规则保持不变。" }
    }
    func configure(folder: URL) throws {
        let next = try ReminderRuleSyncSettings(
            enabled: true,
            bookmark: folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        try next.save(paths)
        stop()
        settings = next
        enabled = true
        issue = nil
        start()
    }
    func disable() {
        var next = settings
        next.enabled = false
        do { try next.save(paths) } catch {
            issue = "无法关闭同步，请检查本机数据目录。"
            return
        }
        stop()
        settings = next
        enabled = false
        issue = nil
        status = "已关闭同步，保留本机及云端规则"
    }
    func request() {
        guard enabled, running else { return }
        if busy {
            pending = true
            return
        }
        scheduled?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.perform() }
        scheduled = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }
    private func perform() {
        guard enabled, running, !busy, let bookmark = settings.bookmark else { return }
        scheduled = nil
        busy = true
        status = "正在同步规则…"
        let worker = worker
        let work = work
        let token = generation
        queue.async { [weak self] in
            let result = Result {
                var stale = false
                let folder = try URL(
                    resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                    bookmarkDataIsStale: &stale)
                guard !stale else { throw ListenerError("同步文件夹的位置或访问状态已变化，请重新选择文件夹。") }
                return try worker.exchange(folder: folder, work: work)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.running, !work.isCancelled else { return }
                self.busy = false
                switch result {
                case .success(let value):
                    self.status =
                        value.cloud
                        ? (value.uploaded ? "规则已上传至 iCloud Drive" : "规则已保存，等待 iCloud Drive 上传")
                        : "同步文件夹已更新，请确认该文件夹位于 iCloud Drive"
                    self.issue =
                        value.exceedsLimit
                        ? "合并后超过 32 条规则，已保留本机规则。请精简规则后重试，删除操作仍会同步。"
                        : value.conflicts > 0 ? "发现并发修改，已保留停用的冲突副本，请检查。" : nil
                    if self.presenter?.presentedItemURL != value.folder {
                        if let presenter = self.presenter { NSFileCoordinator.removeFilePresenter(presenter) }
                        let presenter = ReminderSyncPresenter(url: value.folder) { [weak self] in
                            Task { @MainActor in self?.request() }
                        }
                        self.presenter = presenter
                        self.worker.setPresenter(presenter)
                        NSFileCoordinator.addFilePresenter(presenter)
                    }
                case .failure(let error):
                    self.status = "暂未完成同步，本机规则可继续使用"
                    self.issue = (error as? ListenerError)?.message ?? "同步文件暂不可用，请检查 iCloud Drive 下载、网络和文件夹权限后重试。"
                }
                self.onRulesChanged?()
                if self.pending {
                    self.pending = false
                    self.request()
                }
            }
        }
    }
}
