import SwiftUI

struct DirectoryStatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if let directory = model.preferences.fileDirectory {
                Label(URL(fileURLWithPath: directory).lastPathComponent, systemImage: "folder")
                    .lineLimit(1).help(directory)
            } else {
                Text("尚未选择目录")
            }
            Spacer(minLength: 12)
            if model.fileScanBusy || model.directoryImagesLoading { ProgressView().controlSize(.small) }
            Text(model.fileScanStatus).foregroundStyle(.secondary).lineLimit(1).help(model.fileScanStatus)
        }.font(.caption).padding(.horizontal, 20).frame(height: 38).background(.bar)
    }
}
