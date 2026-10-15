import AppKit
import SwiftUI

struct ImageAssociationCard: View {
    let group: ImageAssociationGroup
    @ObservedObject var model: AppModel
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?
    @State private var isLoading = false
    private var item: ImageAssociation { group.preferred }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let preview = item.preview, preview.state == "ready" {
                Button {
                    model.selectedImage = preview
                } label: {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().interpolation(.high).scaledToFit()
                            .frame(
                                maxWidth: min(380, CGFloat(preview.width) / displayScale),
                                maxHeight: min(250, CGFloat(preview.height) / displayScale), alignment: .leading
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else if isLoading {
                        ProgressView().frame(width: 100, height: 70)
                    } else {
                        Label("无法读取预览", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain).help("查看大图").accessibilityLabel("查看关联图片")
                Text("\(preview.width) × \(preview.height)\(item.isThumbnail ? " · 缩略图" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Label(item.preview?.label ?? "预览将在扫描后生成", systemImage: "photo").font(.caption).foregroundStyle(
                    .secondary)
            }
            DisclosureGroup("文件详情\(group.versions.count > 1 ? " · \(group.versions.count) 个版本" : "")") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.file.name).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(
                            item.file.name)
                        Text(
                            "\(item.file.sizeLabel) · \(item.matchesTimeWindow ? "时间差" : "同组版本，时间差") \(String(format: "%+.3f", item.secondsFromNotification)) 秒"
                        )
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.openFile(item.file, reveal: true)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless).help("在 Finder 中显示原文件").accessibilityLabel("在 Finder 中显示原文件")
                }.padding(.top, 4)
                if group.versions.count > 1 {
                    ForEach(Array(group.versions.dropFirst())) { version in
                        HStack {
                            Text(version.isThumbnail ? "微信缩略图" : "同组图片")
                            Spacer()
                            if let preview = version.preview, preview.state == "ready" {
                                Text("\(preview.width) × \(preview.height)").foregroundStyle(.secondary)
                                Button("查看") { model.selectedImage = preview }
                            } else {
                                Text(version.preview?.label ?? "尚未生成预览").foregroundStyle(.secondary)
                            }
                        }.padding(.top, 4)
                    }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: (item.preview?.token ?? "") + (item.preview?.state ?? "")) {
            thumbnail = nil
            isLoading = true
            guard let preview = item.preview, preview.state == "ready" else {
                isLoading = false
                return
            }
            let decoded = await PreviewImageLoader.load(preview, paths: model.paths, name: "thumbnail.png")
            guard !Task.isCancelled else { return }
            thumbnail = decoded.map { NSImage(cgImage: $0, size: .zero) }
            isLoading = false
        }
    }
}
