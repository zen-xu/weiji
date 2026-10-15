import SwiftUI
import UniformTypeIdentifiers

extension DiscoveredFile {
    var symbolName: String {
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

struct DiscoveredFileRow: View {
    let file: DiscoveredFile
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: file.symbolName).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(
                    file.name)
                Text(file.sizeLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开") { model.openFile(file) }.controlSize(.small)
            Button {
                model.openFile(file, reveal: true)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示")
        }.padding(.vertical, 6)
    }
}
