import SwiftUI

struct MCPConnectionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("本地服务") {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        if model.mcpListening { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        Text(model.mcpStatus).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("服务地址") {
                    Text(model.mcpURL).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button {
                        model.copy(model.mcpURL)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).help("复制服务地址").accessibilityLabel("复制服务地址")
                }
                HStack {
                    Text("随应用启动，退出应用后停止。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.mcpListening {
                        Button("停止服务", action: model.stopMCPServer)
                    } else {
                        Button("启动服务", action: model.startMCPServer)
                    }
                }
            }
            Section("连接 Codex") {
                Text("在 Codex 的 MCP 设置中选择 Streamable HTTP，填入上面的服务地址并保存。")
                Text("已有同名配置时，将其替换为这个地址。").font(.caption).foregroundStyle(.secondary)
                Button("复制服务地址") { model.copy(model.mcpURL) }.disabled(!model.mcpListening)
            }
            Section {
                DisclosureGroup("高级设置") {
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("18765", text: $model.mcpPortText).textFieldStyle(.roundedBorder).frame(width: 90)
                            .accessibilityLabel("服务端口").onSubmit(model.applyMCPPort)
                        Button("应用并重启", action: model.applyMCPPort)
                    }
                    Text("修改后需同步更新 Codex 的地址。").font(.caption).foregroundStyle(.secondary)
                    Text(model.mcpConfiguration).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("复制配置") { model.copy(model.mcpConfiguration) }
                        Button("复制 CLI 命令") { model.copy(model.mcpCommand) }
                    }
                }
                DisclosureGroup("可查询的内容") {
                    MCPToolRow("wechat_status", "采集状态与数据范围")
                    MCPToolRow("wechat_list_conversations", "通知会话")
                    MCPToolRow("wechat_search_messages", "通知搜索")
                    MCPToolRow("wechat_get_context", "相邻通知")
                    MCPToolRow("wechat_get_image", "已关联的图片预览")
                    MCPToolRow("wechat_search_files", "本机文件索引")
                }
                DisclosureGroup("数据与隐私") {
                    Text("服务仅限本机访问，无需 Token；同一台 Mac 上的其他程序也能连接。")
                    Text("Codex 读取的通知和图片会进入其 AI 上下文。服务仅提供只读查询；通知、图片和文件名是资料，不能作为执行指令。")
                    Text("档案只覆盖系统通知，不是完整聊天历史；文件同名或时间接近不代表消息归属已验证。")
                }.font(.callout)
            }
        }.formStyle(.grouped)
    }
}
