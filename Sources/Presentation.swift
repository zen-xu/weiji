import Foundation

// Presentation is derived; never replace the archived notification or its identity.
struct MessagePresentation: Codable, Equatable {
    var sender: String?
    var senderSource: String
    var body: String
    var isGroup: Bool
    var isInferredGroup: Bool
    var kindLabel: String
    enum CodingKeys: String, CodingKey {
        case sender, body
        case senderSource = "sender_source", isGroup = "is_group"
        case isInferredGroup = "is_inferred_group", kindLabel = "kind_label"
    }

    init(_ message: Message) {
        sender = nil; senderSource = "not_provided"; body = message.body
        isGroup = message.conversationKind == "group"
        isInferredGroup = false
        kindLabel = message.kindLabel
        if message.conversationKind == "direct" {
            sender = message.senderDisplayName ?? message.displayName
            senderSource = "notification_title"
            return // Colons in direct-message content are not sender separators.
        }
        let subtitle = message.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = (message.senderDisplayName ?? subtitle).trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty && explicit != message.title {
            sender = explicit; senderSource = "notification_sender"
            // Only strip a duplicate prefix if it matches the explicitly supplied sender.
            if let split = Self.split(message.body), split.sender == explicit { body = split.body }
        } else if let split = Self.split(message.body) {
            sender = split.sender; body = split.body; senderSource = "body_prefix_inferred"
            if !isGroup { isInferredGroup = true }
        }
        if !isGroup && (!subtitle.isEmpty && subtitle != message.title) { isInferredGroup = true }
        if !isGroup && message.conversationName.contains("群") { isInferredGroup = true }
        if isInferredGroup { kindLabel = "疑似群聊" }
    }

    private static func split(_ body: String) -> (sender: String, body: String)? {
        // Prefer a conservative, single-line nickname prefix; preserve everything after it.
        guard let colon = body.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let prefix = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
        let rest = body[body.index(after: colon)...]
        guard !prefix.isEmpty, prefix.count <= 40,
              !prefix.contains(where: { $0.isNewline }),
              prefix.rangeOfCharacter(from: .letters) != nil,
              !prefix.contains("/"), !prefix.contains("\\"),
              !["http", "https", "ftp", "file", "mailto", "tel", "data"].contains(prefix.lowercased()),
              !rest.hasPrefix("//"),
              body[colon] == "：" || rest.first == " " || rest.first == "\t" else { return nil }
        // Summary notifications are not a single reliably attributable message.
        guard !prefix.hasPrefix("["), !prefix.hasPrefix("【") else { return nil }
        let text = rest.drop(while: { $0 == " " || $0 == "\t" })
        guard !text.isEmpty else { return nil }
        return (prefix, String(text))
    }
}

extension Message {
    var presentation: MessagePresentation { MessagePresentation(self) }
}

extension Conversation {
    var displayName: String { name.isEmpty ? "未命名会话" : name }
    var showsGroupIcon: Bool { kind == "group" || inferredGroup }
}
