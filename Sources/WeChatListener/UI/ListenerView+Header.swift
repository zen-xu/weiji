import AppKit
import SwiftUI

extension ListenerView {
    var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.page == .archive ? model.selected?.name ?? "所有通知" : model.page.rawValue).font(
                    .system(size: 23, weight: .semibold))
                Text(
                    model.page == .archive
                        ? "\(model.selected.map { $0.kindLabel + " · " } ?? "")\(model.total) 条通知 · 最新在前" : "本地保存，按需读取"
                ).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isWorking || model.loading { ProgressView().controlSize(.small) }
            Button {
                model.toggleCollection()
            } label: {
                Label(
                    model.isCollecting ? "暂停通知采集" : "开始通知采集",
                    systemImage: model.isCollecting ? "pause.fill" : "play.fill")
            }.buttonStyle(.borderedProminent).disabled(model.isWorking)
            Menu {
                Button("导入旧数据 / JSONL", action: model.importArchive)
                Button("补扫系统保留的历史通知") { model.poll(oneShot: true) }
                Button("导出当前筛选为 JSONL") { model.exportArchive(markdown: false) }
                Button("导出当前筛选为 Markdown") { model.exportArchive(markdown: true) }
                Divider()
                Button("备份档案数据库", action: model.backup)
                Button("打开数据目录", action: model.revealData)
            } label: {
                Image(systemName: "ellipsis.circle")
            }.menuStyle(.borderlessButton).fixedSize().disabled(model.isWorking)
        }.padding(.horizontal, 26).padding(.vertical, 22).background(.background)
    }
    func banner(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error ? "exclamationmark.triangle" : "checkmark.circle")
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button {
                if error { model.errorText = nil } else { model.feedback = nil }
            } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.plain)
        }.padding(12).background((error ? Color.orange : AppTheme.accentColor).opacity(0.10))
    }
}
