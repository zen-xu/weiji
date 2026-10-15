import AppKit
import SwiftUI

struct ImageLibraryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DirectoryStatusBar(model: model)
            if model.directoryImages.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.preferences.fileDirectory == nil ? "选择微信账号目录" : "尚无目录图片",
                        systemImage: "photo.on.rectangle")
                } description: {
                    Text(model.preferences.fileDirectory == nil ? "选择后自动探测并解码本机图片。" : "图片保存到本机后，会自动出现在这里。")
                } actions: {
                    if model.preferences.fileDirectory == nil { Button("选择目录…", action: model.chooseFileDirectory) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16, alignment: .top)],
                        alignment: .leading, spacing: 20
                    ) {
                        ForEach(model.directoryImages) { group in DirectoryImageCard(group: group, model: model) }
                    }.padding(20)
                }
            }
            AppBottomBar {
                Text("\(model.directoryImageTotal) 组图片").font(.caption).foregroundStyle(.secondary)
                Text("归属未验证").font(.caption).foregroundStyle(.tertiary)
                    .help("这些是目录文件，无法仅凭文件确认发送者、收发方向或消息归属。")
                Spacer()
                Button {
                    model.paginateDirectoryImages(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(model.directoryImageOffset == 0).help("上一页").accessibilityLabel("上一页")
                Button {
                    model.paginateDirectoryImages(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(model.directoryImageOffset + model.directoryImages.count >= model.directoryImageTotal)
                .help("下一页").accessibilityLabel("下一页")
            }
        }.background(.background)
    }
}

struct DirectoryImageCard: View {
    let group: DirectoryImageGroup
    @ObservedObject var model: AppModel
    @State private var image: NSImage?
    @State private var isLoading = false
    private var item: DirectoryImageItem { group.preferred }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if let preview = item.preview, preview.state == "ready" { model.selectedImage = preview }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(4)
                    } else if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo").font(.title2)
                            Text(item.preview?.state == "ready" ? "无法读取预览" : item.preview?.label ?? "待解码")
                                .font(.caption).multilineTextAlignment(.center)
                        }.foregroundStyle(.secondary).padding(12)
                    }
                }.frame(height: 160)
            }
            .buttonStyle(.plain).disabled(item.preview?.state != "ready")
            .help("查看大图").accessibilityLabel("查看图片 \(item.file.name)")
            Text(item.file.name).font(.caption).lineLimit(1).textSelection(.enabled)
            Text((Dates.parse(item.file.modifiedAt) ?? .distantPast).formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)

        }
        .contextMenu {
            Button("查看大图") { if let preview = item.preview { model.selectedImage = preview } }
                .disabled(item.preview?.state != "ready")
            Button("在 Finder 中显示") { model.openFile(item.file, reveal: true) }
        }
        .task(id: (item.preview?.token ?? "") + (item.preview?.state ?? "")) {
            image = nil
            isLoading = true
            guard let preview = item.preview else {
                isLoading = false
                return
            }
            let decoded = await PreviewImageLoader.load(preview, paths: model.paths, name: "thumbnail.png")
            guard !Task.isCancelled else { return }
            image = decoded.map { NSImage(cgImage: $0, size: .zero) }
            isLoading = false
        }
    }
}
