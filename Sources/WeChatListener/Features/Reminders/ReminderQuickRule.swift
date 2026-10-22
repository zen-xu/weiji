import Foundation

enum ReminderQuickRule {
    enum Kind: CaseIterable, Identifiable {
        case conversation, sender, everyone
        var id: Self { self }
        var label: String {
            switch self {
            case .conversation: "关注此会话的消息…"
            case .sender: "关注此会话中的发送者…"
            case .everyone: "此会话 @所有人时提醒…"
            }
        }
    }
    static func make(message: Message, kind: Kind) -> ReminderRule? {
        guard let conversation = NotificationDecoder.nonempty(message.conversationName),
            conversation.utf16.count <= 2048
        else { return nil }
        var conditions = [ReminderCondition(field: .conversation, comparison: .equals, value: conversation)]
        var name = conversation
        switch kind {
        case .conversation: break
        case .sender:
            // A direct conversation already identifies the contact. Never promote an inferred body prefix to sender identity.
            if message.conversationKind != "direct" {
                guard let sender = NotificationDecoder.nonempty(message.senderDisplayName), sender.utf16.count <= 2048
                else { return nil }
                conditions.append(ReminderCondition(field: .sender, comparison: .equals, value: sender))
                name += " · " + sender
            }
        case .everyone:
            guard message.conversationKind != "direct" else { return nil }
            conditions.append(ReminderCondition(field: .body, comparison: .regex, value: #"[@＠]\s*了?\s*所有人"#))
            name += " · @所有人"
        }
        return ReminderRule(
            name: String(name.prefix(80)), ignoreCase: false, conditions: conditions,
            sources: [message.notificationPlatform ?? .wechat])
    }
}
