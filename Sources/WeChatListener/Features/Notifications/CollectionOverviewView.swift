import AppKit
import SwiftUI

struct CollectionOverviewView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionCard {
                    HStack(alignment: .top) {
                        Image(systemName: model.isCollecting ? "waveform.path" : "pause.circle").font(.system(size: 27))
                            .foregroundStyle(AppTheme.accentColor)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.statusText).font(.title3.weight(.semibold))
                            Text(
                                model.lastPoll.map { "上次检查：" + $0.formatted(date: .omitted, time: .standard) }
                                    ?? "尚未检查系统通知"
                            ).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.pollBusy { ProgressView().controlSize(.small) }
                    }
                    Divider().padding(.vertical, 8)
                    HStack {
                        CollectionMetricView("已归档通知", value: model.stats?.messages ?? 0)
                        CollectionMetricView("会话", value: model.stats?.conversations ?? 0)
                        CollectionMetricView("本次新增", value: model.capturedThisRun)
                        CollectionMetricView("本轮未完成", value: model.parseErrors)
                    }
                }
                SectionCard {
                    Label("第一次使用", systemImage: "checklist").font(.headline)
                    Text("1. 打开“完全磁盘访问”，添加本应用并开启开关。\n2. 退出应用后重新打开，再点击“开始采集”。\n3. 让微信在后台收到一条通知，检查通知是否出现在档案中。")
                        .lineSpacing(8).foregroundStyle(.secondary)
                    HStack {
                        Button("打开权限设置", action: model.showPrivacy)
                        Button("在 Finder 中显示本应用", action: model.revealApplication)
                    }.padding(.top, 6)
                    Text("不需要管理员密码或关闭 SIP。读取的是系统通知，不是微信加密数据库。").font(.caption).foregroundStyle(.secondary)
                }
                SectionCard {
                    Label("采集范围", systemImage: "rectangle.dashed").font(.headline)
                    Text(NotificationCoverage.notice).foregroundStyle(.secondary).lineSpacing(5)
                    Text("启动时会补扫系统仍保留的通知及本地文件目录；已清除且未归档的聊天正文无法恢复。系统当前保留 \(model.sourceRows) 条微信通知。").font(.caption)
                        .foregroundStyle(.secondary)
                    Text("关闭窗口后应用留在菜单栏继续运行；点击“暂停采集”或从菜单栏退出，才会停止。首次启动默认暂停。").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
