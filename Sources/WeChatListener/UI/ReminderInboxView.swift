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
                    description: Text(filter == .unread ? "命中规则的重要消息会保留在这里，退出后也不会丢失。" : "提醒的处理状态会保存在本机。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.hit.message.displayName).font(.headline).lineLimit(1)
                            Spacer()
                            Text(entry.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.hit.message.body).lineLimit(5).textSelection(.enabled)
                        HStack {
                            Text(entry.hit.ruleNames.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button("查看会话") { model.openReminderMessage(entry.hit.message) }.buttonStyle(.borderless)
                            if entry.isHandled {
                                Button("恢复未处理") { inbox.restore(entry.id) }.buttonStyle(.borderless)
                            } else {
                                Menu("稍后") {
                                    ForEach([5, 15, 60], id: \.self) { minutes in
                                        Button("\(minutes) 分钟后") {
                                            inbox.snooze(
                                                entry.id, until: Date().addingTimeInterval(Double(minutes * 60)))
                                        }
                                    }
                                }.menuStyle(.borderlessButton).fixedSize()
                                Button("处理完成") { inbox.handle(entry.id) }.buttonStyle(.borderless)
                            }
                        }
                        let due = max(entry.dueAt, entry.snoozedUntil ?? .distantPast)
                        if !entry.isHandled && due > Date() {
                            Label("将在 \(due.formatted(date: .abbreviated, time: .shortened)) 提醒", systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 10)
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

struct ReminderSidebarItem: View {
    @ObservedObject var inbox: ReminderInbox
    var body: some View {
        Label("提醒收件箱", systemImage: "bell.badge").badge(inbox.count)
    }
}
