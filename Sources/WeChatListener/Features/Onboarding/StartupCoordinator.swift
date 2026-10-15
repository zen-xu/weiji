import Foundation

@MainActor
final class StartupCoordinator: ObservableObject {
    enum Stage: Equatable {
        case checking
        case accessRequired(NotificationAccess)
        case configuration
        case ready
    }

    @Published private(set) var stage: Stage = .checking
    @Published private(set) var setupError: String?
    var onReady: (() -> Void)?
    var onStageChange: ((Stage) -> Void)?
    var isReady: Bool { stage == .ready }

    private let checkAccess: @Sendable () async -> NotificationAccess
    private let persistCompletion: @MainActor () throws -> Void
    private let demo: Bool
    private var setupCompleted: Bool
    private var checkTask: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var deliveredReady = false

    init(
        setupCompleted: Bool,
        demo: Bool = false,
        checkAccess: @escaping @Sendable () async -> NotificationAccess,
        persistCompletion: @escaping @MainActor () throws -> Void
    ) {
        self.setupCompleted = setupCompleted
        self.demo = demo
        self.checkAccess = checkAccess
        self.persistCompletion = persistCompletion
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        if demo { enterMainInterface() } else { recheck() }
    }

    func recheck() {
        guard !isReady else { return }
        check(finishingSetup: false)
    }

    func finishSetup() {
        guard stage == .configuration else { return }
        // Permission may have been revoked while the optional setup screen was open.
        check(finishingSetup: true)
    }

    func cancel() {
        stopped = true
        checkTask?.cancel()
        checkTask = nil
    }

    private func check(finishingSetup: Bool) {
        guard started, !stopped, checkTask == nil else { return }
        setupError = nil
        transition(to: .checking)
        let probe = checkAccess
        checkTask = Task { [weak self] in
            let access = await probe()
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.checkTask = nil
            guard access == .readable else {
                self.transition(to: .accessRequired(access))
                return
            }
            if finishingSetup {
                do {
                    try self.persistCompletion()
                    self.setupCompleted = true
                } catch {
                    self.setupError = "无法保存设置：" + error.localizedDescription
                    self.transition(to: .configuration)
                    return
                }
            }
            if self.setupCompleted { self.enterMainInterface() } else { self.transition(to: .configuration) }
        }
    }

    private func enterMainInterface() {
        transition(to: .ready)
        guard !deliveredReady else { return }
        deliveredReady = true
        onReady?()
    }

    private func transition(to stage: Stage) {
        guard self.stage != stage else { return }
        self.stage = stage
        onStageChange?(stage)
    }
}
