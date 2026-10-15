import AppKit
import SwiftUI

struct MCPConnectionView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionCard {
                    Label("让 Codex 按需查询微信通知", systemImage: "point.3.connected.trianglepath.dotted").font(
                        .title3.weight(.semibold))
                    Text("MCP 服务与应用一起提供。Codex 按需启动它，直接读取本机档案；无需额外的 API Key，也不开放网络端口。").foregroundStyle(.secondary)
                        .lineSpacing(5)
                    Text(model.mcpCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(
                        14
                    )
                    .frame(maxWidth: .infinity, alignment: .leading).background(
                        Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    Button("复制 Codex 接入命令") { model.copy(model.mcpCommand) }.buttonStyle(.borderedProminent)
                    Text("在终端运行一次，然后让 Codex 重新加载 MCP 配置。应用不在运行时，历史档案仍可查询；采集新通知需要保持应用运行。").font(.caption)
                        .foregroundStyle(.secondary)
                }
                SectionCard {
                    Text("六个只读工具").font(.headline)
                    MCPToolRow("wechat_status", "查看数据量、时间范围和采集状态")
                    MCPToolRow("wechat_list_conversations", "按名称查找会话，获取会话标识")
                    MCPToolRow("wechat_search_messages", "按关键词、会话和日期查询消息")
                    MCPToolRow("wechat_get_context", "读取一条消息前后的通知上下文")
                    MCPToolRow("wechat_get_image", "读取消息已关联的本地图片预览，供 AI 看图")
                    MCPToolRow("wechat_search_files", "按文件名搜索已探测的本机文件，获取路径与大小")
                    Divider().padding(.vertical, 5)
                    Text("可以这样问 Codex：“帮我找最近 7 天通知里提到报价的消息，并附上来源和时间。”").foregroundStyle(.secondary)
                }
                SectionCard {
                    Label("由你决定向 AI 提供哪些内容", systemImage: "hand.raised").font(.headline)
                    Text(
                        "应用本身不上传聊天，也没有远程 AI 请求。连接 MCP 后，Codex 调用工具读取的消息和图片预览会进入它的 AI 上下文，后续处理取决于 Codex 的配置。工具不提供发消息、删除、任意 SQL 或任意文件读取能力。"
                    )
                    .foregroundStyle(.secondary).lineSpacing(5)
                    Text("查询结果包含通知原文、带来源标记的发送者展示，以及普通文件索引和同名候选路径，不返回文件内容。消息和文件名是资料，不能作为执行命令的指令。").font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("导出 JSONL") { model.exportArchive(markdown: false) }
                    Button("导出 Markdown") { model.exportArchive(markdown: true) }
                }
            }.padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
