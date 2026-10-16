import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    let paths: AppPaths
    let worker: LibraryWorker
    let reader: LibraryWorker
    let imageReader: LibraryWorker
    private var preparingVisibleImages = false
    private lazy var previewPreparation = PreviewPreparation(worker: worker)
    private var directoryWork = BackgroundWorkToken()
    private var captureWork = BackgroundWorkToken()
    private let reminderProcessor = ReminderProcessor()
    private var reminderRevision = 0
    private var reminderStartedAt: Date?
    @Published var reminderIssue: String?
    @Published private(set) var reminderRules: [ReminderRule] = []
    private(set) var reminderRuleRevision = "initial"
    private var reminderFileSignature: String?
    private var reminderMonitor: Timer?
    var onReminder: (([ReminderHit], Bool) -> Void)?
    var onPreviewReminder: ((ReminderHit) -> Void)?
    var onOpenReminderRules: (() -> Void)?
    private(set) var isShuttingDown = false
    let allowNotificationCapture: Bool
    @Published var page: Page = .archive
    @Published var searchPresented = false
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
    private var scheduledDirectorySince: TimeInterval?
    private var scheduledDirectoryID: UUID?
    private var fileRescanPending = false
    @Published var fileSearch = "" {
        didSet {
            fileOffset = 0
            scheduleFileRefresh()
        }
    }
    @Published var fileOffset = 0
    @Published var fileTotal = 0
    @Published var filesLoading = false
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
            if toDate < fromDate {
                toDate = fromDate
                return
            }
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
    private var lastRuntimeSignature: String?
    private var lastRuntimeWrite: TimeInterval = 0
    private var lastRuntimeWallWrite = Date.distantPast
    @Published var mcpStatus = "服务尚未启动"
    @Published var mcpListening = false
    @Published var mcpPortText = String(MCPHTTPServer.defaultPort)
    private lazy var mcpServer = MCPHTTPServer(paths: paths)
    var onStatusChange: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    let pageSize = 100
    private(set) var hasStartedLibrary = false

    init(paths: AppPaths, allowNotificationCapture: Bool = true) {
        self.paths = paths
        self.allowNotificationCapture = allowNotificationCapture
        worker = LibraryWorker(paths: paths)
        reader = LibraryWorker(paths: paths, readOnly: true)
        imageReader = LibraryWorker(paths: paths, readOnly: true)
        preferences = Preferences.load(paths)
        mcpPortText = String(preferences.mcpPort ?? MCPHTTPServer.defaultPort)
        refreshReminderRules()
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
        guard !hasStartedLibrary, !isShuttingDown else { return }
        hasStartedLibrary = true
        loading = true
        filesLoading = true
        // Establish a new archive before any read-only connection tries to open it.
        worker.perform { _ in
            ()
        } completion: { [weak self] result in
            guard let self, !self.isShuttingDown else { return }
            switch result {
            case .success:
                self.refresh()
                self.refreshFiles()
                if self.page == .images { self.refreshDirectoryImages() }
                self.startDirectoryMonitoring()
                if self.allowNotificationCapture {
                    if self.preferences.collectOnLaunch { self.start() } else { self.poll(oneShot: true) }
                }
            case .failure(let error):
                self.loading = false
                self.filesLoading = false
                self.errorText = error.localizedDescription
            }
        }
    }
    func scheduleRefresh() {
        guard !isShuttingDown else { return }
        revision += 1
        reader.invalidate(.messages)
        loading = true
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    func refresh() {
        guard !isShuttingDown else { return }
        pendingRefresh?.cancel()
        pendingRefresh = nil
        revision += 1
        let token = revision
        let filter = self.filter
        loading = true
        reader.performLatest(.messages) { archive in
            try archive.database.readSnapshot {
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
            }
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
        guard !isShuttingDown, !isWorking else { return }
        guard allowNotificationCapture else {
            feedback = "演示模式只读取合成档案"
            return
        }
        guard !isCollecting else { return }
        errorText = nil
        isCollecting = true
        beginReminderSession()
        statusText = "正在检查通知访问权限…"
        timer = Timer.scheduledTimer(withTimeInterval: Double(max(1, preferences.pollSeconds)), repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer?.tolerance = min(1, Double(max(1, preferences.pollSeconds)) * 0.1)
        paths.log("capture_started")
        onStatusChange?()
        poll()
    }
    func stop() {
        reminderProcessor.cancelPending()
        reminderStartedAt = nil
        reminderRevision += 1
        timer?.invalidate()
        timer = nil
        isCollecting = false
        statusText = pollBusy ? "暂停中，正在完成本轮读取…" : "已暂停采集"
        paths.log("capture_paused")
        saveRuntime("paused")
        onStatusChange?()
    }
    func poll(oneShot: Bool = false) {
        guard !isShuttingDown, allowNotificationCapture, isCollecting || oneShot, !pollBusy else { return }
        pollBusy = true
        if oneShot && !isCollecting { statusText = "正在补扫系统保留的微信通知…" }
        let source = paths.source
        let work = captureWork
        let reminderSince = isCollecting && !oneShot ? reminderStartedAt : nil
        worker.perform { archive -> CaptureResult? in
            guard !work.isCancelled else { return nil }
            return try NotificationSource(url: source).capture(to: archive, reminderSince: reminderSince)
        } completion: { [weak self] result in
            guard let self else { return }
            self.pollBusy = false
            guard !work.isCancelled, !self.isShuttingDown else { return }
            switch result {
            case .success(let value):
                guard let value else { return }
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
                self.processReminderCandidates(value.reminderCandidates)
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
    func saveRuntime(_ state: String, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let signature = "\(state)|\(sourceRows)|\(parseErrors)|\(preferences.pollSeconds)"
        let now = Date()
        guard
            signature != lastRuntimeSignature || uptime - lastRuntimeWrite >= 15
                || now.timeIntervalSince(lastRuntimeWallWrite) >= 15
        else { return }
        let payload: [String: Any] = [
            "state": state, "pid": ProcessInfo.processInfo.processIdentifier,
            "updated_at": Dates.string(Date()), "last_poll_at": lastPoll.map(Dates.string) ?? "",
            "source_rows": sourceRows, "parse_errors": parseErrors, "poll_seconds": preferences.pollSeconds,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            let url = paths.root.appendingPathComponent("runtime.json")
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                lastRuntimeSignature = signature
                lastRuntimeWrite = uptime
                lastRuntimeWallWrite = now
            } catch { paths.log("runtime_status_write_failed") }
        }
    }
    func updatePreferences(_ update: (inout Preferences) -> Void) throws {
        var updated = preferences
        update(&updated)
        try updated.save(paths)
        preferences = updated
    }
    func setCollectOnLaunch(_ enabled: Bool) {
        do { try updatePreferences { $0.collectOnLaunch = enabled } } catch { errorText = error.localizedDescription }
    }
    func saveReminderRules(_ rules: [ReminderRule], expectedRevision: String? = nil) throws {
        let store = ReminderRuleStore(paths: paths)
        let snapshot = try store.save(rules, expectedRevision: expectedRevision ?? reminderRuleRevision)
        reminderRules = snapshot.rules
        reminderRuleRevision = snapshot.revision
        reminderFileSignature = try? store.signature()
        reminderRevision += 1
        reminderIssue = nil
        reminderProcessor.reset()
    }
    @discardableResult
    func refreshReminderRules() -> Bool {
        do {
            let store = ReminderRuleStore(paths: paths)
            let signature = try store.signature()
            guard signature != reminderFileSignature else { return true }
            let snapshot = try store.load()
            reminderFileSignature = signature
            if snapshot.revision != reminderRuleRevision {
                reminderRules = snapshot.rules
                reminderRuleRevision = snapshot.revision
                reminderRevision += 1
                reminderProcessor.reset()
                reminderIssue = nil
            }
            return true
        } catch {
            reminderIssue = "无法加载提醒规则，本轮暂不匹配。请检查规则文件和目录权限。"
            return false
        }
    }
    func startReminderMonitoring() {
        reminderMonitor?.invalidate()
        refreshReminderRules()
        reminderMonitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshReminderRules() }
        }
        reminderMonitor?.tolerance = 0.5
    }
    func beginReminderSession(at date: Date = Date()) {
        reminderStartedAt = date
        reminderRevision += 1
    }
    func setReminderSound(_ enabled: Bool) {
        do { try updatePreferences { $0.reminderSound = enabled } } catch { errorText = error.localizedDescription }
    }
    func processReminderCandidates(_ candidates: [Message], now: Date = Date()) {
        guard isCollecting, !isShuttingDown, let since = reminderStartedAt else { return }
        let messages = candidates.filter {
            guard let delivered = $0.deliveredAt.flatMap(Dates.parse) else { return false }
            return delivered >= since && now.timeIntervalSince(delivered) >= -60
                && now.timeIntervalSince(delivered) <= 300
        }
        guard refreshReminderRules() else { return }
        let rules = reminderRules
        guard !messages.isEmpty, rules.contains(where: \.isEnabled) else { return }
        let token = reminderRevision
        reminderProcessor.evaluate(messages, rules: rules) { [weak self] result in
            guard let self, !self.isShuttingDown, self.isCollecting, self.refreshReminderRules(),
                self.reminderRevision == token
            else { return }
            if !result.issues.isEmpty { self.reminderIssue = result.issues.joined(separator: "\n") }
            if !result.hits.isEmpty { self.onReminder?(result.hits, self.preferences.reminderSound ?? false) }
        }
    }
    func openSettings() { onOpenSettings?() }
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
    func completeStartupSetup() throws {
        try paths.prepare()
        var updated = preferences
        updated.onboardingCompleted = true
        try updated.save(paths)
        preferences = updated
    }
    func chooseFileDirectory() { chooseDirectory(startMonitoring: true) }
    func chooseStartupDirectory() { chooseDirectory(startMonitoring: false) }
    private func chooseDirectory(startMonitoring: Bool) {
        guard !isShuttingDown, !isWorking else { return }
        let panel = NSOpenPanel()
        panel.title = "选择微信账号目录或 msg/file 文件夹"
        panel.message = "只读探测文件，解码已关联图片并在本机缓存预览；不读取聊天数据库。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if let directory = preferences.fileDirectory { panel.directoryURL = URL(fileURLWithPath: directory) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let directory = try FileDiscovery.directory(url).path
            if startMonitoring {
                try selectFileDirectory(directory)
            } else {
                preferences.fileDirectory = directory
                errorText = nil
            }
        } catch {
            fileScanStatus = error.localizedDescription
            if !startMonitoring { errorText = error.localizedDescription }
        }
    }
    func selectFileDirectory(_ directory: String) throws {
        let changed = preferences.fileDirectory != directory
        try updatePreferences { $0.fileDirectory = directory }
        if changed {
            invalidateQueries()
            files = []
            fileTotal = 0
            directoryImages = []
            directoryImageTotal = 0
            messageFiles = [:]
            imageLinks = [:]
            selectedImage = nil
            filesLoading = true
            directoryImagesLoading = true
        }
        fileOffset = 0
        directoryImageOffset = 0
        startDirectoryMonitoring()
    }
    func scanFiles() {
        guard !isShuttingDown, !isWorking else { return }
        guard let directory = preferences.fileDirectory else { return }
        guard !fileScanBusy else {
            fileRescanPending = true
            return
        }
        fileScanBusy = true
        lastFileScanAttempt = Date()
        fileScanStatus = "正在探测本地文件…"
        let work = directoryWork
        worker.perform { archive -> (FileScanResult, ImageAssociationScan)? in
            guard !work.isCancelled else { return nil }
            let files = try archive.scanFiles(in: URL(fileURLWithPath: directory))
            guard !work.isCancelled else { return nil }
            let images = try archive.scanImageAssociations(fileRoot: URL(fileURLWithPath: files.root))
            guard !work.isCancelled else { return nil }
            return (files, images)
        } completion: { [weak self] result in
            guard let self else { return }
            self.fileScanBusy = false
            defer {
                if self.fileRescanPending {
                    self.fileRescanPending = false
                    self.scheduleDirectoryScan()
                }
            }
            guard !work.isCancelled, !self.isShuttingDown else { return }
            switch result {
            case .success(let value):
                guard let (files, images) = value else { return }
                self.fileScanStatus =
                    "\(files.complete && images.complete ? "扫描完成" : "部分扫描") · \(files.files) 个普通文件 · \(images.files) 个图片文件"
                self.refreshFiles()
                self.refresh()
                if self.page == .images { self.refreshDirectoryImages() }
                self.prepareRecentImages()
            case .failure(let error):
                self.fileScanStatus = error.localizedDescription
                self.filesLoading = false
                self.directoryImagesLoading = false
            }
        }
    }
    func startDirectoryMonitoring() {
        guard !isShuttingDown else { return }
        stopDirectoryMonitoring()
        guard let selected = preferences.fileDirectory else {
            directoryMonitorStatus = "选择账户目录后自动探测"
            return
        }
        let revision = directoryMonitorRevision
        let work = directoryWork
        directoryMonitorStatus = "自动补扫中 · 正在建立目录监听"
        configureDirectoryTimer(interval: 15, work: work)
        scanFiles()
        // FSEvents can wait on a protected or unavailable volume. Never block the app's main thread on it.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let root = try FileDiscovery.directory(URL(fileURLWithPath: selected))
                let observer = try DirectoryMonitor(fileRoot: root) { [weak self] in
                    DispatchQueue.main.async { if !work.isCancelled { self?.scheduleDirectoryScan() } }
                }
                DispatchQueue.main.async {
                    guard let self, self.directoryMonitorRevision == revision else {
                        observer.stop()
                        return
                    }
                    self.directoryMonitor = observer
                    self.directoryMonitorStatus = "自动监听中 · 每分钟补扫"
                    self.configureDirectoryTimer(interval: 60, work: work)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.directoryMonitorRevision == revision else { return }
                    self.directoryMonitorStatus = "自动补扫中 · 每 15 秒更新"
                }
            }
        }
    }
    private func configureDirectoryTimer(interval: TimeInterval, work: BackgroundWorkToken) {
        directoryTimer?.invalidate()
        directoryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in if !work.isCancelled { self?.scanFiles() } }
        }
        directoryTimer?.tolerance = interval / 10
    }
    func stopDirectoryMonitoring() {
        directoryWork.cancel()
        directoryWork = BackgroundWorkToken()
        directoryMonitorRevision += 1
        directoryMonitor?.stop()
        directoryMonitor = nil
        directoryTimer?.invalidate()
        directoryTimer = nil
        scheduledDirectoryScan?.cancel()
        scheduledDirectoryScan = nil
        scheduledDirectorySince = nil
        scheduledDirectoryID = nil
        fileRescanPending = false
    }
    func scheduleDirectoryScan() {
        guard !isShuttingDown, !isWorking else { return }
        scheduledDirectoryScan?.cancel()
        let token = directoryWork
        let id = UUID()
        let now = ProcessInfo.processInfo.systemUptime
        let since = scheduledDirectorySince ?? now
        scheduledDirectorySince = since
        scheduledDirectoryID = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, !token.isCancelled, self.scheduledDirectoryID == id else { return }
            self.scheduledDirectoryScan = nil
            self.scheduledDirectorySince = nil
            self.scheduledDirectoryID = nil
            self.scanFiles()
        }
        scheduledDirectoryScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(0.8, max(0, 2 - (now - since))), execute: work)
    }
    func scheduleDirectoryImageRefresh() {
        guard !isShuttingDown else { return }
        imageReader.invalidate(.gallery)
        directoryImageRevision += 1
        pendingDirectoryImageRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshDirectoryImages() }
        pendingDirectoryImageRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func refreshDirectoryImages() {
        guard !isShuttingDown else { return }
        pendingDirectoryImageRefresh?.cancel()
        pendingDirectoryImageRefresh = nil
        directoryImageRevision += 1
        let revision = directoryImageRevision
        let query = directoryImageSearch
        let offset = directoryImageOffset
        directoryImagesLoading = true
        // Reading cached gallery rows must not wait for a scan of the source directory.
        imageReader.performLatest(.gallery) { archive in
            try archive.database.readSnapshot {
                (
                    groups: try archive.directoryImageGroups(query: query, offset: offset),
                    total: try archive.directoryImageGroupCount(query: query)
                )
            }
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
        guard !isShuttingDown, !isWorking, !preparingVisibleImages, !ids.isEmpty else { return }
        preparingVisibleImages = true
        let work = directoryWork
        worker.perform {
            guard !work.isCancelled else { return [String: Int]() }
            return try $0.prepareImagePreviews(limit: 5, fileIDs: ids, shouldContinue: { !work.isCancelled })
        } completion: { [weak self] result in
            guard let self else { return }
            self.preparingVisibleImages = false
            guard !work.isCancelled, !self.isShuttingDown else { return }
            switch result {
            case .success: if self.page == .images { self.refreshDirectoryImages() }
            case .failure(let error): self.fileScanStatus = error.localizedDescription
            }
        }
    }
    private func prepareRecentImages() {
        guard !isShuttingDown, !isWorking else { return }
        previewPreparation.prepareRecent(token: directoryWork) { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            if self.page == .images { self.scheduleDirectoryImageRefresh() }
            if self.page == .archive { self.scheduleRefresh() }
        } onFailure: { [weak self] error in
            self?.fileScanStatus = error.localizedDescription
        }
    }
    func paginateDirectoryImages(_ direction: Int) {
        directoryImageOffset = max(0, directoryImageOffset + direction * 60)
        refreshDirectoryImages()
    }
    func scheduleFileRefresh() {
        guard !isShuttingDown else { return }
        reader.invalidate(.files)
        filesLoading = true
        fileRevision += 1
        pendingFileRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshFiles() }
        pendingFileRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func refreshFiles() {
        guard !isShuttingDown else { return }
        pendingFileRefresh?.cancel()
        pendingFileRefresh = nil
        fileRevision += 1
        let revision = fileRevision
        let query = fileSearch
        let offset = fileOffset
        filesLoading = true
        reader.performLatest(.files) { archive in
            try archive.database.readSnapshot {
                (
                    files: try archive.discoveredFiles(query: query, limit: 100, offset: offset),
                    total: try archive.discoveredFileCount(query: query), scanInfo: try archive.fileScanInfo()
                )
            }
        } completion: { [weak self] result in
            guard let self, self.fileRevision == revision else { return }
            self.filesLoading = false
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
    var mcpURL: String { "http://127.0.0.1:\(preferences.mcpPort ?? MCPHTTPServer.defaultPort)/mcp" }
    var mcpCommand: String { "codex mcp add wechat-listener --url \(mcpURL)" }
    var mcpConfiguration: String { "[mcp_servers.wechat-listener]\nurl = \"\(mcpURL)\"" }

    func startMCPServer() {
        let port = preferences.mcpPort ?? MCPHTTPServer.defaultPort
        mcpServer.start(port: port) { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .starting:
                    self.mcpListening = false
                    self.mcpStatus = "正在启动本地服务…"
                case .listening:
                    self.mcpListening = true
                    self.mcpStatus = "运行中"
                case .stopped:
                    self.mcpListening = false
                    self.mcpStatus = "服务已停止"
                case .failed(let message):
                    self.mcpListening = false
                    self.mcpStatus = "启动失败：\(message)。请检查端口是否被占用，或修改端口重试。"
                }
            }
        }
    }
    func stopMCPServer() { mcpServer.stop() }
    func applyMCPPort() {
        guard let port = UInt16(mcpPortText.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            errorText = "端口必须是 1…65535 的整数"
            return
        }
        do {
            var updated = preferences
            updated.mcpPort = port
            try updated.save(paths)
            preferences = updated
            mcpPortText = String(port)
            startMCPServer()
        } catch { errorText = error.localizedDescription }
    }
    func importArchive() {
        guard !isShuttingDown, !isWorking else { return }
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
        guard !isShuttingDown, !isWorking else { return }
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
        guard !isShuttingDown, !isWorking else { return }
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
        guard !isShuttingDown, !isWorking else { return }
        let alert = NSAlert()
        alert.messageText = "清空本机通知档案？"
        alert.informativeText = "删除本应用保存的消息、图片预览缓存、文件索引和事件日志，不修改微信、系统通知、原文件或已导出的文件。此操作无法撤销，请先备份。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空档案")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        clearLocalArchive()
    }
    func clearLocalArchive() {
        guard !isShuttingDown, !isWorking else { return }
        captureWork.cancel()
        captureWork = BackgroundWorkToken()
        stop()
        stopDirectoryMonitoring()
        invalidateQueries()
        selectedImage = nil
        messages = []
        conversations = []
        total = 0
        messageFiles = [:]
        imageLinks = [:]
        files = []
        fileTotal = 0
        directoryImages = []
        directoryImageTotal = 0
        lastFileScanAttempt = nil
        fileScanStatus = "档案已清空，尚未重新扫描"
        PreviewImageLoader.clearCache()
        directoryMonitorStatus = "档案已清空，重启后重新探测"
        isWorking = true
        worker.perform {
            try $0.clear()
        } completion: { [weak self] result in
            guard let self else { return }
            self.isWorking = false
            switch result {
            case .success:
                PreviewImageLoader.clearCache()
                self.selectedID = nil
                self.refreshFiles()
                self.refreshDirectoryImages()
                self.feedback = "本机档案已清空；再次采集时，系统仍保留的通知可能重新入库。"
                self.refresh()
            case .failure(let error):
                self.errorText = error.localizedDescription
                self.refresh()
                self.refreshFiles()
                self.refreshDirectoryImages()
            }
        }
    }
    private func invalidateQueries() {
        revision += 1
        fileRevision += 1
        directoryImageRevision += 1
        reader.invalidate(.messages)
        reader.invalidate(.files)
        imageReader.invalidate(.gallery)
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingFileRefresh?.cancel()
        pendingFileRefresh = nil
        pendingDirectoryImageRefresh?.cancel()
        pendingDirectoryImageRefresh = nil
        loading = false
        filesLoading = false
        directoryImagesLoading = false
    }
    func shutDown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        reminderMonitor?.invalidate()
        reminderMonitor = nil
        captureWork.cancel()
        stop()
        stopDirectoryMonitoring()
        invalidateQueries()
    }
}
