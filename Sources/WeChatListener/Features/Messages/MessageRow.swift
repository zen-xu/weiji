import SwiftUI

struct MessageRow: View {
    let message: Message
    @ObservedObject var model: AppModel
    @State private var showingOriginal = false
    private var presentation: MessagePresentation { message.presentation }
    private var sender: String? {
        guard let sender = presentation.sender, !sender.isEmpty, sender != message.displayName else { return nil }
        return sender
    }
    private var heading: String {
        model.selectedID == nil ? message.displayName : sender ?? message.displayName
    }
    private func showConversation() {
        model.page = .archive
        model.selectedID = message.conversationID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            LongNotificationBody(message: message, text: presentation.body)
            if let files = model.messageFiles[message.id], !files.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("同名文件 · 归属未验证").font(.caption).foregroundStyle(.secondary)
                    ForEach(files) { file in DiscoveredFileRow(file: file, model: model) }
                }.padding(.top, 4)
            }
            if let images = model.imageLinks[message.id], !images.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message.isImageNotification ? "时间关联图片 · 归属未验证" : "附近的目录图片 · 未捕获图片通知")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(ImageAssociations.groups(images)) { group in
                        ImageAssociationCard(group: group, model: model)
                    }
                }.padding(.top, 4)
            }
            if message.updatedAt != message.capturedAt {
                Text("已更新").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 16)
        .contextMenu { actions }
        .popover(isPresented: $showingOriginal, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("原始通知").font(.headline)
                LabeledContent("标题", value: message.title)
                if !message.subtitle.isEmpty { LabeledContent("副标题", value: message.subtitle) }
                Divider()
                ScrollView {
                    Text(message.body.isEmpty ? "正文为空" : message.body).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                Text("消息 ID").font(.caption).foregroundStyle(.secondary)
                Text(message.id).font(.system(.caption2, design: .monospaced))
            }.textSelection(.enabled).padding(20).frame(width: 400)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if model.selectedID == nil {
                        Button(heading, action: showConversation)
                            .buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                            .help("查看此会话").accessibilityHint("筛选到此会话的通知")
                    } else {
                        Text(heading).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                    }
                    NotificationSourceBadge(message: message)
                }
                if model.selectedID == nil, let sender {
                    HStack(spacing: 5) {
                        Text(sender).font(.system(size: 11)).foregroundStyle(.secondary)
                        if presentation.senderSource == "body_prefix_inferred" {
                            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                                .help("发送者根据正文前缀推测，身份未验证。")
                                .accessibilityLabel("发送者为正文推测")
                        }
                    }
                } else if presentation.senderSource == "body_prefix_inferred" {
                    Text("发送者为正文推测").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(message.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.top, 2).help(message.date.formatted(date: .complete, time: .standard))
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("通知操作").accessibilityLabel("通知操作")
        }
    }

    @ViewBuilder private var actions: some View {
        Menu("创建提醒规则") {
            ForEach(ReminderQuickRule.Kind.allCases) { kind in
                Button(kind.label) { model.createReminder(from: message, kind: kind) }
                    .disabled(ReminderQuickRule.make(message: message, kind: kind) == nil)
            }
        }
        Divider()
        Button("复制正文") { model.copy(presentation.body) }
        Button("复制原始通知正文") { model.copy(message.body) }
        Button("复制结构化 JSON") {
            if let data = try? jsonData(message, pretty: true) { model.copy(String(decoding: data, as: UTF8.self)) }
        }
        Button("复制消息 ID") { model.copy(message.id) }
        Divider()
        Button("查看原始通知…") { showingOriginal = true }
    }
}
