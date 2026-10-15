import SwiftUI

struct AppBottomBar<Content: View>: View {
    let horizontalPadding: CGFloat
    let content: Content
    init(horizontalPadding: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.horizontalPadding = horizontalPadding
        self.content = content()
    }
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) { content }.padding(.horizontal, horizontalPadding).frame(height: 52)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
