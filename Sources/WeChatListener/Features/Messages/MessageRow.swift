import SwiftUI

struct MessageRow: View {
    let message: Message
    @ObservedObject var model: AppModel
    @State private var showingOriginal = false
    private var presentation: MessagePresentation { message.presentation }
    private var showsConversation: Bool {
        model.selectedID == nil
            && (presentation.isGroup || presentation.isInferredGroup || presentation.sender != message.displayName)
    }
    private func showConversation() {
        model.page = .archive
        model.selectedID = message.conversationID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsConversation {
                Button(action: showConversation) {
                    Label(
                        message.displayName,
                        systemImage: presentation.isGroup || presentation.isInferredGroup ? "person.2" : "bubble.left")
                }
                .buttonStyle(.plain).foregroundStyle(AppAppearance.accent).font(.caption).lineLimit(1)
                .help("查看此会话").accessibilityHint("筛选到此会话的通知")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.platformName).font(.caption2).foregroundStyle(.secondary)
                if model.selectedID == nil && !showsConversation {
                    Button(presentation.sender ?? message.displayName, action: showConversation)
                        .buttonStyle(.plain).font(.headline).help("查看此会话")
                } else {
                    Text(presentation.sender ?? "发送者未提供").font(.headline).textSelection(.enabled)
                }
                if presentation.senderSource == "body_prefix_inferred" {
                    Text("正文推测").font(.caption2).foregroundStyle(.secondary)
                        .help("根据通知中的昵称前缀展示，发送者身份未验证。")
                }
                Spacer(minLength: 8)
                Text(message.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help(message.date.formatted(date: .complete, time: .standard))
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(minWidth: 24, minHeight: 24)
                .help("通知操作").accessibilityLabel("通知操作")
            }
            Text(presentation.body.isEmpty ? "通知未提供正文" : presentation.body)
                .font(.body).lineSpacing(4).textSelection(.enabled)
                .foregroundStyle(presentation.body.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.vertical, 14)
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
