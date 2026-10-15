import SwiftUI

struct DirectoryStatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let directory = model.preferences.fileDirectory {
                Label(URL(fileURLWithPath: directory).lastPathComponent, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).help(directory)
                    .accessibilityLabel("微信账号目录：\(URL(fileURLWithPath: directory).lastPathComponent)")
            } else {
                Text("尚未选择目录")
            }
            Spacer(minLength: 12)
            if model.fileScanBusy || (model.page == .images ? model.directoryImagesLoading : model.filesLoading) {
                ProgressView().controlSize(.small).accessibilityLabel(model.fileScanBusy ? "正在扫描目录" : "正在读取索引")
            }
            Text(model.fileScanStatus).foregroundStyle(.secondary).lineLimit(1).help(model.fileScanStatus)
                .layoutPriority(-1)
        }.font(.caption).padding(.horizontal, 20).frame(height: 38).background(.bar)
    }
}
