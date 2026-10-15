import SwiftUI

struct CollectionMetricView: View {
    let title: String
    let value: Int

    init(_ title: String, value: Int) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(value)").font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
