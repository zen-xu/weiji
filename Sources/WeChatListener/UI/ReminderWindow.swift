import AppKit
import SwiftUI

private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ReminderWindowController: NSObject, NSWindowDelegate {
    let inbox: ReminderInbox
    var rules: () -> [ReminderRule] = { [] }
    var soundEnabled: () -> Bool = { false }
    private var synchronizing = false
    private var automaticPresentation = true
    private var wakeObserver: NSObjectProtocol?
    private var timeZoneObserver: NSObjectProtocol?
    init(inbox: ReminderInbox? = nil) {
        self.inbox = inbox ?? ReminderInbox()
        super.init()
        self.inbox.onChange = { [weak self] in self?.synchronize() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.synchronize() }
        }
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.synchronize() }
        }
    }
    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let timeZoneObserver { NotificationCenter.default.removeObserver(timeZoneObserver) }
    }
    func synchronize() {
        guard !synchronizing else { return }
        synchronizing = true
        defer { synchronizing = false }
        let due = inbox.takeDue(rules: rules())
        onCountChange?(inbox.count)
        if !due.isEmpty {
            display(due, sound: soundEnabled(), showWindow: automaticPresentation)
        } else if inbox.visibleHits.isEmpty {
            hide()
        } else {
            resize()
        }
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        if let next = inbox.nextDue {
            snoozeTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, next.timeIntervalSinceNow), repeats: false) {
                [weak self] _ in
                Task { @MainActor in self?.synchronize() }
            }
            snoozeTimer?.tolerance = 1
        }
    }
    func shutDown() {
        hide()
        snoozeTimer?.invalidate()
        inbox.flush()
    }
    private(set) var panel: NSPanel?
    private var lastSound = Date.distantPast
    private var snoozeTimer: Timer?
    private var inWindowsMenu = false
    var snoozedUntil: Date? { inbox.snoozedUntil }
    var openMessage: ((Message) -> Void)?
    var onCountChange: ((Int) -> Void)?

    func present(_ hits: [ReminderHit], sound: Bool, showWindow: Bool = true) {
        guard !hits.isEmpty else { return }
        automaticPresentation = showWindow
        synchronizing = true
        inbox.append(hits, rules: rules())
        let due = inbox.takeDue(rules: rules())
        synchronizing = false
        onCountChange?(inbox.count)
        if !due.isEmpty { display(due, sound: sound, showWindow: showWindow) }
        synchronize()
    }
    private func display(_ hits: [ReminderHit], sound: Bool, showWindow: Bool) {
        if panel == nil {
            let panel = ReminderPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "微迹 · 提醒"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.isFloatingPanel = true
            panel.level = hits.allSatisfy(\.isPreview) ? .modalPanel : .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.worksWhenModal = true
            panel.collectionBehavior = [.canJoinAllSpaces]
            panel.tabbingMode = .disallowed
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            let view = ReminderPromptView(
                inbox: inbox, confirm: { [weak self] in self?.dismiss() },
                hide: { [weak self] in self?.hide() },
                snooze: { [weak self] in self?.snooze(minutes: $0) },
                expand: { [weak self] in self?.toggleExpanded() },
                openMessage: { [weak self] in self?.openMessage?($0) })
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = []
            (controller.view as? NSHostingView<ReminderPromptView>)?.sizingOptions = []
            panel.contentViewController = controller
            self.panel = panel
        }
        if let panel, !inWindowsMenu {
            NSApp.addWindowsItem(panel, title: "微迹提醒", filename: false)
            inWindowsMenu = true
        }
        resize()
        // Quiet corner prompt: no activation, Dock bounce, or automatic keyboard focus.
        if showWindow { panel?.orderFrontRegardless() }
        if sound && showWindow && Date().timeIntervalSince(lastSound) >= 5 {
            NSSound(named: "Glass")?.play()
            lastSound = Date()
        }
    }
    func showPending() {
        guard !inbox.hits.isEmpty else { return }
        inbox.reveal()
        display(inbox.hits, sound: false, showWindow: true)
    }
    func hide() { panel?.orderOut(nil) }
    func snooze(minutes: Int) {
        hide()
        inbox.snooze(until: Date().addingTimeInterval(Double(minutes * 60)))
    }
    func toggleExpanded() {
        inbox.expanded.toggle()
        resize()
    }
    private func resize() {
        guard let panel else { return }
        let visible =
            panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let preview = String((inbox.visibleHits.last?.message.body ?? "").prefix(500))
        let textHeight = (preview as NSString).boundingRect(
            with: NSSize(width: 352, height: 60), options: [.usesLineFragmentOrigin],
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ).height
        let compactHeight = 134 + min(54, max(18, ceil(textHeight)))
        let size =
            inbox.expanded
            ? NSSize(width: 480, height: min(520, visible.height - 80))
            : NSSize(width: 380, height: compactHeight)
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20, y: visible.minY + 20))
    }
    func dismiss() {
        hide()
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        inbox.clear()
        if let panel { NSApp.removeWindowsItem(panel) }
        inWindowsMenu = false
        onCountChange?(0)
        resize()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

struct ReminderPromptView: View {
    @ObservedObject var inbox: ReminderInbox
    var confirm: () -> Void
    var hide: () -> Void
    var snooze: (Int) -> Void
    var expand: () -> Void
    var openMessage: (Message) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "bell.badge.fill").foregroundStyle(AppAppearance.accent)
                Text("微迹 · 重要消息").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if inbox.count > 1 {
                    Text("\(inbox.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: expand) {
                    Image(systemName: inbox.expanded ? "chevron.up" : "chevron.down")
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(inbox.expanded ? "收起详情" : "展开提醒")
                Button(action: hide) {
                    Image(systemName: "xmark").frame(width: 20, height: 20).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("收起提醒")
            }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            if inbox.expanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(inbox.visibleHits.reversed()) { hit in
                            message(hit, compact: false)
                            Divider()
                        }
                        if inbox.overflow > 0 {
                            Text("另有 \(inbox.overflow) 条命中已归档，请在消息档案查看。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 10)
                }
            } else if let hit = inbox.visibleHits.last {
                message(hit, compact: true).padding(.horizontal, 14).padding(.vertical, 6)
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Menu("稍后") {
                    Button("5 分钟后提醒") { snooze(5) }
                    Button("15 分钟后提醒") { snooze(15) }
                    Button("1 小时后提醒") { snooze(60) }
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("全部处理", action: confirm)
                    .buttonStyle(.plain).foregroundStyle(AppAppearance.accent)
            }.font(.callout).padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            }
            .weijiAccent().accessibilityElement(children: .contain)
    }

    private func message(_ hit: ReminderHit, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(
                    [hit.message.senderDisplayName, hit.message.displayName].compactMap { $0 }.joined(separator: " · ")
                )
                .font(.subheadline.bold()).lineLimit(compact ? 1 : nil)
                if hit.isPreview { Text("预览").font(.caption).foregroundStyle(.secondary) }
            }
            Text(hit.message.body).font(.body).lineLimit(compact ? 3 : nil)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(hit.ruleNames.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !hit.isPreview {
                    Button("查看会话") { openMessage(hit.message) }.buttonStyle(.plain).font(.caption)
                        .foregroundStyle(AppAppearance.accent)
                }
            }
        }
    }
}
