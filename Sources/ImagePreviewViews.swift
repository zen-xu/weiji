import SwiftUI
import AppKit
import ImageIO

/// Read and decompress cached previews away from SwiftUI's main actor. The cache has a fixed memory budget.
enum PreviewImageLoader {
    private static let queue = DispatchQueue(label: "local.wechat-listener.preview-display", qos: .userInitiated)
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 128
        return cache
    }()
    static func load(_ preview: ImagePreview, paths: AppPaths, name: String = "image.png") async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                let image: CGImage? = autoreleasepool {
                    // Validate even on cache hits so a deleted or replaced cache path is never trusted.
                    guard let url = try? preview.validFile(paths: paths, name: name) else { return nil }
                    let key = url.path as NSString
                    if let cached = cache.object(forKey: key) { return cached }
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                          let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                          let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                          width > 0, height > 0, width <= 4096, height <= 4096,
                          let decoded = CGImageSourceCreateImageAtIndex(source, 0,
                            [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
                    cache.setObject(decoded, forKey: key, cost: decoded.bytesPerRow * decoded.height)
                    return decoded
                }
                continuation.resume(returning: image)
            }
        }
    }
}

struct ImageAssociationCard: View {
    let group: ImageAssociationGroup
    @ObservedObject var model: AppModel
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?
    var item: ImageAssociation { group.preferred }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview = item.preview, preview.state == "ready" {
                Button { model.selectedImage = preview } label: {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFit()
                            .frame(maxWidth: min(380, CGFloat(preview.width) / displayScale),
                                   maxHeight: min(250, CGFloat(preview.height) / displayScale), alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    } else { ProgressView().frame(width: 100, height: 70) }
                }.buttonStyle(.plain).help("点击查看大图")
                HStack {
                    Text("\(preview.width) × \(preview.height)").font(.caption2).foregroundStyle(.secondary)
                    if item.isThumbnail { Text("当前为缩略图").font(.caption2).foregroundStyle(.secondary) }
                    else if group.versions.count > 1 { Text("已选较清晰版本").font(.caption2).foregroundStyle(green) }
                    Button("查看大图") { model.selectedImage = preview }.font(.caption)
                }
            } else {
                Label(item.preview?.label ?? "预览将在扫描后生成", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.file.name).font(.caption.weight(.medium)).lineLimit(1).textSelection(.enabled)
                    Text("\(item.file.sizeLabel) · \(item.matchesTimeWindow ? "时间差" : "同组版本，文件时间差") \(String(format: "%+.3f", item.secondsFromNotification)) 秒")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { model.openFile(item.file, reveal: true) } label: { Image(systemName: "folder") }.help("在 Finder 中显示原文件")
            }
            if group.versions.count > 1 {
                DisclosureGroup("其他版本（\(group.versions.count - 1)）") {
                    ForEach(Array(group.versions.dropFirst())) { version in
                        HStack {
                            Text(version.isThumbnail ? "微信缩略图" : "同组图片").font(.caption)
                            if let preview = version.preview, preview.state == "ready" {
                                Text("\(preview.width) × \(preview.height)").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Button("查看") { model.selectedImage = preview }.font(.caption)
                            } else { Text(version.preview?.label ?? "尚未生成预览").font(.caption2).foregroundStyle(.secondary) }
                        }.padding(.top, 5)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(green.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .task(id: (item.preview?.token ?? "") + (item.preview?.state ?? "")) {
                thumbnail = nil
                guard let preview = item.preview else { return }
                let decoded = await PreviewImageLoader.load(preview, paths: model.paths, name: "thumbnail.png")
                guard !Task.isCancelled else { return }
                thumbnail = decoded.map { NSImage(cgImage: $0, size: .zero) }
            }
    }
}

enum ImagePreviewSizing {
    static func size(width: Int, height: Int, displayScale: CGFloat, available: CGSize, fit: Bool, zoom: CGFloat) -> CGSize {
        let scale = max(1, displayScale)
        let w = CGFloat(width) / scale, h = CGFloat(height) / scale
        guard w > 0, h > 0 else { return .zero }
        let factor = fit ? min(1, max(1, available.width) / w, max(1, available.height) / h) : min(4, max(0.25, zoom))
        return CGSize(width: w * factor, height: h * factor)
    }
}

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
                Button("100%") { fit = false; zoom = 1 }
                Button { fit = false; zoom = max(0.25, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
                Button { fit = false; zoom = min(4, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let image {
                GeometryReader { geometry in
                    let available = CGSize(width: geometry.size.width - 32, height: geometry.size.height - 32)
                    let size = ImagePreviewSizing.size(width: preview.width, height: preview.height, displayScale: displayScale, available: available, fit: fit, zoom: zoom)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                            .frame(minWidth: max(1, available.width), minHeight: max(1, available.height)).padding(16)
                    }
                }
            } else { ContentUnavailableView("预览不可用", systemImage: "photo", description: Text("请关闭后重新扫描图片。")) }
            Divider()
            HStack {
                Text("本地解码 · 按实际像素显示 · 文件的消息归属待确认").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("在 Finder 中显示预览") {
                    if let url = try? preview.validFile(paths: paths) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
