import SwiftUI

extension ListenerView {
    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            switch model.page {
            case .archive:
                Button(action: model.toggleCollection) {
                    Label(model.isCollecting ? "暂停采集" : "开始采集", systemImage: model.isCollecting ? "pause" : "play")
                }
                .help(model.isCollecting ? "暂停通知采集" : "开始通知采集")
                .disabled(model.isWorking)
                Button(action: model.refresh) { Label("刷新", systemImage: "arrow.clockwise") }
                    .help("刷新本地档案").disabled(model.loading)
                Menu {
                    Button("导入通知…", action: model.importArchive)
                    Button("补扫系统保留的通知") { model.poll(oneShot: true) }
                    Divider()
                    Button("导出为 JSONL…") { model.exportArchive(markdown: false) }
                    Button("导出为 Markdown…") { model.exportArchive(markdown: true) }
                } label: {
                    Label("更多操作", systemImage: "ellipsis.circle")
                }.menuIndicator(.hidden).disabled(model.isWorking)
            case .files, .images:
                Button(action: model.chooseFileDirectory) { Label("选择目录…", systemImage: "folder.badge.plus") }
                    .help("选择微信账号目录")
                Button(action: model.scanFiles) { Label("扫描目录", systemImage: "arrow.clockwise") }
                    .help("立即扫描目录").disabled(model.fileScanBusy || model.preferences.fileDirectory == nil)
            default: EmptyView()
            }
        }
    }

    func banner(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(error ? Color.orange : Color.secondary)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button {
                if error { model.errorText = nil } else { model.feedback = nil }
            } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭提示")
        }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
    }
}
