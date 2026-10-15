import Darwin
import Foundation
import Testing

@testable import WeChatListener

@Test("Notification access checks the real file and schema without importing messages")
func notificationAccessProbe() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let absent = root.appendingPathComponent("must-not-create.sqlite")
    #expect(NotificationAccessChecker.check(absent) == .missing)
    #expect(!FileManager.default.fileExists(atPath: absent.path))
    let invalid = root.appendingPathComponent("invalid.sqlite")
    try Data("Not a notification database".utf8).write(to: invalid)
    #expect(NotificationAccessChecker.check(invalid) == .unsupported)
    let source = root.appendingPathComponent("source.sqlite")
    let database = try SQLite(source.path)
    try database.run("CREATE TABLE app(app_id INTEGER PRIMARY KEY,identifier TEXT)")
    try database.run(
        "CREATE TABLE record(rec_id INTEGER PRIMARY KEY,uuid BLOB,delivered_date REAL,data BLOB,app_id INTEGER)")
    try database.run("INSERT INTO app VALUES(1,'com.tencent.xinwechat')")
    try database.run("INSERT INTO record VALUES(1,NULL,0,?,1)", [.blob(Data("NOT_A_NOTIFICATION_PAYLOAD".utf8))])
    let before = try Data(contentsOf: source)
    #expect(NotificationAccessChecker.check(source) == .readable)
    #expect(try Data(contentsOf: source) == before)
    #expect(try database.rows("SELECT COUNT(*) AS n FROM record").first?.int("n") == 1)
    try database.run("BEGIN EXCLUSIVE")
    #expect(NotificationAccessChecker.check(source) == .busy)
    try database.run("ROLLBACK")
    #expect(NotificationAccessChecker.check(source) == .readable)
    if geteuid() != 0 {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }
        #expect(NotificationAccessChecker.check(source) == .denied)
    }
    let incompatible = root.appendingPathComponent("incompatible.sqlite")
    let incompatibleDatabase = try SQLite(incompatible.path)
    try incompatibleDatabase.run("CREATE TABLE record(rec_id INTEGER PRIMARY KEY)")
    #expect(NotificationAccessChecker.check(incompatible) == .unsupported)
}

private actor AccessSequence {
    private var results: [NotificationAccess]
    private(set) var calls = 0
    init(_ results: [NotificationAccess]) { self.results = results }
    func next() -> NotificationAccess {
        calls += 1
        return results.isEmpty ? .unavailable : results.removeFirst()
    }
}

@MainActor
private func waitForStartup(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ListenerError("Timed out waiting for startup state")
}

@Test("First launch waits for access and explicit setup completion")
@MainActor
func startupAccessGate() async throws {
    let probe = AccessSequence([.denied, .readable, .readable])
    var started = 0
    var saved = 0
    let startup = StartupCoordinator(
        setupCompleted: false, checkAccess: { await probe.next() }, persistCompletion: { saved += 1 })
    startup.onReady = { started += 1 }
    #expect(startup.stage == .checking)
    startup.start()
    try await waitForStartup { startup.stage == .accessRequired(.denied) }
    #expect(started == 0 && saved == 0)
    startup.finishSetup()
    #expect(startup.stage == .accessRequired(.denied))
    startup.recheck()
    try await waitForStartup { startup.stage == .configuration }
    #expect(started == 0 && saved == 0)
    startup.finishSetup()
    try await waitForStartup { startup.isReady }
    #expect(started == 1 && saved == 1)
    #expect(await probe.calls == 3)
    startup.start()
    startup.recheck()
    #expect(started == 1 && saved == 1)
    #expect(await probe.calls == 3)
}

@Test("A saved completion flag never substitutes for a fresh access check")
@MainActor
func startupChecksReturningUsers() async throws {
    let probe = AccessSequence([.denied, .readable])
    var started = 0
    let startup = StartupCoordinator(
        setupCompleted: true, checkAccess: { await probe.next() },
        persistCompletion: { Issue.record("Unexpected setup save") })
    startup.onReady = { started += 1 }
    startup.start()
    try await waitForStartup { startup.stage == .accessRequired(.denied) }
    #expect(!startup.isReady && started == 0)
    startup.recheck()
    try await waitForStartup { startup.isReady }
    #expect(started == 1)
}

@Test("Revocation while setup is open prevents completion and capture")
@MainActor
func startupRechecksBeforeCompletion() async throws {
    let probe = AccessSequence([.readable, .denied])
    var saved = 0
    var started = 0
    let startup = StartupCoordinator(
        setupCompleted: false, checkAccess: { await probe.next() }, persistCompletion: { saved += 1 })
    startup.onReady = { started += 1 }
    startup.start()
    try await waitForStartup { startup.stage == .configuration }
    startup.finishSetup()
    try await waitForStartup { startup.stage == .accessRequired(.denied) }
    #expect(started == 0 && saved == 0)
}

