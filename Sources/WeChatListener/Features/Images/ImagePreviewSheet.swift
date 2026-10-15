import AppKit
import ImageIO
import SwiftUI

struct ImagePreviewSheet: View {
    let preview: ImagePreview
    let paths: AppPaths
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var fit = true
    @State private var zoom: CGFloat = 1
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("图片预览").font(.headline)
                Text("\(preview.width) × \(preview.height)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("适应窗口") { fit = true }.disabled(fit)
                Button("100%") {
                    fit = false
                    zoom = 1
                }
                Button {
                    fit = false
                    zoom = max(0.25, zoom / 1.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }.help("缩小")
                Button {
                    fit = false
                    zoom = min(4, zoom * 1.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }.help("放大")
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let image {
                GeometryReader { geometry in
                    let available = CGSize(width: geometry.size.width - 32, height: geometry.size.height - 32)
                    let size = ImagePreviewSizing.size(
                        width: preview.width, height: preview.height, displayScale: displayScale, available: available,
                        fit: fit, zoom: zoom)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high).frame(
                            width: size.width, height: size.height
                        )
                        .frame(minWidth: max(1, available.width), minHeight: max(1, available.height)).padding(16)
                    }
                }
            } else {
                ContentUnavailableView("预览不可用", systemImage: "photo", description: Text("请关闭后重新扫描图片。"))
            }
            Divider()
            HStack {
                Text("本地解码 · 按实际像素显示 · 文件的消息归属待确认").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("在 Finder 中显示预览") {
                    if let url = try? preview.validFile(paths: paths) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }.disabled(image == nil)
            }.padding(16)
        }.frame(minWidth: 760, idealWidth: 960, minHeight: 540, idealHeight: 740)
            .task(id: preview.token) {
                image = nil
                let decoded = await PreviewImageLoader.load(preview, paths: paths)
                guard !Task.isCancelled else { return }
                image = decoded.map { NSImage(cgImage: $0, size: .zero) }
            }
    }
}
