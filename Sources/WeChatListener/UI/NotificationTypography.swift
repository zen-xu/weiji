import Foundation
import SwiftUI

/// Formatting is presentation-only. Raw notification text is always kept verbatim.
struct NotificationSourceBadge: View {
    let message: Message
    private var color: Color {
        message.source == "agent_reminder"
            ? .indigo
            : message.notificationPlatform == .feishu ? .blue : AppAppearance.accent
    }
    var body: some View {
        Text(message.source == "agent_reminder" ? "Agent 提醒" : message.platformName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.09), in: Capsule())
            .fixedSize()
    }
}

struct NotificationTextBlock: Equatable {
    enum Kind: Equatable {
        case paragraph, heading
        case bullet(String)
    }
    var kind: Kind
    var text: String

    static func parse(_ text: String) -> [Self] {
        var blocks: [Self] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                blocks.append(Self(kind: .paragraph, text: paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            let hashes = line.prefix(while: { $0 == "#" })
            if (1...3).contains(hashes.count), line.dropFirst(hashes.count).first == " " {
                flush()
                blocks.append(Self(kind: .heading, text: String(line.dropFirst(hashes.count + 1))))
            } else if ["- ", "* ", "• "].contains(where: line.hasPrefix) {
                flush()
                blocks.append(Self(kind: .bullet("•"), text: String(line.dropFirst(2))))
            } else if let range = line.range(of: #"^\d{1,2}[.)、]\s+"#, options: .regularExpression) {
                flush()
                blocks.append(
                    Self(
                        kind: .bullet(String(line[range]).trimmingCharacters(in: .whitespaces)),
                        text: String(line[range.upperBound...])))
            } else {
                paragraph.append(raw)
            }
        }
        flush()
        return blocks
    }
}

struct NotificationBody: View {
    let text: String
    var summary = false
    var lineLimit: Int? = nil
    private var blocks: [NotificationTextBlock] { NotificationTextBlock.parse(text) }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
    var body: some View {
        Group {
            if summary && lineLimit == nil {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
            } else {
                Text(summary ? inline(compactSummary) : AttributedString(text.isEmpty ? "通知未提供正文" : text))
                    .lineLimit(lineLimit)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
            }
        }
        .font(.system(size: 13)).lineSpacing(4)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    private var compactSummary: String {
        blocks.map { block in
            if case .bullet(let marker) = block.kind { return marker + " " + block.text }
            return block.text
        }.joined(separator: "\n")
    }
    @ViewBuilder private func blockView(_ block: NotificationTextBlock) -> some View {
        switch block.kind {
        case .heading:
            Text(inline(block.text)).font(.system(size: 13, weight: .semibold)).padding(.top, 3)
        case .paragraph:
            Text(inline(block.text))
        case .bullet(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 10, alignment: .trailing)
                Text(inline(block.text)).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct LongNotificationBody: View {
    let message: Message
    let text: String
    var previewLines = 6
    @State private var expanded = false

    static func needsReader(_ text: String) -> Bool {
        text.prefix(321).count > 320 || text.lazy.filter(\.isNewline).prefix(7).count > 6
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotificationBody(
                text: text, summary: message.source == "agent_reminder",
                lineLimit: Self.needsReader(text) && !expanded ? previewLines : nil)
            if Self.needsReader(text) {
                HStack {
                    Button {
                        expanded.toggle()
                    } label: {
                        Label(expanded ? "收起" : "阅读全文", systemImage: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain).foregroundStyle(AppAppearance.accent)
                    .accessibilityLabel((expanded ? "收起：" : "展开全文：") + message.displayName)
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                    Text("\(text.count.formatted()) 字符")
                        .foregroundStyle(.tertiary)
                }.font(.caption)
            }
        }
    }
}
