import Darwin
import Foundation

struct ReminderRuleSyncResult {
    var folder: URL
    var conflicts: Int
    var exceedsLimit: Bool
    var cloud: Bool
    var uploaded: Bool
}

/// All folder access is explicit and coordinated. Every replica owns a different file; no shared last-writer-wins file.
final class ReminderRuleSyncWorker: @unchecked Sendable {
    static let directoryName = "微迹提醒规则"
    private let paths: AppPaths
    private let lock = NSLock()
    private var activeCoordinator: NSFileCoordinator?
    private var presenter: NSFilePresenter?
    func setPresenter(_ value: NSFilePresenter?) {
        lock.lock()
        presenter = value
        lock.unlock()
    }
    init(paths: AppPaths) { self.paths = paths }
    func cancel() {
        lock.lock()
        let coordinator = activeCoordinator
        lock.unlock()
        coordinator?.cancel()
    }
    private func check(_ work: BackgroundWorkToken) throws {
        if work.isCancelled { throw CancellationError() }
    }
    private func coordinated<T>(_ url: URL, writing: Bool = false, work: BackgroundWorkToken, action: (URL) throws -> T)
        throws -> T
    {
        try check(work)
        lock.lock()
        let owner = presenter
        lock.unlock()
        let coordinator = NSFileCoordinator(filePresenter: owner)
        lock.lock()
        activeCoordinator = coordinator
        lock.unlock()
        defer {
            lock.lock()
            activeCoordinator = nil
            lock.unlock()
        }
        var error: NSError?
        var result: Result<T, Error>?
        let access: (URL) -> Void = { target in
            result = Result {
                try self.check(work)
                return try action(target)
            }
        }
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &error, byAccessor: access)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error, byAccessor: access)
        }
        if let error { throw error }
        guard let result else { throw CancellationError() }
        return try result.get()
    }
    private func read(_ url: URL) throws -> ReminderRuleSyncDocument {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey, .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ])
        if values.isUbiquitousItem == true, let status = values.ubiquitousItemDownloadingStatus, status != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw ListenerError("正在等待 iCloud Drive 下载最新规则，下载完成后会自动重试。")
        }
        guard values.isSymbolicLink != true, values.isDirectory != true,
            let size = values.fileSize, size <= ReminderRuleSyncDocument.maximumBytes
        else {
            throw ListenerError("同步文件格式或大小无效，未覆盖本机规则。")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= ReminderRuleSyncDocument.maximumBytes else { throw ListenerError("同步文件过大。") }
        let document = try JSONDecoder().decode(ReminderRuleSyncDocument.self, from: data)
        try document.validate()
        return document
    }
    private func logicalURL(_ url: URL) -> URL? {
        var name = url.lastPathComponent
        if name.hasPrefix(".weiji-rules-") && name.hasSuffix(".json.icloud") {
            name = String(name.dropFirst().dropLast(7))
        }
        guard name.hasPrefix("weiji-rules-"), name.hasSuffix(".json"),
            UUID(uuidString: String(name.dropFirst(12).dropLast(5))) != nil
        else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }
    func exchange(folder: URL, work: BackgroundWorkToken = BackgroundWorkToken()) throws -> ReminderRuleSyncResult {
        try check(work)
        let scope = folder.startAccessingSecurityScopedResource()
        defer { if scope { folder.stopAccessingSecurityScopedResource() } }
        guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ListenerError("同步文件夹不可用，请重新选择 iCloud Drive 文件夹。")
        }
        let root = folder.appendingPathComponent(Self.directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try coordinated(root, writing: true, work: work) { target in
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        let attributes = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard attributes.isSymbolicLink != true, attributes.isDirectory == true else {
            throw ListenerError("同步文件夹必须是普通目录，不能是符号链接。")
        }
        let store = ReminderRuleStore(paths: paths)
        var snapshot = try store.enableSync(work: work)
        var combined = snapshot.sync!.document
        let files = try coordinated(root, work: work) { target in
            Array(
                Set(
                    try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).compactMap(
                        self.logicalURL)))
        }
        guard files.count <= ReminderRuleSyncDocument.maximumDevices else { throw ListenerError("同步设备文件过多，请检查所选文件夹。") }
        var resolved: [NSFileVersion] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try coordinated(file, work: work) { target in
                try combined.merge(read(target))
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: target) ?? [] {
                    try combined.merge(read(version.url))
                    resolved.append(version)
                }
            }
        }
        try check(work)
        snapshot = try store.mergeSync(combined, work: work)
        let destination = root.appendingPathComponent("weiji-rules-\(snapshot.sync!.deviceID.uuidString).json")
        let unchanged =
            FileManager.default.fileExists(atPath: destination.path)
            ? try coordinated(destination, work: work) { try read($0) == snapshot.sync!.document } : false
        if !unchanged {
            try coordinated(destination, writing: true, work: work) { target in
                // Re-read this replica's current file under coordination, including a cloned installation's writes.
                if FileManager.default.fileExists(atPath: target.path) {
                    try combined.merge(read(target))
                }
                snapshot = try store.mergeSync(combined, work: work)
                let data = try jsonData(snapshot.sync!.document)
                guard data.count <= ReminderRuleSyncDocument.maximumBytes else { throw ListenerError("同步文件已达到容量上限。") }
                if FileManager.default.fileExists(atPath: target.path),
                    try Data(contentsOf: target, options: .mappedIfSafe) == data
                {
                    return
                }
                try check(work)
                let temporary = target.deletingLastPathComponent().appendingPathComponent(".weiji-sync-\(UUID()).tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard
                    FileManager.default.createFile(
                        atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else {
                    throw ListenerError("无法保存同步规则。")
                }
                try data.write(to: temporary)
                try check(work)
                guard rename(temporary.path, target.path) == 0 else { throw ListenerError("无法更新同步文件，请检查文件夹权限和空间。") }
            }
        }
        // A merged durable replica now retains every version before we acknowledge provider conflict files.
        try check(work)
        for version in resolved { version.isResolved = true }
        let output = snapshot.sync!.document.materialized()
        let values = try? destination.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
        return ReminderRuleSyncResult(
            folder: root,
            conflicts: output.conflicts + output.rules.filter { !$0.isEnabled && $0.name.hasSuffix("（冲突副本）") }.count,
            exceedsLimit: output.rules.count > ReminderRule.maximumRules,
            cloud: values?.isUbiquitousItem == true, uploaded: values?.ubiquitousItemIsUploaded == true)
    }
}
