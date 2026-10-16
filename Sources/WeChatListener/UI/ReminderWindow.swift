import AppKit
import SwiftUI

private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ReminderInbox: ObservableObject {
    @Published private(set) var hits: [ReminderHit] = []
    @Published private(set) var overflow = 0
    @Published var expanded = false
    var count: Int { hits.count + overflow }

    func append(_ incoming: [ReminderHit]) {
        for hit in incoming {
            if let index = hits.firstIndex(where: { $0.id == hit.id }) {
                for name in hit.ruleNames where !hits[index].ruleNames.contains(name) {
                    hits[index].ruleNames.append(name)
                }
            } else if hits.count < 200 {
                hits.append(hit)
            } else {
                overflow += 1
            }
        }
    }
    func clear() {
        hits = []
        overflow = 0
        expanded = false
    }
}

@MainActor
final class ReminderWindowController: NSObject, NSWindowDelegate {
    let inbox = ReminderInbox()
    private(set) var panel: NSPanel?
    private var lastSound = Date.distantPast
    private var snoozeTimer: Timer?
    private var inWindowsMenu = false
    private(set) var snoozedUntil: Date?
    var openMessage: ((Message) -> Void)?
    var onCountChange: ((Int) -> Void)?

    func present(_ hits: [ReminderHit], sound: Bool, showWindow: Bool = true) {
        guard !hits.isEmpty else { return }
        inbox.append(hits)
        onCountChange?(inbox.count)
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
        if showWindow && snoozedUntil == nil { panel?.orderFrontRegardless() }
        if sound && showWindow && snoozedUntil == nil && Date().timeIntervalSince(lastSound) >= 5 {
            NSSound(named: "Glass")?.play()
            lastSound = Date()
        }
    }
    func showPending() {
        guard !inbox.hits.isEmpty else { return }
        snoozeTimer?.invalidate()
        snoozedUntil = nil
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil) }
    func snooze(minutes: Int) {
        hide()
        snoozeTimer?.invalidate()
        snoozedUntil = Date().addingTimeInterval(Double(minutes * 60))
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes * 60), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.showPending() }
        }
        snoozeTimer?.tolerance = 1
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
        let preview = String((inbox.hits.last?.message.body ?? "").prefix(500))
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
        snoozedUntil = nil
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
                        ForEach(inbox.hits.reversed()) { hit in
                            message(hit, compact: false)
                            Divider()
                        }
                        if inbox.overflow > 0 {
                            Text("另有 \(inbox.overflow) 条命中已归档，请在消息档案查看。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 10)
                }
            } else if let hit = inbox.hits.last {
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
                Button("全部已读", action: confirm)
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
