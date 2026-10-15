import AppKit
import ImageIO
import SwiftUI

struct ImagePreviewSheet: View {
    let preview: ImagePreview
    let paths: AppPaths
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var fit = true
    @State private var zoom: CGFloat = 1
    @State private var fittedZoom: CGFloat = 1
    private var currentZoom: CGFloat { fit ? fittedZoom : zoom }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("图片预览").font(.headline)
                Text("\(preview.width) × \(preview.height)").font(.caption.monospacedDigit()).foregroundStyle(
                    .secondary)
                Spacer()
                Button("适应窗口") { fit = true }.disabled(fit || image == nil)
                    .keyboardShortcut("0", modifiers: .command).help("适应窗口（⌘0）")
                Button("100%") {
                    fit = false
                    zoom = 1
                }.disabled(image == nil || (!fit && zoom == 1))
                    .keyboardShortcut("1", modifiers: .command).help("按实际像素显示（⌘1）")
                Button {
                    zoom = max(0.25, currentZoom / 1.25)
                    fit = false
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }.disabled(image == nil || currentZoom <= 0.25)
                    .keyboardShortcut("-", modifiers: .command).help("缩小（⌘−）").accessibilityLabel("缩小")
                Button {
                    zoom = min(4, max(0.25, currentZoom * 1.25))
                    fit = false
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }.disabled(image == nil || currentZoom >= 4)
                    .keyboardShortcut("=", modifiers: .command).help("放大（⌘+）").accessibilityLabel("放大")
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let image {
                GeometryReader { geometry in
                    let available = CGSize(width: geometry.size.width - 32, height: geometry.size.height - 32)
                    let size = ImagePreviewSizing.size(
                        width: preview.width, height: preview.height, displayScale: displayScale, available: available,
                        fit: fit, zoom: zoom)
                    let fittedSize = ImagePreviewSizing.size(
                        width: preview.width, height: preview.height, displayScale: displayScale, available: available,
                        fit: true, zoom: 1)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high).frame(
                            width: size.width, height: size.height
                        )
                        .frame(minWidth: max(1, available.width), minHeight: max(1, available.height)).padding(16)
                    }
                    .onChange(of: fittedSize, initial: true) {
                        fittedZoom = fittedSize.width / (CGFloat(max(1, preview.width)) / max(1, displayScale))
                    }
                }
            } else if isLoading {
                ProgressView("正在读取图片…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("预览不可用", systemImage: "photo", description: Text("请关闭后重新扫描图片。"))
            }
            Divider()
            HStack {
                Text(fit ? "适应窗口" : "\(Int((zoom * 100).rounded()))% · 按实际像素缩放")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("本地解码 · 归属未验证").font(.caption).foregroundStyle(.tertiary)
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
                isLoading = true
                let decoded = await PreviewImageLoader.load(preview, paths: paths)
                guard !Task.isCancelled else { return }
                image = decoded.map { NSImage(cgImage: $0, size: .zero) }
                isLoading = false
            }
    }
}
