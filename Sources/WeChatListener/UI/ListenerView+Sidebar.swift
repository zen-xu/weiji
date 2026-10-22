import SwiftUI

extension ListenerView {
    var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                Section("资料库") {
                    ReminderSidebarItem(inbox: model.reminderInbox).tag(SidebarSelection.page(.reminders))
                    Label("所有通知", systemImage: "tray").tag(SidebarSelection.page(.archive))
                    Label("微信文件", systemImage: "folder").tag(SidebarSelection.page(.files))
                    Label("目录图片", systemImage: "photo.on.rectangle").tag(SidebarSelection.page(.images))
                }
                Section("工具") {
                    Label("采集状态", systemImage: "waveform.path").tag(SidebarSelection.page(.overview))
                    Label("API 与 Agent", systemImage: "point.3.connected.trianglepath.dotted").tag(
                        SidebarSelection.page(.mcp))
                }
                ForEach(NotificationPlatform.allCases) { platform in
                    conversationSection(platform)
                }
            }
            .listStyle(.sidebar)
            AppBottomBar(horizontalPadding: 12) {
                Image(
                    systemName: model.statusText == "通知读取受阻"
                        ? "exclamationmark.circle" : model.isCollecting ? "record.circle" : "pause.circle"
                )
                .foregroundStyle(
                    model.statusText == "通知读取受阻"
                        ? Color.orange : model.isCollecting ? AppAppearance.accent : Color.secondary
                )
                .accessibilityHidden(true)
                Text(model.statusText == "通知读取受阻" ? "通知读取受阻" : model.isCollecting ? "正在采集" : "采集已暂停")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(model.statusText)
                Spacer(minLength: 0)
                Button(action: model.openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("设置…（⌘,）").accessibilityLabel("设置")
            }
        }
    }

    private func conversationSection(_ platform: NotificationPlatform) -> some View {
        let conversations = model.conversations.filter { $0.platform == platform }
        return Section(platform.name + "会话") {
            ForEach(conversations) { conversation in
                conversationRow(conversation)
                    .tag(SidebarSelection.conversation(conversation.id))
            }
            if conversations.isEmpty {
                Text("暂无" + platform.name + "通知会话").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        HStack(spacing: 8) {
            Label(
                conversation.displayName,
                systemImage: conversation.showsGroupIcon ? "person.2" : "bubble.left"
            )
            .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(conversation.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .help(conversation.platform.name + " · " + conversation.kindLabel + " · " + conversation.displayName)
        .accessibilityElement(children: .combine)
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: {
                if model.page == .archive, let id = model.selectedID { return .conversation(id) }
                return .page(model.page)
            },
            set: { selection in
                guard let selection else { return }
                switch selection {
                case .conversation(let id):
                    model.page = .archive
                    model.selectedID = id
                case .page(let page):
                    model.page = page
                    if page == .archive { model.selectedID = nil }
                    if page == .files { model.refreshFiles() }
                    if page == .images { model.refreshDirectoryImages() }
                }
            })
    }
}
