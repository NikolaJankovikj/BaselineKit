import Foundation
import HealthData

@testable import Forecasting

enum TestClock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// A Friday, 17:00.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 17))!

    static func daysAgo(_ date: Date) -> Int {
        calendar.dateComponents([.day], from: date, to: calendar.startOfDay(for: now)).day ?? .max
    }
}

func unitBand(around median: Double = 10) -> Band {
    Band(lower: median - Band.widthPerSigma / 2, median: median, upper: median + Band.widthPerSigma / 2)
}

func assessment(_ metric: Metric, concerns: [Double?]) -> MetricAssessment {
    let days = TestClock.calendar.days(count: concerns.count, endingAt: TestClock.now)
    let sign = metric.concerningDirection?.sign ?? 1
    return MetricAssessment(
        metric: metric,
        days: zip(days, concerns).map { day, concern in
            DayAssessment(day: day, observed: concern.map { 10 + sign * $0 }, expected: unitBand(), simple: nil, horizon: 1)
        },
        outlook: [])
}
