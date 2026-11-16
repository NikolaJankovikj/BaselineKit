import Foundation

/// The "sleep day" convention: a night belongs to the day you wake up on, and that day
/// runs from 18:00 the evening before to 18:00.
enum SleepDay {
    static let startsHoursBeforeMidnight = 6

    static func day(containing date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date.addingTimeInterval(Double(startsHoursBeforeMidnight) * 3600))
    }

    /// Hours covered by the intervals, counting overlaps once: the phone and the watch
    /// can both record the same night.
    static func hoursCovered(by intervals: [DateInterval]) -> Double {
        merged(intervals).reduce(0) { $0 + $1.duration } / 3600
    }

    static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }
}
