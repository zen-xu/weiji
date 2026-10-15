import SwiftUI

struct FileLibraryView: View {
    @ObservedObject var model: AppModel
    @State private var selection = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            DirectoryStatusBar(model: model)
            if model.filesLoading && model.files.isEmpty {
                ProgressView("正在读取本地文件索引…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.files.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.preferences.fileDirectory == nil
                            ? "选择微信账号目录" : model.fileSearch.isEmpty ? "尚无文件" : "没有匹配的文件",
                        systemImage: model.fileSearch.isEmpty ? "folder" : "magnifyingglass")
                } description: {
                    Text(
                        model.preferences.fileDirectory == nil
                            ? "选择后自动索引本机文件，原文件不会被修改。"
                            : model.fileSearch.isEmpty ? "文件保存到本机后会自动索引，也可以手动扫描目录。" : "试试其他文件名，或清除搜索查看全部文件。")
                } actions: {
                    if model.preferences.fileDirectory == nil {
                        Button("选择目录…", action: model.chooseFileDirectory).disabled(model.isWorking)
                    } else if !model.fileSearch.isEmpty {
                        Button("清除搜索") { model.fileSearch = "" }
                    } else {
                        Button("扫描目录", action: model.scanFiles).disabled(model.fileScanBusy || model.isWorking)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.files, selection: $selection) {
                    TableColumn("名称") { file in
                        Label(file.name, systemImage: file.symbolName).lineLimit(1).truncationMode(.middle).help(
                            file.name)
                    }
                    .width(min: 180, ideal: 350)
                    TableColumn("大小") { file in
                        Text(file.sizeLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .width(min: 65, ideal: 80, max: 100)
                    TableColumn("修改日期") { file in
                        Text(LibraryPresentation.date(file.modifiedAt))
                            .font(.caption).foregroundStyle(.secondary)
                            .help(LibraryPresentation.date(file.modifiedAt, abbreviated: true))
                    }.width(min: 145, ideal: 170, max: 190)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let file = file(for: ids) {
                        Button("打开") { model.openFile(file) }
                        Button("在 Finder 中显示") { model.openFile(file, reveal: true) }
                    }
                } primaryAction: { ids in
                    if let file = file(for: ids) { model.openFile(file) }
                }
            }
            AppBottomBar {
                Text(
                    LibraryPresentation.range(
                        offset: model.fileOffset, count: model.files.count, total: model.fileTotal, unit: "个文件")
                )
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let selected = file(for: selection) {
                    Button("打开") { model.openFile(selected) }
                    Button("在 Finder 中显示") { model.openFile(selected, reveal: true) }
                } else if selection.count > 1 {
                    Text("已选 \(selection.count.formatted()) 项").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                LibraryPageControls(
                    offset: model.fileOffset, count: model.files.count, total: model.fileTotal,
                    isLoading: model.filesLoading, previous: { model.paginateFiles(-1) },
                    next: { model.paginateFiles(1) })
            }
        }
        .onChange(of: model.fileOffset) { selection.removeAll() }
        .onChange(of: model.fileSearch) { selection.removeAll() }
        .onChange(of: model.preferences.fileDirectory) { selection.removeAll() }
    }

    private func file(for ids: Set<String>) -> DiscoveredFile? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.files.first { $0.id == id }
    }
}
