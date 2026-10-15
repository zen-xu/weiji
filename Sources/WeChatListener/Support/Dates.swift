import Foundation

enum Dates {
    // Each library queue owns its thread's formatters; never share mutable formatters across readers and writers.
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let key = fractional ? "local.wechat-listener.iso.fractional" : "local.wechat-listener.iso.seconds"
        if let cached = Thread.current.threadDictionary[key] as? ISO8601DateFormatter { return cached }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions =
            fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        Thread.current.threadDictionary[key] = formatter
        return formatter
    }
    static func string(_ date: Date) -> String {
        formatter(fractional: true).string(from: date)
    }
    static func parse(_ value: String) -> Date? {
        formatter(fractional: true).date(from: value) ?? formatter(fractional: false).date(from: value)
    }
    static func day(_ value: String, end: Bool = false) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw ListenerError("日期必须为 YYYY-MM-DD")
        }
        return string(end ? Calendar.current.date(byAdding: .day, value: 1, to: date)! : date)
    }
}
