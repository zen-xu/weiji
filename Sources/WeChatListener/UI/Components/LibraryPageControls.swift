import SwiftUI

struct LibraryPageControls: View {
    let offset: Int
    let count: Int
    let total: Int
    let isLoading: Bool
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: previous) {
                Image(systemName: "chevron.left").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .disabled(offset == 0 || isLoading).help("上一页").accessibilityLabel("上一页")
            Button(action: next) {
                Image(systemName: "chevron.right").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .disabled(offset + count >= total || isLoading).help("下一页").accessibilityLabel("下一页")
        }.buttonStyle(.borderless)
    }
}

enum LibraryPresentation {
    static func range(offset: Int, count: Int, total: Int, unit: String) -> String {
        guard total > 0, count > 0 else { return "\(total.formatted()) \(unit)" }
        return "\((offset + 1).formatted())–\(min(offset + count, total).formatted()) / \(total.formatted()) \(unit)"
    }

    static func date(_ value: String, abbreviated: Bool = false) -> String {
        guard let date = Dates.parse(value) else { return "—" }
        return date.formatted(date: abbreviated ? .abbreviated : .numeric, time: .shortened)
    }
}
