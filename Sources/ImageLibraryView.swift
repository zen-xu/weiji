import SwiftUI
import AppKit

struct ImageLibraryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(model.directoryMonitorStatus, systemImage: "eye").font(.callout)
                    Spacer()
                    if model.fileScanBusy || model.directoryImagesLoading { ProgressView().controlSize(.small) }
                    Button("选择目录…", action: model.chooseFileDirectory)
                    Button("立即扫描", action: model.scanFiles).disabled(model.fileScanBusy || model.preferences.fileDirectory == nil)
                }
                Text("文件变化后自动探测、解码；暂停通知采集也会更新。这里是目录文件，发送者、收发方向和消息归属尚未确认。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.fileScanStatus).font(.caption).foregroundStyle(.secondary)
                TextField("按图片文件名搜索…", text: $model.directoryImageSearch).textFieldStyle(.roundedBorder)
            }.padding(24)
            Divider()
            if model.directoryImages.isEmpty {
                ContentUnavailableView(model.preferences.fileDirectory == nil ? "选择微信账户目录" : "等待目录图片", systemImage: "photo.on.rectangle",
                    description: Text(model.preferences.fileDirectory == nil ? "选择后自动探测并解码本机图片。" : "微信将图片保存到本机后，会自动显示在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(model.directoryImages) { group in DirectoryImageCard(group: group, model: model) }
                    }.padding(24)
                }
            }
            AppBottomBar {
                Text("\(model.directoryImageTotal) 组本地图片").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.paginateDirectoryImages(-1) } label: { Image(systemName: "chevron.left") }.disabled(model.directoryImageOffset == 0)
                Button { model.paginateDirectoryImages(1) } label: { Image(systemName: "chevron.right") }.disabled(model.directoryImageOffset + model.directoryImages.count >= model.directoryImageTotal)
            }
        }
    }
}

struct DirectoryImageCard: View {
    let group: DirectoryImageGroup
    @ObservedObject var model: AppModel
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale
    var item: DirectoryImageItem { group.preferred }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                if let preview = item.preview, preview.state == "ready" { model.selectedImage = preview }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(green.opacity(0.05))
                    if let image, let preview = item.preview {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .frame(maxWidth: min(330, CGFloat(preview.width) / displayScale), maxHeight: min(180, CGFloat(preview.height) / displayScale)).padding(5)
                    }
                    else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo").font(.title)
                            Text(item.preview?.label ?? "待自动解码").font(.caption).multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding(12)
                    }
                }.frame(height: 190)
            }.buttonStyle(.plain).disabled(item.preview?.state != "ready")
            if let preview = item.preview, preview.state == "ready" {
                Text("\(preview.width) × \(preview.height) · \(group.versions.count) 个版本").font(.caption).foregroundStyle(green)
            }
            Text(item.file.name).font(.caption).lineLimit(1).textSelection(.enabled)
            HStack {
                Text((Dates.parse(item.file.modifiedAt) ?? .distantPast).formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { model.openFile(item.file, reveal: true) } label: { Image(systemName: "folder") }.help("在 Finder 中显示原文件")
            }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .task(id: (item.preview?.token ?? "") + (item.preview?.state ?? "")) {
                if let preview = item.preview, let url = try? preview.validFile(paths: model.paths, name: "thumbnail.png") { image = NSImage(contentsOf: url) }
                else { image = nil }
            }
    }
}
