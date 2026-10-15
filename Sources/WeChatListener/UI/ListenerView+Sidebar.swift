import SwiftUI

extension ListenerView {
    var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: sidebarSelection) {
                Section("资料库") {
                    Label("所有通知", systemImage: "tray").tag(SidebarSelection.page(.archive))
                    Label("微信文件", systemImage: "folder").tag(SidebarSelection.page(.files))
                    Label("目录图片", systemImage: "photo.on.rectangle").tag(SidebarSelection.page(.images))
                }
                Section("工具") {
                    Label("采集状态", systemImage: "waveform.path").tag(SidebarSelection.page(.overview))
                    Label("连接 Codex", systemImage: "point.3.connected.trianglepath.dotted").tag(
                        SidebarSelection.page(.mcp))
                }
                Section("会话") {
                    ForEach(model.conversations) { conversation in
                        HStack(spacing: 8) {
                            Label(
                                conversation.displayName,
                                systemImage: conversation.showsGroupIcon ? "person.2" : "bubble.left"
                            )
                            .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(conversation.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(
                                .secondary)
                        }
                        .help(conversation.kindLabel + " · " + conversation.displayName)
                        .tag(SidebarSelection.conversation(conversation.id))
                    }
                    if model.conversations.isEmpty {
                        Text("尚无会话").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            AppBottomBar(horizontalPadding: 12) {
                Image(systemName: model.isCollecting ? "record.circle" : "pause.circle").foregroundStyle(.secondary)
                Text(model.isCollecting ? "正在采集" : "采集已暂停").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: model.openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("设置…（⌘,）").accessibilityLabel("设置")
            }
        }
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
