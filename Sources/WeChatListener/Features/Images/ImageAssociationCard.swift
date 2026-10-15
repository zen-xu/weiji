import AppKit
import ImageIO
import SwiftUI

struct ImageAssociationCard: View {
    let group: ImageAssociationGroup
    @ObservedObject var model: AppModel
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?
    var item: ImageAssociation { group.preferred }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    } else {
                        ProgressView().frame(width: 100, height: 70)
                    }
                }.buttonStyle(.plain).help("点击查看大图")
                HStack {
                    Text("\(preview.width) × \(preview.height)").font(.caption2).foregroundStyle(.secondary)
                    if item.isThumbnail {
                        Text("当前为缩略图").font(.caption2).foregroundStyle(.secondary)
                    } else if group.versions.count > 1 {
                        Text("已选较清晰版本").font(.caption2).foregroundStyle(AppTheme.accentColor)
                    }
                    Button("查看大图") { model.selectedImage = preview }.font(.caption)
                }
            } else {
                Label(item.preview?.label ?? "预览将在扫描后生成", systemImage: "photo").font(.caption).foregroundStyle(
                    .secondary)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.file.name).font(.caption.weight(.medium)).lineLimit(1).textSelection(.enabled)
                    Text(
                        "\(item.file.sizeLabel) · \(item.matchesTimeWindow ? "时间差" : "同组版本，文件时间差") \(String(format: "%+.3f", item.secondsFromNotification)) 秒"
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button {
                    model.openFile(item.file, reveal: true)
                } label: {
                    Image(systemName: "folder")
                }.help("在 Finder 中显示原文件")
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
                            } else {
                                Text(version.preview?.label ?? "尚未生成预览").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.top, 5)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .task(id: (item.preview?.token ?? "") + (item.preview?.state ?? "")) {
                thumbnail = nil
                guard let preview = item.preview else { return }
                let decoded = await PreviewImageLoader.load(preview, paths: model.paths, name: "thumbnail.png")
                guard !Task.isCancelled else { return }
                thumbnail = decoded.map { NSImage(cgImage: $0, size: .zero) }
            }
    }
}