@Test("Unavailable sources do not become misleading disk permission errors")
@MainActor
func startupUnavailableSources() async throws {
    for access in [NotificationAccess.missing, .busy, .unsupported, .unavailable] {
        let startup = StartupCoordinator(
            setupCompleted: true, checkAccess: { access }, persistCompletion: { Issue.record("Unexpected save") })
        startup.start()
        try await waitForStartup { startup.stage == .accessRequired(access) }
        #expect(!startup.isReady)
    }
}

@Test("Failed preference writes keep onboarding incomplete until a successful retry")
@MainActor
func startupSaveFailure() async throws {
    let probe = AccessSequence([.readable, .readable, .readable, .readable])
    var failWrite = true
    var started = 0
    let startup = StartupCoordinator(
        setupCompleted: false, checkAccess: { await probe.next() },
        persistCompletion: { if failWrite { throw ListenerError("Synthetic disk failure") } })
    startup.onReady = { started += 1 }
    startup.start()
    try await waitForStartup { startup.stage == .configuration }
    startup.finishSetup()
    try await waitForStartup { startup.setupError != nil }
    #expect(startup.stage == .configuration && started == 0)
    startup.recheck()
    try await waitForStartup { startup.stage == .configuration }
    #expect(!startup.isReady && started == 0)
    failWrite = false
    startup.finishSetup()
    try await waitForStartup { startup.isReady }
    #expect(started == 1 && startup.setupError == nil)
}

private actor DelayedAccess {
    private var continuation: CheckedContinuation<NotificationAccess, Never>?
    private(set) var calls = 0
    var waiting: Bool { continuation != nil }
    func check() async -> NotificationAccess {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func resolve(_ access: NotificationAccess) {
        continuation?.resume(returning: access)
        continuation = nil
    }
}

@Test("Repeated activation checks coalesce and late results cannot restart a cancelled app")
@MainActor
func startupCancellation() async throws {
    let probe = DelayedAccess()
    var started = 0
    let startup = StartupCoordinator(
        setupCompleted: true, checkAccess: { await probe.check() }, persistCompletion: {})
    startup.onReady = { started += 1 }
    startup.start()
    try await waitForStartup { await probe.waiting }
    startup.recheck()
    startup.recheck()
    #expect(await probe.calls == 1)
    startup.cancel()
    await probe.resolve(.readable)
    try await Task.sleep(for: .milliseconds(20))
    #expect(!startup.isReady && started == 0)
    startup.start()
    startup.recheck()
    #expect(await probe.calls == 1)
}

@Test("Demo mode uses only synthetic data and never requests actual notification access")
@MainActor
func startupDemo() async {
    let probe = AccessSequence([.denied])
    var started = 0
    let startup = StartupCoordinator(
        setupCompleted: false, demo: true, checkAccess: { await probe.next() },
        persistCompletion: { Issue.record("Demo must not persist onboarding") })
    startup.onReady = { started += 1 }
    startup.start()
    startup.start()
    #expect(startup.isReady && started == 1)
    #expect(await probe.calls == 0)
}

@Test("Onboarding preferences migrate without resetting settings or opening an archive")
@MainActor
func startupPreferenceMigration() throws {
    let old = Data(
        #"{"collectOnLaunch":true,"pollSeconds":5,"fileDirectory":"/synthetic/account","mcpPort":23456}"#.utf8)
    let previous = try JSONDecoder().decode(Preferences.self, from: old)
    #expect(previous.onboardingCompleted == nil && previous.collectOnLaunch && previous.pollSeconds == 5)
    #expect(previous.fileDirectory == "/synthetic/account" && previous.mcpPort == 23456)
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.appendingPathComponent("new-user").path)
    let model = AppModel(paths: paths)
    model.preferences = previous
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))
    try model.completeStartupSetup()
    let stored = Preferences.load(paths)
    #expect(stored.onboardingCompleted == true && stored.fileDirectory == previous.fileDirectory)
    #expect(stored.collectOnLaunch && stored.pollSeconds == 5 && stored.mcpPort == 23456)
    #expect(!model.hasStartedLibrary && !model.isCollecting)
    #expect(!FileManager.default.fileExists(atPath: paths.database.path))
    #expect(!FileManager.default.fileExists(atPath: paths.journal.path))
}
