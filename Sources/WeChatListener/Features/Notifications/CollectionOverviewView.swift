import SwiftUI

struct CollectionOverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("通知采集") {
                LabeledContent("状态") {
                    if model.pollBusy { ProgressView().controlSize(.small).accessibilityLabel("正在读取系统通知") }
                    Text(model.statusText).foregroundStyle(.secondary)
                    Button(model.isCollecting ? "暂停采集" : "开始采集", action: model.toggleCollection)
                        .disabled(model.isWorking)
                }
                LabeledContent("上次检查", value: model.lastPoll?.formatted(date: .abbreviated, time: .standard) ?? "尚未检查")
                LabeledContent("系统保留通知", value: model.sourceRows.formatted())
                Button("补扫系统保留的通知") { model.poll(oneShot: true) }.disabled(model.pollBusy || model.isWorking)
            }
            Section("本地档案") {
                LabeledContent("已归档通知", value: (model.stats?.messages ?? 0).formatted())
                LabeledContent("会话", value: (model.stats?.conversations ?? 0).formatted())
                LabeledContent("本次新增", value: model.capturedThisRun.formatted())
                if model.parseErrors > 0 { LabeledContent("本轮未完成", value: model.parseErrors.formatted()) }
            }
            Section("通知访问") {
                HStack {
                    Button("打开权限设置…", action: model.showPrivacy)
                    Button("显示本应用", action: model.revealApplication)
                }
                DisclosureGroup("设置步骤") {
                    Text("1. 在完全磁盘访问中添加本应用，并开启开关。")
                    Text("2. 退出应用后重新打开，再开始采集。")
                    Text("3. 让微信在后台收到通知，检查档案是否更新。")
                }
            }
            Section {
                DisclosureGroup("了解采集范围") {
                    Text(NotificationCoverage.notice).foregroundStyle(.secondary)
                    Text("启动时补扫系统仍保留的通知。已清除且未归档的聊天正文无法恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("关闭窗口后继续在菜单栏运行。暂停采集不影响文件扫描和 MCP 查询。")
            }
        }.formStyle(.grouped)
    }
}
