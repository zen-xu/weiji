import SwiftUI

struct InlineNotice: View {
    let text: String
    var isError = false
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle")
                .foregroundStyle(isError ? Color.orange : AppAppearance.accent)
                .frame(height: 24).accessibilityHidden(true)
            Text(text).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.borderless).help("关闭提示").accessibilityLabel("关闭提示")
        }
    }
}
