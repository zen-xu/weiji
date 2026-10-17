import Foundation

/// Wall-clock minutes in the Mac's current time zone. Calendar arithmetic also handles DST.
struct ReminderQuietHours: Codable, Equatable {
    var startMinute = 22 * 60
    var endMinute = 8 * 60

    func validate() throws {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute), startMinute != endMinute else {
            throw ListenerError("安静时段须为有效时间，开始与结束不能相同。")
        }
    }
    func nextAllowedDate(after date: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let quiet =
            startMinute < endMinute
            ? minute >= startMinute && minute < endMinute
            : minute >= startMinute || minute < endMinute
        guard quiet else { return date }
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: endMinute / 60, minute: endMinute % 60, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first) ?? date.addingTimeInterval(3600)
    }
}
