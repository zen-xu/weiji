import AppKit
import SwiftUI

struct ListenerView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 225, idealWidth: 265, maxWidth: 340)
            VStack(spacing: 0) {
                header
                if let error = model.errorText { banner(error, error: true) }
                if let feedback = model.feedback { banner(feedback, error: false) }
                switch model.page {
                case .archive: MessageArchiveView(model: model)
                case .files: FileLibraryView(model: model)
                case .images: ImageLibraryView(model: model)
                case .overview: CollectionOverviewView(model: model)
                case .mcp: MCPConnectionView(model: model)
                case .settings: SettingsView(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 620)
        .tint(AppTheme.accentColor)
        .sheet(item: $model.selectedImage) { preview in ImagePreviewSheet(preview: preview, paths: model.paths) }
    }
}
