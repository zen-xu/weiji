import AppKit
import SwiftUI

extension ListenerView {
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("微信消息监听").font(.headline)
                    Text("把收到的信息留在本机").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18)
            VStack(spacing: 4) {
                nav("所有通知", icon: "tray.full", active: model.page == .archive && model.selectedID == nil) {
                    model.page = .archive
                    model.selectedID = nil
                }
                nav("微信文件", icon: "folder", active: model.page == .files) {
                    model.page = .files
                    model.refreshFiles()
                }
                nav("目录图片", icon: "photo.on.rectangle", active: model.page == .images) {
                    model.page = .images
                    model.refreshDirectoryImages()
                }
                nav("采集状态", icon: "waveform.path", active: model.page == .overview) { model.page = .overview }
                nav("连接 Codex", icon: "point.3.connected.trianglepath.dotted", active: model.page == .mcp) {
                    model.page = .mcp
                }
            }.padding(.horizontal, 10)
            HStack {
                Text("会话").font(.caption.weight(.semibold))
                Spacer()
                Text("\(model.conversations.count)").font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.conversations) { conversation in
                        Button {
                            model.page = .archive
                            model.selectedID = conversation.id
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 11).fill(AppTheme.accentColor.opacity(0.10)).frame(
                                        width: 36, height: 36)
                                    Image(
                                        systemName: conversation.showsGroupIcon ? "person.2.fill" : "bubble.left.fill"
                                    ).foregroundStyle(AppTheme.accentColor)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(conversation.displayName).font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        Spacer(minLength: 2)
                                        Text("\(conversation.count)").font(.caption2.monospacedDigit()).foregroundStyle(
                                            .secondary)
                                    }
                                    if conversation.showsGroupIcon {
                                        Text(conversation.kindLabel).font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(AppTheme.accentColor)
                                    }
                                    Text(conversation.preview.isEmpty ? "通知未提供正文" : conversation.preview).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(10).contentShape(Rectangle())
                                .background(
                                    model.page == .archive && model.selectedID == conversation.id
                                        ? AppTheme.accentColor.opacity(0.13) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                    if model.conversations.isEmpty {
                        Text("采集到通知后，会话会出现在这里").font(.caption).foregroundStyle(.secondary).padding(18)
                    }
                }.padding(.horizontal, 8)
            }
            AppBottomBar(horizontalPadding: 18) {
                Circle().fill(model.isCollecting ? AppTheme.accentColor : .secondary).frame(width: 7, height: 7)
                Text(model.isCollecting ? "通知采集中" : "通知已暂停").font(.caption)
                Spacer()
                Button {
                    model.page = .settings
                } label: {
                    Image(systemName: "gearshape")
                }.buttonStyle(.plain).help("设置")
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    func nav(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: active ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(
                    active ? AppTheme.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9)
                )
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(active ? AppTheme.accentColor : .primary)
    }
}
