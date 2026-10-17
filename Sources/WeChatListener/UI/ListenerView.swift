import AppKit
import SwiftUI

struct ListenerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            searchableContent
                .navigationTitle(model.page == .archive ? model.selected?.displayName ?? "所有通知" : model.page.rawValue)
                .toolbar { toolbar }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let error = model.errorText { banner(error, error: true) }
                    if let feedback = model.feedback { banner(feedback, error: false) }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 800, minHeight: 540)
        .sheet(item: $model.selectedImage) { preview in ImagePreviewSheet(preview: preview, paths: model.paths) }
        .task(id: model.feedback) {
            guard model.feedback != nil else { return }
            do {
                try await Task.sleep(for: .seconds(3))
                model.feedback = nil
            } catch {}
        }
    }

    @ViewBuilder private var searchableContent: some View {
        switch model.page {
        case .archive, .files, .images:
            pageContent.searchable(
                text: searchBinding, isPresented: $model.searchPresented, placement: .toolbar, prompt: searchPrompt)
        default: pageContent
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .archive: MessageArchiveView(model: model)
        case .reminders: ReminderInboxView(inbox: model.reminderInbox, model: model)
        case .files: FileLibraryView(model: model)
        case .images: ImageLibraryView(model: model)
        case .overview: CollectionOverviewView(model: model)
        case .mcp: MCPConnectionView(model: model)
        }
    }

    private var searchPrompt: String {
        switch model.page {
        case .files: "搜索文件名"
        case .images: "搜索图片文件名"
        default: "搜索通知"
        }
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: {
                switch model.page {
                case .files: model.fileSearch
                case .images: model.directoryImageSearch
                default: model.search
                }
            },
            set: { value in
                switch model.page {
                case .files: model.fileSearch = value
                case .images: model.directoryImageSearch = value
                default: model.search = value
                }
            })
    }
}
