import Foundation

/// The `v8` date and time candidates for one instant in one time zone. Pure: the instant
/// and the zone are arguments (the shell injects its clock), and every field comes from a
/// Gregorian `Calendar.dateComponents`, so the output never depends on the user's locale.
public struct DateTimeTemplates: Sendable, Hashable {
    public let timeZone: TimeZone

    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    static let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

    /// In order: `2026-11-26`, `2026年11月26日`, `2026/11/26`, `2026-11-26 09:30`,
    /// `09:30:00`, `星期四`, ISO 8601 with offset (`2026-11-26T09:30:00+08:00`, `Z` at UTC),
    /// and the Unix timestamp in whole seconds.
    public func candidates(for date: Date) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let (year, month, day) = (c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        let (hour, minute, second) = (c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        func four(_ value: Int) -> String {
            let text = String(abs(value))
            return (value < 0 ? "-" : "") + String(repeating: "0", count: max(4 - text.count, 0)) + text
        }
        let isoDate = "\(four(year))-\(two(month))-\(two(day))"
        let clock = "\(two(hour)):\(two(minute))"
        let offset = timeZone.secondsFromGMT(for: date)
        let zone: String
        if offset == 0 {
            zone = "Z"
        } else {
            let minutes = abs(offset) / 60
            zone = (offset < 0 ? "-" : "+") + two(minutes / 60) + ":" + two(minutes % 60)
        }
        let weekday = Self.weekdays[((c.weekday ?? 1) - 1 + 7) % 7]
        let timestamp = Int64(date.timeIntervalSince1970.rounded(.down))
        return [
            isoDate,
            "\(year)年\(month)月\(day)日",
            "\(four(year))/\(two(month))/\(two(day))",
            "\(isoDate) \(clock)",
            "\(clock):\(two(second))",
            weekday,
            "\(isoDate)T\(clock):\(two(second))\(zone)",
            String(timestamp),
        ]
    }
}
