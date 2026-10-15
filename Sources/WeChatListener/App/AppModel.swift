import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    let paths: AppPaths
    let worker: LibraryWorker
    let imageReader: LibraryWorker
    private var preparingVisibleImages = false
    let allowNotificationCapture: Bool
    @Published var page: Page = .archive
    @Published var conversations: [Conversation] = []
    @Published var messages: [Message] = []
    @Published var messageFiles: [String: [DiscoveredFile]] = [:]
    @Published var imageLinks: [String: [ImageAssociation]] = [:]
    @Published var selectedImage: ImagePreview?
    @Published var files: [DiscoveredFile] = []
    @Published var directoryImages: [DirectoryImageGroup] = []
    @Published var directoryImageSearch = "" {
        didSet {
            directoryImageOffset = 0
            scheduleDirectoryImageRefresh()
        }
    }
    @Published var directoryImageOffset = 0
    @Published var directoryImageTotal = 0
    @Published var directoryImagesLoading = false
    @Published var directoryMonitorStatus = "选择账户目录后自动探测"
    private var directoryImageRevision = 0
    private var pendingDirectoryImageRefresh: DispatchWorkItem?
    private var directoryMonitor: DirectoryMonitor?
    private var directoryMonitorRevision = 0
    private var directoryTimer: Timer?
    private var scheduledDirectoryScan: DispatchWorkItem?
    private var fileRescanPending = false
    @Published var fileSearch = "" {
        didSet {
            fileOffset = 0
            scheduleFileRefresh()
        }
    }
    @Published var fileOffset = 0
    @Published var fileTotal = 0
    @Published var fileScanBusy = false
    @Published var fileScanStatus = "尚未选择微信文件目录"
    private var fileRevision = 0
    private var pendingFileRefresh: DispatchWorkItem?
    private var lastFileScanAttempt: Date?
    @Published var stats: ArchiveStats?
    @Published var selectedID: String? {
        didSet {
            offset = 0
            refresh()
        }
    }
    @Published var search = "" {
        didSet {
            offset = 0
            scheduleRefresh()
        }
    }
    @Published var dateScope: DateScope = .all {
        didSet {
            offset = 0
            refresh()
        }
    }
    @Published var fromDate = Calendar.current.startOfDay(for: Date()) {
        didSet {
            offset = 0
            refresh()
        }
    }
    @Published var toDate = Date() {
        didSet {
            offset = 0
            refresh()
        }
    }
    @Published var total = 0
    @Published var offset = 0
    @Published var isCollecting = false
    @Published var pollBusy = false
    @Published var isWorking = false
    @Published var loading = false
    @Published var statusText = "已暂停采集"
    @Published var lastPoll: Date?
    @Published var sourceRows = 0
    @Published var capturedThisRun = 0
    @Published var updatedThisRun = 0
    @Published var parseErrors = 0
    @Published var errorText: String?
    @Published var feedback: String?
    @Published var preferences: Preferences
    @Published var ftsAvailable = false
    private var timer: Timer?
    private var revision = 0
    private var pendingRefresh: DispatchWorkItem?
    var onStatusChange: (() -> Void)?
    let pageSize = 100

    init(paths: AppPaths, allowNotificationCapture: Bool = true) {
        self.paths = paths
        self.allowNotificationCapture = allowNotificationCapture
        worker = LibraryWorker(paths: paths)
        imageReader = LibraryWorker(paths: paths, readOnly: true)
        preferences = Preferences.load(paths)
    }
    var selected: Conversation? { conversations.first { $0.id == selectedID } }
    var filter: MessageFilter {
        var result = MessageFilter(query: search, conversation: selectedID, limit: pageSize, offset: offset)
        let calendar = Calendar.current
        switch dateScope {
        case .all: break
        case .today: result.from = Dates.string(calendar.startOfDay(for: Date()))
        case .week:
            result.from = Dates.string(calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))!)
        case .custom:
            result.from = Dates.string(calendar.startOfDay(for: fromDate))
            result.before = Dates.string(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: toDate))!)
        }
        return result
    }
    func startUp() {
        refresh()
        refreshFiles()
        startDirectoryMonitoring()
        if allowNotificationCapture {
            if preferences.collectOnLaunch { start() } else { poll(oneShot: true) }
        }
    }
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    func refresh() {
        revision += 1
        let token = revision
        let filter = self.filter
        loading = true
        worker.perform { archive in
            let messages = try archive.messages(filter)
            var links = [String: [DiscoveredFile]]()
            var images = [String: [ImageAssociation]]()
            for message in messages {
                if let name = message.notifiedFileName {
                    links[message.id] = try archive.discoveredFiles(name: name, limit: 20)
                }
                if message.deliveredAt != nil && message.mediaDirectoryID != nil {
                    images[message.id] = try archive.imageAssociations(for: message)
                }
            }
            return (
                conversations: try archive.conversations(), messages: messages, total: try archive.count(filter),
                stats: try archive.stats(), hasFTS: archive.hasFTS, fileCandidates: links, imageAssociations: images
            )
        } completion: { [weak self] result in
            guard let self, self.revision == token else { return }
            self.loading = false
            switch result {
            case .success(let value):
                self.conversations = value.conversations
                self.messages = value.messages
                self.total = value.total
                self.stats = value.stats
                self.ftsAvailable = value.hasFTS
                self.messageFiles = value.fileCandidates
                self.imageLinks = value.imageAssociations
                if self.lastPoll == nil {
                    self.saveRuntime(
                        self.statusText == "通知读取受阻" ? "blocked" : (self.isCollecting ? "starting" : "paused"))
                }
            case .failure(let error): self.errorText = error.localizedDescription
            }
        }
    }
    func paginate(_ direction: Int) {
        offset = max(0, offset + direction * pageSize)
        refresh()
    }
    func toggleCollection() { isCollecting ? stop() : start() }
    func start() {
        guard allowNotificationCapture else {
            feedback = "演示模式只读取合成档案"
            return
        }
        guard !isCollecting else { return }
        errorText = nil
        isCollecting = true
        statusText = "正在检查通知访问权限…"
        timer = Timer.scheduledTimer(withTimeInterval: Double(max(1, preferences.pollSeconds)), repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        paths.log("capture_started")
        onStatusChange?()
        poll()
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        isCollecting = false
        statusText = pollBusy ? "暂停中，正在完成本轮读取…" : "已暂停采集"
        paths.log("capture_paused")
        saveRuntime("paused")
        onStatusChange?()
    }
    func poll(oneShot: Bool = false) {
        guard allowNotificationCapture, isCollecting || oneShot, !pollBusy else { return }
        pollBusy = true
        if oneShot && !isCollecting { statusText = "正在补扫系统保留的微信通知…" }
        let source = paths.source
        worker.perform { archive in
            try NotificationSource(url: source).capture(to: archive)
        } completion: { [weak self] result in
            guard let self else { return }
            self.pollBusy = false
            switch result {
            case .success(let value):
                self.lastPoll = Date()
                self.sourceRows = value.sourceRows
                self.capturedThisRun += value.inserted
                self.updatedThisRun += value.updated
                self.parseErrors = value.failed
                self.statusText = self.isCollecting ? "正在采集微信通知" : "已暂停采集"
                if value.journalError {
                    self.errorText = "消息已保存在数据库，但结构化事件日志暂未同步。请检查剩余磁盘空间。"
                } else if value.failed > 0 {
                    self.errorText = "本轮有 \(value.failed) 条通知未能解析或保存，请查看采集状态；这些记录会在后续轮次重试。"
                }
                self.saveRuntime(self.isCollecting ? "collecting" : "paused")
                if oneShot {
                    self.feedback =
                        "历史补扫完成：检查系统保留的 \(value.sourceRows) 条通知，新增 \(value.inserted) 条，更新 \(value.updated) 条。"
                }
                if value.inserted > 0 || value.updated > 0 { self.refresh() }
            case .failure(let error):
                self.stop()
                self.statusText = "通知读取受阻"
                self.errorText = error.localizedDescription
                self.paths.log("capture_read_failed")
                self.saveRuntime("blocked")
            }
            self.onStatusChange?()
        }
    }
    func saveRuntime(_ state: String) {
        let payload: [String: Any] = [
            "state": state, "pid": ProcessInfo.processInfo.processIdentifier,
            "updated_at": Dates.string(Date()), "last_poll_at": lastPoll.map(Dates.string) ?? "",
            "source_rows": sourceRows, "parse_errors": parseErrors, "poll_seconds": preferences.pollSeconds,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            let url = paths.root.appendingPathComponent("runtime.json")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
    func savePreferences() {
        do { try preferences.save(paths) } catch { errorText = error.localizedDescription }
    }
    func showPrivacy() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    func revealData() { NSWorkspace.shared.open(paths.root) }
    func revealApplication() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        feedback = "已复制到剪贴板"
    }
    func chooseFileDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择微信账号目录或 msg/file 文件夹"
        panel.message = "只读探测文件，解码已关联图片并在本机缓存预览；不读取聊天数据库。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if let directory = preferences.fileDirectory { panel.directoryURL = URL(fileURLWithPath: directory) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            preferences.fileDirectory = try FileDiscovery.directory(url).path
            savePreferences()
            fileOffset = 0
            directoryImageOffset = 0
            startDirectoryMonitoring()
        } catch { fileScanStatus = error.localizedDescription }
    }
    func scanFiles() {
        guard let directory = preferences.fileDirectory else { return }
        guard !fileScanBusy else {
            fileRescanPending = true
            return
        }
        fileScanBusy = true
        lastFileScanAttempt = Date()
        fileScanStatus = "正在探测本地文件…"
        worker.perform { archive in
            let files = try archive.scanFiles(in: URL(fileURLWithPath: directory))
            let images = try archive.scanImageAssociations(fileRoot: URL(fileURLWithPath: files.root))
            let previews = try archive.prepareImagePreviews()
            return (files: files, images: images, previews: previews)
        } completion: { [weak self] result in
            guard let self else { return }
            self.fileScanBusy = false
            switch result {
            case .success(let value):
                self.fileScanStatus =
                    "\(value.files.complete && value.images.complete ? "扫描完成" : "部分扫描") · \(value.files.files) 个普通文件 · \(value.images.files) 个图片文件 · \(value.previews["ready"] ?? 0) 个预览"
                self.refreshFiles()
                self.refresh()
                if self.page == .images { self.refreshDirectoryImages() }
            case .failure(let error): self.fileScanStatus = error.localizedDescription
            }
            if self.fileRescanPending {
                self.fileRescanPending = false
                self.scheduleDirectoryScan()
            }
        }
    }
    func startDirectoryMonitoring() {
        stopDirectoryMonitoring()
        guard let selected = preferences.fileDirectory else {
            directoryMonitorStatus = "选择账户目录后自动探测"
            return
        }
        let revision = directoryMonitorRevision
        directoryMonitorStatus = "自动补扫中 · 正在建立目录监听"
        directoryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanFiles() }
        }
        scanFiles()
        // FSEvents can wait on a protected or unavailable volume. Never block the app's main thread on it.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let root = try FileDiscovery.directory(URL(fileURLWithPath: selected))
                let observer = try DirectoryMonitor(fileRoot: root) { [weak self] in
                    DispatchQueue.main.async { self?.scheduleDirectoryScan() }
                }
                DispatchQueue.main.async {
                    guard let self, self.directoryMonitorRevision == revision else {
                        observer.stop()
                        return
                    }
                    self.directoryMonitor = observer
                    self.directoryMonitorStatus = "自动监听中 · 每 15 秒补扫"
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.directoryMonitorRevision == revision else { return }
                    self.directoryMonitorStatus = "自动补扫中 · 每 15 秒更新"
                }
            }
        }
    }
    func stopDirectoryMonitoring() {
        directoryMonitorRevision += 1
        directoryMonitor?.stop()
        directoryMonitor = nil
        directoryTimer?.invalidate()
        directoryTimer = nil
        scheduledDirectoryScan?.cancel()
        scheduledDirectoryScan = nil
        fileRescanPending = false
    }
    func scheduleDirectoryScan() {
        scheduledDirectoryScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanFiles() }
        scheduledDirectoryScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
    func scheduleDirectoryImageRefresh() {
        directoryImageRevision += 1
        pendingDirectoryImageRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshDirectoryImages() }
        pendingDirectoryImageRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func refreshDirectoryImages() {
        pendingDirectoryImageRefresh?.cancel()
        pendingDirectoryImageRefresh = nil
        directoryImageRevision += 1
        let revision = directoryImageRevision
        let query = directoryImageSearch
        let offset = directoryImageOffset
        directoryImagesLoading = true
        // Reading cached gallery rows must not wait for a scan of the source directory.
        imageReader.perform { archive in
            (
                groups: try archive.directoryImageGroups(query: query, offset: offset),
                total: try archive.directoryImageGroupCount(query: query)
            )
        } completion: { [weak self] result in
            guard let self, self.directoryImageRevision == revision else { return }
            self.directoryImagesLoading = false
            switch result {
            case .success(let value):
                self.directoryImages = value.groups
                self.directoryImageTotal = value.total
                let pending = value.groups.flatMap { $0.versions }.filter {
                    $0.preview == nil || $0.preview?.state == "pending"
                }.map { $0.file.id }
                self.prepareVisibleImages(Array(pending.prefix(100)))
            case .failure(let error): self.fileScanStatus = error.localizedDescription
            }
        }
    }
    func prepareVisibleImages(_ ids: [String]) {
        guard !preparingVisibleImages, !ids.isEmpty else { return }
        preparingVisibleImages = true
        worker.perform {
            try $0.prepareImagePreviews(limit: 20, fileIDs: ids)
        } completion: { [weak self] result in
            guard let self else { return }
            self.preparingVisibleImages = false
            switch result {
            case .success: if self.page == .images { self.refreshDirectoryImages() }
            case .failure(let error): self.fileScanStatus = error.localizedDescription
            }
        }
    }
    func paginateDirectoryImages(_ direction: Int) {
        directoryImageOffset = max(0, directoryImageOffset + direction * 60)
        refreshDirectoryImages()
    }
    func scheduleFileRefresh() {
        fileRevision += 1
        pendingFileRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshFiles() }
        pendingFileRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func refreshFiles() {
        pendingFileRefresh?.cancel()
        pendingFileRefresh = nil
        fileRevision += 1
        let revision = fileRevision
        let query = fileSearch
        let offset = fileOffset
        worker.perform {
            (
                files: try $0.discoveredFiles(query: query, limit: 100, offset: offset),
                total: try $0.discoveredFileCount(query: query), scanInfo: try $0.fileScanInfo()
            )
        } completion: { [weak self] result in
            guard let self, self.fileRevision == revision else { return }
            switch result {
            case .success(let value):
                self.files = value.files
                self.fileTotal = value.total
                if self.lastFileScanAttempt == nil, let at = value.scanInfo["scanned_at"] as? String,
                    let date = Dates.parse(at)
                {
                    self.fileScanStatus = "上次扫描：\(date.formatted(date: .abbreviated, time: .standard))"
                }
            case .failure(let error): self.fileScanStatus = error.localizedDescription
            }
        }
    }
    func paginateFiles(_ direction: Int) {
        fileOffset = max(0, fileOffset + direction * 100)
        refreshFiles()
    }
    func openFile(_ file: DiscoveredFile, reveal: Bool = false) {
        do {
            let url = try file.url()
            guard FileManager.default.fileExists(atPath: url.path) else { throw ListenerError("文件已移动或删除，请重新扫描目录。") }
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else if !NSWorkspace.shared.open(url) {
                throw ListenerError("系统无法打开该文件，可在 Finder 中选择应用打开。")
            }
        } catch { errorText = error.localizedDescription }
    }
    var mcpCommand: String {
        let executable = Bundle.main.executableURL?.path ?? "WeChatListener"
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        var command = "codex mcp add wechat-listener -- " + quote(executable) + " mcp"
        if paths.root.path != AppPaths().root.path { command += " --data-dir " + quote(paths.root.path) }
        return command
    }
    func importArchive() {
        let panel = NSOpenPanel()
        panel.title = "导入通知 JSONL 或旧版验证数据文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        worker.perform {
            try $0.importJSONL(from: url)
        } completion: { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            switch result {
            case .success(let value):
                self.feedback = "导入完成：新增 \(value.inserted)，更新 \(value.updated)，跳过 \(value.unchanged)，失败 \(value.failed)"
                self.refresh()
            case .failure(let error): self.errorText = error.localizedDescription
            }
        }
    }
    func exportArchive(markdown: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "微信通知-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
            + (markdown ? ".md" : ".jsonl")
        panel.directoryURL = paths.exports
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let filter = self.filter
        isWorking = true
        worker.perform {
            try $0.export(to: url, filter: filter, markdown: markdown)
        } completion: { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            switch result {
            case .success(let count):
                self.feedback = "已导出 \(count) 条通知"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error): self.errorText = error.localizedDescription
            }
        }
    }
    func backup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "微信通知备份-\(Int(Date().timeIntervalSince1970)).sqlite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isWorking = true
        worker.perform {
            try $0.database.backup(to: url)
        } completion: { [weak self] result in
            self?.isWorking = false
            switch result {
            case .success: self?.feedback = "数据库备份完成"
            case .failure(let error): self?.errorText = error.localizedDescription
            }
        }
    }
    func clearArchive() {
        let alert = NSAlert()
        alert.messageText = "清空本机通知档案？"
        alert.informativeText = "删除本应用保存的消息、图片预览缓存、文件索引和事件日志，不修改微信、系统通知、原文件或已导出的文件。此操作无法撤销，请先备份。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空档案")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        stop()
        stopDirectoryMonitoring()
        directoryMonitorStatus = "档案已清空，重启后重新探测"
        isWorking = true
        worker.perform {
            try $0.clear()
        } completion: { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            switch result {
            case .success:
                self.selectedID = nil
                self.refreshFiles()
                self.refreshDirectoryImages()
                self.feedback = "本机档案已清空；再次采集时，系统仍保留的通知可能重新入库。"
                self.refresh()
            case .failure(let error): self.errorText = error.localizedDescription
            }
        }
    }
}
