import SwiftUI

struct DiscoveredFileRow: View {
    let file: DiscoveredFile
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text").font(.title2).foregroundStyle(AppTheme.accentColor).frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(file.name).font(.callout.weight(.medium)).lineLimit(2).textSelection(.enabled)
                Text(
                    "\(file.sizeLabel) · \((Dates.parse(file.modifiedAt) ?? .distantPast).formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("打开") { model.openFile(file) }.font(.caption)
            Button {
                model.openFile(file, reveal: true)
            } label: {
                Image(systemName: "folder")
            }.help("在 Finder 中显示")
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct FileLibraryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(model.fileScanStatus, systemImage: "folder.badge.gearshape").font(.callout)
                        Spacer()
                        if model.fileScanBusy { ProgressView().controlSize(.small) }
                        Button("选择目录…", action: model.chooseFileDirectory)
                        Button("立即扫描", action: model.scanFiles).disabled(
                            model.fileScanBusy || model.preferences.fileDirectory == nil)
                    }
                    if let directory = model.preferences.fileDirectory {
                        Text(directory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("文件变化自动更新，每 15 秒补扫；暂停通知采集也会扫描。普通文件建立名称与路径索引；图片按会话和时间定位，再补充同组清晰版本；成功解码后可在消息中预览，可信度交由 AI 评估。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField("按文件名搜索…", text: $model.fileSearch).textFieldStyle(.roundedBorder)
            }.padding(24)
            Divider()
            if model.files.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder").font(.system(size: 40, weight: .light)).foregroundStyle(
                        AppTheme.accentColor)
                    Text(model.preferences.fileDirectory == nil ? "选择微信账号目录，开始探测本地文件" : "当前没有匹配的本地文件").font(.headline)
                    Text("文件来自本地目录，不能仅凭同名或时间确认它属于某条聊天消息。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.files) { file in DiscoveredFileRow(file: file, model: model) }
                    }.padding(.horizontal, 24).padding(.vertical, 16)
                }
            }
            AppBottomBar {
                Text("\(model.fileTotal) 个匹配文件").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.paginateFiles(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }.disabled(model.fileOffset == 0)
                Button {
                    model.paginateFiles(1)
                } label: {
                    Image(systemName: "chevron.right")
                }.disabled(model.fileOffset + model.files.count >= model.fileTotal)
            }
        }
    }
}
