import Foundation

struct Conversation: Identifiable {
    var id: String
    var name: String
    var kind: String
    var identitySource: String
    var preview: String
    var lastAt: String
    var count: Int
    var inferredGroup = false
    var kindLabel: String { kind == "group" ? "群聊" : kind == "direct" ? "私聊" : inferredGroup ? "疑似群聊" : "通知分组" }
}
