import Foundation

enum ReminderField: String, Codable, CaseIterable, Identifiable {
    case conversation, sender, body, conversationKind
    var id: Self { self }
    var label: String {
        switch self {
        case .conversation: return "会话 / 频道"
        case .sender: return "发送者"
        case .body: return "消息内容"
        case .conversationKind: return "会话类型"
        }
    }
    func value(in message: Message) -> String? {
        switch self {
        case .conversation: return NotificationDecoder.nonempty(message.conversationName)
        case .sender: return NotificationDecoder.nonempty(message.senderDisplayName)
        case .body: return message.body
        case .conversationKind:
            switch message.conversationKind {
            case "group": return "群聊"
            case "direct": return "私聊"
            default: return nil
            }
        }
    }
}

enum ReminderComparison: String, Codable, CaseIterable, Identifiable {
    case contains, equals, regex, notContains, notEquals, notRegex
    var id: Self { self }
    var label: String {
        switch self {
        case .contains: return "包含"
        case .equals: return "等于"
        case .regex: return "匹配正则"
        case .notContains: return "不包含"
        case .notEquals: return "不等于"
        case .notRegex: return "不匹配正则"
        }
    }
    var isRegex: Bool { self == .regex || self == .notRegex }
    var isNegative: Bool { self == .notContains || self == .notEquals || self == .notRegex }
}

struct ReminderCondition: Codable, Identifiable, Equatable {
    var id = UUID()
    var field: ReminderField = .body
    var comparison: ReminderComparison = .contains
    var value = ""
}

struct ReminderRule: Codable, Identifiable, Equatable {
    static let maximumRules = 32
    static let maximumConditions = 12
    var id = UUID()
    var name = ""
    var isEnabled = true
    var matchAll = true
    var ignoreCase = true
    var conditions = [ReminderCondition()]

    var summary: String {
        conditions.map { "\($0.field.label)\($0.comparison.label)“\($0.value)”" }
            .joined(separator: matchAll ? "，且 " : "，或 ")
    }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else {
            throw ListenerError("请填写规则名称，最多 80 个字符。")
        }
        guard !conditions.isEmpty, conditions.count <= Self.maximumConditions else {
            throw ListenerError("每条规则需要 1–\(Self.maximumConditions) 个条件。")
        }
        for (index, condition) in conditions.enumerated() {
            guard !condition.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                condition.value.utf16.count <= 2048
            else { throw ListenerError("条件 \(index + 1) 的值不能为空，最多 2048 个字符。") }
            if condition.comparison.isRegex {
                do {
                    _ = try NSRegularExpression(pattern: condition.value, options: ignoreCase ? [.caseInsensitive] : [])
                } catch { throw ListenerError("条件 \(index + 1) 的正则表达式无效，请检查括号和转义。") }
            }
        }
    }
}
