import AppKit
import SwiftUI

struct StartupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var startup: StartupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch startup.stage {
            case .checking:
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("正在检查通知访问权限…").font(.headline)
                    Text("检查完成后继续设置。").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .accessRequired(let access):
                accessContent(access)
                Spacer(minLength: 16)
                Divider()
                HStack {
                    Button("退出") { NSApp.terminate(nil) }
                    Spacer()
                    Button("重新检查", action: startup.recheck)
                    if access == .denied {
                        Button("打开权限设置…", action: model.showPrivacy).buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }.padding(.top, 20)
            case .configuration:
                configuration
                Spacer(minLength: 16)
                Divider()
                HStack {
                    Text("稍后可在设置中更改。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("开始使用", action: startup.finishSetup).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }.padding(.top, 20)
            case .ready: EmptyView()
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
    }

    private func accessContent(_ access: NotificationAccess) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: access == .denied ? "lock.shield" : "externaldrive.badge.exclamationmark")
                .font(.system(size: 36)).foregroundStyle(.secondary)
            Text(access.title).font(.title2.weight(.semibold))
            Text(access.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if access == .denied {
                VStack(alignment: .leading, spacing: 12) {
                    Label("打开“隐私与安全性 → 完全磁盘访问”。", systemImage: "1.circle")
                    Label("添加“\(ApplicationInfo.name)”，并开启开关。", systemImage: "2.circle")
                    Label("返回应用，系统会自动重新检查。", systemImage: "3.circle")
                }.font(.callout).padding(.vertical, 4)
                Button("在 Finder 中显示本应用", action: model.revealApplication)
                Text("若授权后仍无法读取，请退出并重新打开应用。这里只读取系统通知，不读取微信聊天数据库。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, 12)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("通知访问已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(AppAppearance.accent).font(.callout)
            Text("设置采集方式").font(.title2.weight(.semibold))
            Toggle("打开应用后自动采集通知", isOn: $model.preferences.collectOnLaunch)
                .toggleStyle(.checkbox)
            Text("关闭窗口后继续在菜单栏运行，退出应用后停止。").font(.caption).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("本机文件（可选）").font(.headline)
                Text("选择微信账号目录，可浏览本机文件和图片。").foregroundStyle(.secondary)
                if let directory = model.preferences.fileDirectory {
                    Label(URL(fileURLWithPath: directory).lastPathComponent, systemImage: "folder")
                        .lineLimit(1).help(directory)
                }
                Button(model.preferences.fileDirectory == nil ? "选择目录…" : "更换目录…", action: model.chooseStartupDirectory)
                Text("也可以进入应用后再选择。").font(.caption).foregroundStyle(.secondary)
            }
            if let error = startup.setupError ?? model.errorText {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, 12)
    }
}
