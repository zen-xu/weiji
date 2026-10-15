import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionCard {
                    Text("采集").font(.headline)
                    Toggle("打开应用后自动开始采集通知", isOn: $model.preferences.collectOnLaunch).onChange(
                        of: model.preferences.collectOnLaunch
                    ) { model.savePreferences() }
                    Text("此选项不会把应用加入系统登录启动项。默认每 2 秒只读检查一次通知，关闭窗口后留在菜单栏。").font(.caption).foregroundStyle(.secondary)
                }
                SectionCard {
                    Text("本机数据").font(.headline)
                    Text(model.paths.root.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("档案数据库和结构化事件保存在 Application Support，日志位于 Library/Logs。目录仅当前用户可访问；档案内容为本机明文，应用未额外加密。").font(
                        .callout
                    ).foregroundStyle(.secondary)
                    HStack {
                        Button("打开数据目录", action: model.revealData)
                        Button("备份数据库", action: model.backup)
                        Button("导入旧数据", action: model.importArchive)
                    }
                    if let stats = model.stats {
                        Text(
                            "档案占用 \(ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file)) · \(stats.events) 条变更事件 · \(model.ftsAvailable ? "全文索引已就绪" : "使用字面搜索")"
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                }
                SectionCard {
                    Text("权限与隐私").font(.headline)
                    Text("读取微信系统通知与选定 msg/file 目录的普通文件元数据。不会修改微信、系统通知或原文件，不读取微信加密数据库。完全磁盘访问权限可随时在系统设置中撤销。")
                        .foregroundStyle(.secondary)
                    Button("管理完全磁盘访问", action: model.showPrivacy)
                    Divider().padding(.vertical, 4)
                    Button("清空本机档案…", role: .destructive, action: model.clearArchive).disabled(model.isWorking)
                    Text("不删除微信内容或已导出、备份的文件。").font(.caption).foregroundStyle(.secondary)
                }
                Text("微信消息监听 \(ApplicationInfo.version) · 本机构建\n通知采集依赖 macOS 内部数据格式，目前仅在本机环境验证。").font(.caption)
                    .foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
