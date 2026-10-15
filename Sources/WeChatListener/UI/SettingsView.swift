import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("打开应用后自动采集通知", isOn: $model.preferences.collectOnLaunch)
                    .onChange(of: model.preferences.collectOnLaunch) { model.savePreferences() }
            } header: {
                Text("采集")
            } footer: {
                Text("关闭窗口后继续在菜单栏运行。此选项不会添加系统登录启动项。")
            }
            Section("本机数据") {
                LabeledContent(
                    "档案大小",
                    value: ByteCountFormatter.string(fromByteCount: model.stats?.databaseBytes ?? 0, countStyle: .file))
                HStack {
                    Button("在 Finder 中显示", action: model.revealData)
                    Button("备份…", action: model.backup)
                    Button("导入…", action: model.importArchive)
                }
                DisclosureGroup("存储详情") {
                    Text(model.paths.root.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("\(model.stats?.events ?? 0) 条变更事件 · \(model.ftsAvailable ? "全文索引已就绪" : "字面搜索")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("档案保存在本机，未额外加密。目录权限仅允许当前用户访问。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("隐私与权限") {
                Button("管理完全磁盘访问…", action: model.showPrivacy)
                Text("只读系统通知和选定的微信文件目录，不修改微信内容，也不读取聊天数据库。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("清空本机档案…", role: .destructive, action: model.clearArchive).disabled(model.isWorking)
            } footer: {
                Text("不删除微信内容、原文件或已导出的备份。清空前会再次确认。")
            }
            if let error = model.errorText { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            Text("\(ApplicationInfo.name) \(ApplicationInfo.version)").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
