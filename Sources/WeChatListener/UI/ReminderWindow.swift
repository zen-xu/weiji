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
            if let panel, inWindowsMenu {
                NSApp.removeWindowsItem(panel)
                inWindowsMenu = false
            }
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
    var openInbox: (() -> Void)?
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
                openMessage: { [weak self] in self?.openMessage?($0) },
                readFull: { [weak self] in self?.openInbox?() })
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
        let hits = inbox.compactHits
        let rowsHeight = hits.reduce(CGFloat(0)) { total, hit in
            let preview = String(hit.message.body.prefix(500))
            let textHeight = (preview as NSString).boundingRect(
                with: NSSize(width: 352, height: 60), options: [.usesLineFragmentOrigin],
                attributes: [.font: NSFont.systemFont(ofSize: 13)]
            ).height
            return total + 54 + min(54, max(18, ceil(textHeight)))
        }
        let hiddenCount = max(0, inbox.visibleHits.count - hits.count)
        let compactHeight =
            80 + rowsHeight + CGFloat(max(0, hits.count - 1)) * 16
            + (hiddenCount > 0 ? 24 : 0)
        let availableHeight = max(180, visible.height - 80)
        let size =
            inbox.expanded
            ? NSSize(width: 480, height: min(520, availableHeight))
            : NSSize(width: 380, height: min(compactHeight, availableHeight))
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20, y: visible.minY + 20))
    }
    func dismiss() {
        hide()
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        inbox.dismissPrompt()
        if let panel { NSApp.removeWindowsItem(panel) }
        inWindowsMenu = false
        onCountChange?(inbox.count)
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
    var readFull: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "bell.badge.fill").foregroundStyle(AppAppearance.accent)
                Text("微迹 · 重要消息").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if inbox.visibleHits.count > 1 {
                    Text("\(inbox.visibleHits.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
            } else {
                compactMessages
                let remaining = inbox.visibleHits.count - inbox.compactHits.count
                if remaining > 0 {
                    Button("还有 \(remaining) 条，展开查看", action: expand)
                        .buttonStyle(.plain).font(.caption).foregroundStyle(AppAppearance.accent)
                        .padding(.horizontal, 14).padding(.bottom, 6)
                }
            }
            HStack(spacing: 12) {
                Menu("稍后") {
                    Button("5 分钟后提醒") { snooze(5) }
                    Button("15 分钟后提醒") { snooze(15) }
                    Button("1 小时后提醒") { snooze(60) }
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("全部查收", action: confirm)
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

    private var compactMessages: some View {
        let hits = inbox.compactHits
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(hits) { hit in
                    message(hit, compact: true)
                    if hit.id != hits.last?.id { Divider().padding(.vertical, 3) }
                }
            }.padding(.horizontal, 14).padding(.vertical, 6)
        }.scrollBounceBehavior(.basedOnSize)
    }

    private func message(_ hit: ReminderHit, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(hit.message.displayName).font(.system(size: 13, weight: .semibold))
                    .lineLimit(compact ? 1 : nil)
                if compact { NotificationSourceBadge(message: hit.message) }
                if hit.isPreview { Text("预览").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                if !hit.isPreview {
                    Toggle(
                        "已查收",
                        isOn: Binding(
                            get: { inbox.entries.first(where: { $0.id == hit.id })?.isHandled ?? false },
                            set: { received in if received { inbox.handle(hit.id) } })
                    )
                    .toggleStyle(.checkbox).controlSize(.small).font(.caption).fixedSize()
                    .help("查收这一条提醒，不再显示；可在收件箱的已处理列表找回。")
                    .accessibilityLabel("已查收：" + hit.message.displayName)
                }
            }
            if !compact {
                HStack(spacing: 7) {
                    NotificationSourceBadge(message: hit.message)
                    if let sender = hit.message.presentation.sender, sender != hit.message.displayName {
                        Text(sender).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            NotificationBody(
                text: hit.message.body, summary: hit.message.source == "agent_reminder", lineLimit: compact ? 3 : nil)
            if !compact && LongNotificationBody.needsReader(hit.message.body) {
                Button("在收件箱阅读全文", action: readFull)
                    .buttonStyle(.plain).font(.caption).foregroundStyle(AppAppearance.accent)
            }
            HStack {
                if compact && LongNotificationBody.needsReader(hit.message.body) {
                    Button("阅读全文", action: readFull).buttonStyle(.plain).font(.caption).foregroundStyle(
                        AppAppearance.accent)
                } else if hit.message.source == "agent_reminder" {
                    Text(hit.message.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(
                        .secondary)
                } else {
                    Text(hit.ruleNames.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !hit.isPreview && hit.message.source != "agent_reminder" {
                    Button("查看会话") { openMessage(hit.message) }.buttonStyle(.plain).font(.caption)
                        .foregroundStyle(AppAppearance.accent)
                }
            }
        }
    }
}
