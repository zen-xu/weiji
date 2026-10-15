import SwiftUI

struct MCPToolRow: View {
    let name: String
    let detail: String

    init(_ name: String, _ detail: String) {
        self.name = name
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(name).font(.system(.caption, design: .monospaced)).frame(width: 210, alignment: .leading)
            Text(detail).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
