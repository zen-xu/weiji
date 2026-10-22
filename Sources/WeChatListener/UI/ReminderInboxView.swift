import SwiftUI

struct ReminderInboxView: View {
    @ObservedObject var inbox: ReminderInbox
    @ObservedObject var model: AppModel
    @State private var filter = Filter.unread
    private enum Filter: String, CaseIterable {
        case unread = "未处理"
        case snoozed = "稍后"
        case handled = "已处理"
    }
    private var entries: [ReminderEntry] {
        inbox.entries.reversed().filter { entry in
            switch filter {
            case .unread: return !entry.isHandled
            case .snoozed: return !entry.isHandled && max(entry.dueAt, entry.snoozedUntil ?? .distantPast) > Date()
            case .handled: return entry.isHandled
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("提醒状态", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 300)
                Spacer()
                Button("提醒规则…") { model.onOpenReminderRules?() }
                Button("全部处理") { inbox.handle() }.disabled(inbox.count == 0)
            }.padding(20)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(
                    filter == .handled ? "还没有已处理的提醒" : filter == .snoozed ? "没有稍后提醒" : "没有待处理的提醒",
                    systemImage: filter == .handled ? "checkmark.circle" : "bell",
                    description: Text(filter == .unread ? "规则命中和 Agent 提醒会保留在这里，退出后也不会丢失。" : "提醒的处理状态会保存在本机。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    ReminderInboxRow(entry: entry, inbox: inbox, model: model)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }.listStyle(.inset)
            }
            if let issue = inbox.issue {
                InlineNotice(text: issue, isError: true) {}.padding(16)
            }
            if inbox.overflow > 0 {
                Text("另有 \(inbox.overflow) 条较早的提醒，请在消息档案中查看。")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReminderInboxRow: View {
    let entry: ReminderEntry
    @ObservedObject var inbox: ReminderInbox
    @ObservedObject var model: AppModel
    private var message: Message { entry.hit.message }
    private var due: Date { max(entry.dueAt, entry.snoozedUntil ?? .distantPast) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            LongNotificationBody(message: message, text: message.body, previewLines: 7)
            footer
            if !entry.isHandled && due > Date() {
                Label("将在 \(due.formatted(date: .abbreviated, time: .shortened)) 提醒", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(
                Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        }
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text(message.displayName).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                NotificationSourceBadge(message: message)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.receivedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
        }
    }
    private var footer: some View {
        HStack(spacing: 12) {
            if message.source != "agent_reminder" {
                Text(entry.hit.ruleNames.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("查看会话") { model.openReminderMessage(message) }.buttonStyle(.borderless)
            }
            Spacer(minLength: 8)
            if entry.isHandled {
                Label("已处理", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                Button("恢复未处理") { inbox.restore(entry.id) }.buttonStyle(.borderless)
            } else {
                Menu("稍后") {
                    ForEach([5, 15, 60], id: \.self) { minutes in
                        Button("\(minutes) 分钟后") {
                            inbox.snooze(entry.id, until: Date().addingTimeInterval(Double(minutes * 60)))
                        }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
                Button("处理完成") { inbox.handle(entry.id) }.buttonStyle(.borderless)
            }
        }.font(.caption)
    }
}

struct ReminderSidebarItem: View {
    @ObservedObject var inbox: ReminderInbox
    var body: some View {
        Label("提醒收件箱", systemImage: "bell.badge").badge(inbox.count)
    }
}
