import SwiftUI
import AppKit

struct MessageCard: View {
    let message: Message
    @ObservedObject var model: AppModel
    var presentation: MessagePresentation { message.presentation }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(green.opacity(0.12)).frame(width: 36, height: 36)
                if let sender = presentation.sender {
                    Text(String(sender.prefix(1))).font(.system(size: 15, weight: .semibold)).foregroundStyle(green)
                } else { Image(systemName: "person.crop.circle").foregroundStyle(green) }
            }
            VStack(alignment: .leading, spacing: 10) {
                if model.selectedID == nil {
                    HStack(spacing: 7) {
                        Button { model.page = .archive; model.selectedID = message.conversationID } label: {
                            Label(message.displayName, systemImage: presentation.isGroup || presentation.isInferredGroup ? "person.2.fill" : "bubble.left")
                        }.buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(green).lineLimit(1)
                        Text(presentation.kindLabel).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.sender ?? "发送者未提供").font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                    if presentation.senderSource == "body_prefix_inferred" {
                        Text("正文推测").font(.caption2).foregroundStyle(.secondary)
                            .help("从“昵称: 正文”格式拆分，仅用于展示，不是已验证的发送者身份。原始通知保持不变。")
                    }
                    Spacer(minLength: 4)
                    Text(message.date.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(presentation.body.isEmpty ? "这条通知未提供正文" : presentation.body).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    .foregroundStyle(presentation.body.isEmpty ? .secondary : .primary).frame(maxWidth: .infinity, alignment: .leading)
                if let files = model.messageFiles[message.id], !files.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("同名文件候选 · 按通知文件名匹配，未验证消息归属").font(.caption).foregroundStyle(.secondary)
                        ForEach(files) { file in DiscoveredFileRow(file: file, model: model) }
                    }
                }
                if let images = model.imageLinks[message.id], !images.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message.isImageNotification ? "图片关联 · 优先显示清晰版本 · 归属由 AI 评估" : "附近发现的图片 · 未捕获独立图片通知 · 归属待确认").font(.caption).foregroundStyle(.secondary)
                        ForEach(ImageAssociations.groups(images)) { group in ImageAssociationCard(group: group, model: model) }
                    }
                }
                HStack(spacing: 12) {
                    if message.updatedAt != message.capturedAt { Text("已更新").foregroundStyle(.secondary) }
                    Spacer()
                    Menu {
                        Button("复制正文") { model.copy(presentation.body) }
                        Button("复制原始通知正文") { model.copy(message.body) }
                        Button("复制结构化 JSON") { if let data = try? jsonData(message, pretty: true) { model.copy(String(decoding: data, as: UTF8.self)) } }
                        Button("复制消息 ID") { model.copy(message.id) }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                }.font(.caption)
                DisclosureGroup("原始通知") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("标题：\(message.title)")
                        if !message.subtitle.isEmpty { Text("副标题：\(message.subtitle)") }
                        Text(message.body.isEmpty ? "正文为空" : message.body)
                        Text("消息 ID：\(message.id)").font(.system(size: 10, design: .monospaced))
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }
}
