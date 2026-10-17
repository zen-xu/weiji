import Foundation

struct ReminderHit: Codable, Identifiable {
    var id: String { message.id }
    let message: Message
    var ruleNames: [String]
    var isPreview = false
    var ruleIDs: [UUID] = []
}

struct ReminderEvaluation {
    var hits: [ReminderHit] = []
    var issues: [String] = []
}

/// Used only on the reminder queue; never blocks the UI, capture or database queues.
final class ReminderMatcher {
    private struct CompiledRule {
        let rule: ReminderRule
        let expressions: [UUID: NSRegularExpression]
    }
    private var configuration: [ReminderRule] = []
    private var compiled: [CompiledRule] = []
    private var suspended: Set<UUID> = []
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private let matchBudget: TimeInterval

    init(matchBudget: TimeInterval = 0.02) { self.matchBudget = matchBudget }

    func resetConfiguration() {
        configuration = []
        compiled = []
        suspended = []
    }

    func evaluate(_ messages: [Message], rules: [ReminderRule], deduplicate: Bool = true) -> ReminderEvaluation {
        var output = ReminderEvaluation()
        if configuration != rules {
            configuration = rules
            compiled = []
            suspended = []
            for rule in rules.prefix(ReminderRule.maximumRules) where rule.isEnabled {
                do {
                    try rule.validate()
                    var expressions: [UUID: NSRegularExpression] = [:]
                    for condition in rule.conditions where condition.comparison.isRegex {
                        expressions[condition.id] = try NSRegularExpression(
                            pattern: condition.value, options: rule.ignoreCase ? [.caseInsensitive] : [])
                    }
                    compiled.append(CompiledRule(rule: rule, expressions: expressions))
                } catch { output.issues.append("规则“\(rule.name)”无效，未执行。") }
            }
        }
        for message in messages {
            var names: [String] = []
            var ids: [UUID] = []
            for entry in compiled where !suspended.contains(entry.rule.id) {
                let key = "\(entry.rule.id)|\(message.id)"
                guard !deduplicate || !seen.contains(key) else { continue }
                do {
                    if try matches(message, entry: entry) {
                        names.append(entry.rule.name)
                        ids.append(entry.rule.id)
                        if deduplicate {
                            seen.insert(key)
                            seenOrder.append(key)
                        }
                    }
                } catch {
                    suspended.insert(entry.rule.id)
                    output.issues.append("规则“\(entry.rule.name)”匹配超时或内容过长，已暂停；请简化条件后重新保存。")
                }
            }
            if !names.isEmpty { output.hits.append(ReminderHit(message: message, ruleNames: names, ruleIDs: ids)) }
        }
        if seenOrder.count > 10_000 {
            let extra = seenOrder.count - 10_000
            for key in seenOrder.prefix(extra) { seen.remove(key) }
            seenOrder.removeFirst(extra)
        }
        return output
    }

    private func matches(_ message: Message, entry: CompiledRule) throws -> Bool {
        for condition in entry.rule.conditions {
            let matched = try matches(condition, message: message, entry: entry)
            if entry.rule.matchAll && !matched { return false }
            if !entry.rule.matchAll && matched { return true }
        }
        return entry.rule.matchAll
    }

    private func matches(_ condition: ReminderCondition, message: Message, entry: CompiledRule) throws -> Bool {
        // Unknown sender/type never satisfies even a negative condition.
        guard let value = condition.field.value(in: message) else { return false }
        var matched: Bool
        if let expression = entry.expressions[condition.id] {
            guard value.utf16.count <= 32_768 else { throw ListenerError("reminder_input_limit") }
            let deadline = ProcessInfo.processInfo.systemUptime + matchBudget
            var timedOut = false
            matched = false
            expression.enumerateMatches(
                in: value, options: [.reportProgress], range: NSRange(value.startIndex..., in: value)
            ) { result, _, stop in
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    timedOut = true
                    stop.pointee = true
                } else if result != nil {
                    matched = true
                    stop.pointee = true
                }
            }
            if timedOut { throw ListenerError("reminder_regex_timeout") }
        } else {
            let options: String.CompareOptions = entry.rule.ignoreCase ? [.caseInsensitive, .literal] : [.literal]
            switch condition.comparison {
            case .equals, .notEquals: matched = value.compare(condition.value, options: options) == .orderedSame
            default: matched = value.range(of: condition.value, options: options) != nil
            }
        }
        return condition.comparison.isNegative ? !matched : matched
    }
}

@MainActor
final class ReminderProcessor {
    // The state is private and every access runs on the serial queue below.
    private final class State: @unchecked Sendable {
        let matcher = ReminderMatcher()
    }
    private let queue = DispatchQueue(label: "local.xzy.WeChatListener.reminders", qos: .userInitiated)
    private let state = State()
    private var work = BackgroundWorkToken()

    func cancelPending() {
        work.cancel()
        work = BackgroundWorkToken()
    }
    func reset() {
        cancelPending()
        queue.async { [state] in state.matcher.resetConfiguration() }
    }

    func evaluate(_ messages: [Message], rules: [ReminderRule], completion: @escaping (ReminderEvaluation) -> Void) {
        let work = work
        queue.async { [state] in
            guard !work.isCancelled else { return }
            let result = state.matcher.evaluate(messages, rules: rules)
            DispatchQueue.main.async { if !work.isCancelled { completion(result) } }
        }
    }

    static func test(_ message: Message, rule: ReminderRule) async -> ReminderEvaluation {
        await Task.detached(priority: .userInitiated) {
            ReminderMatcher().evaluate([message], rules: [rule], deduplicate: false)
        }.value
    }
}
