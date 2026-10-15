import SwiftUI

struct FileLibraryView: View {
    @ObservedObject var model: AppModel
    @State private var selection = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            DirectoryStatusBar(model: model)
            if model.files.isEmpty {
                ContentUnavailableView {
                    Label(model.preferences.fileDirectory == nil ? "选择微信账号目录" : "没有匹配的文件", systemImage: "folder")
                } description: {
                    Text(model.preferences.fileDirectory == nil ? "选择后自动索引本机文件，原文件不会被修改。" : "试试其他文件名，或检查目录是否可访问。")
                } actions: {
                    if model.preferences.fileDirectory == nil { Button("选择目录…", action: model.chooseFileDirectory) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.files, selection: $selection) {
                    TableColumn("名称") { file in
                        Label(file.name, systemImage: "doc.text").lineLimit(1).truncationMode(.middle).help(file.name)
                    }
                    .width(min: 180, ideal: 350)
                    TableColumn("大小") { file in Text(file.sizeLabel).font(.caption).foregroundStyle(.secondary) }
                        .width(min: 65, ideal: 80, max: 100)
                    TableColumn("修改日期") { file in
                        Text(
                            (Dates.parse(file.modifiedAt) ?? .distantPast).formatted(
                                date: .numeric, time: .shortened)
                        )
                        .font(.caption).foregroundStyle(.secondary)
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
                Text("\(model.fileTotal) 个文件").font(.caption).foregroundStyle(.secondary)
                if let selected = file(for: selection) {
                    Button("打开") { model.openFile(selected) }
                    Button("在 Finder 中显示") { model.openFile(selected, reveal: true) }
                }
                Spacer(minLength: 8)
                Button {
                    model.paginateFiles(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(model.fileOffset == 0).help("上一页").accessibilityLabel("上一页")
                Button {
                    model.paginateFiles(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(model.fileOffset + model.files.count >= model.fileTotal).help("下一页").accessibilityLabel("下一页")
            }
        }
        .onChange(of: model.fileOffset) { selection.removeAll() }
    }

    private func file(for ids: Set<String>) -> DiscoveredFile? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.files.first { $0.id == id }
    }
}
