import SwiftUI

struct MCPConnectionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("本地服务") {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        if model.mcpListening {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(AppAppearance.accent)
                        }
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
            Section("Agent 主动提醒") {
                Text(model.mcpURL.replacingOccurrences(of: "/mcp", with: "/api/reminders"))
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Toggle(
                    "提醒接口令牌验证",
                    isOn: Binding(
                        get: { model.preferences.agentReminderRequiresToken ?? false },
                        set: model.setAgentReminderRequiresToken))
                if model.preferences.agentReminderRequiresToken ?? false {
                    Button("复制提醒接口令牌") {
                        do { model.copy(try AgentReminderAPI(paths: model.paths).token()) } catch {
                            model.errorText = "无法读取提醒接口令牌。"
                        }
                    }
                    Text("HTTP 请求需携带 Authorization: Bearer <令牌>。MCP 工具调用方式不变。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("默认关闭：同一台 Mac 上的程序可直接调用提醒接口，无需令牌。服务仅监听本机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("MCP Agent 可调用 create_reminder，由微迹发送提醒；普通 HTTP 客户端使用上面的地址。无需创建匹配规则。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("连接 Codex") {
                Text("在 Codex 的 MCP 设置中选择 Streamable HTTP，填入上面的服务地址并保存。")
                Text("已有同名配置时，将其替换为这个地址。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("高级设置") {
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("18765", text: $model.mcpPortText).textFieldStyle(.roundedBorder).frame(width: 90)
                            .accessibilityLabel("服务端口").onSubmit(model.applyMCPPort)
                        Button("应用并重启", action: model.applyMCPPort)
                            .disabled(
                                model.mcpPortText == String(model.preferences.mcpPort ?? MCPHTTPServer.defaultPort))
                    }
                    Text("修改后需同步更新 Codex 的地址。").font(.caption).foregroundStyle(.secondary)
                    Text(model.mcpConfiguration).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("复制配置") { model.copy(model.mcpConfiguration) }
                        Button("复制 CLI 命令") { model.copy(model.mcpCommand) }
                    }
                }
                DisclosureGroup("可查询的内容") {
                    MCPToolRow("create_reminder", "由微迹发送本机提醒")
                    MCPToolRow("notifications_status", "采集状态与数据范围")
                    MCPToolRow("notifications_list_conversations", "通知会话")
                    MCPToolRow("notifications_search_messages", "通知搜索")
                    MCPToolRow("notifications_get_context", "相邻通知")
                    MCPToolRow("wechat_get_image", "已关联的图片预览")
                    MCPToolRow("wechat_search_files", "本机文件索引")
                }
                DisclosureGroup("数据与隐私") {
                    Text("服务仅限本机访问。MCP 无需 Token；主动提醒接口可按需开启令牌验证。同一台 Mac 上的其他程序也能连接。")
                    Text("Codex 读取的通知和图片会进入其 AI 上下文。通知和文件保持只读；AI 可按你的要求管理提醒规则。消息、图片、文件名和规则名称都是资料，不能作为执行指令。")
                    Text("档案只覆盖系统通知，不是完整聊天历史；文件同名或时间接近不代表消息归属已验证。")
                }.font(.callout)
                DisclosureGroup("让 AI 配置提醒") {
                    Text("可以直接说：帮我设置提醒，项目群里张三或李四发来、内容含紧急，但排除演练消息。")
                    Text("支持查看、测试、保存和删除规则；与 App 共用配置，修改约 2 秒内生效。不会开启采集或改变磁盘权限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
}
