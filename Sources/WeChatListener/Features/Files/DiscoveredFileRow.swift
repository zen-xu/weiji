import SwiftUI

struct DiscoveredFileRow: View {
    let file: DiscoveredFile
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.callout).lineLimit(1).textSelection(.enabled)
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
