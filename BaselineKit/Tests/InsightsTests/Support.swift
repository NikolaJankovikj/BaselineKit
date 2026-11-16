import Foundation
import HealthData

@testable import Forecasting
@testable import Insights

var testCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}

/// A Friday, 17:00.
let testNow = testCalendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 17))!

func day(_ daysAgo: Int) -> Date {
    testCalendar.date(byAdding: .day, value: -daysAgo, to: testCalendar.startOfDay(for: testNow))!
}

func assessed(_ metric: Metric, _ values: [Double?], expected: Band) -> MetricAssessment {
    MetricAssessment(
        metric: metric,
        days: values.enumerated().map { index, value in
            DayAssessment(day: day(values.count - 1 - index), observed: value, expected: expected, simple: nil, horizon: 1)
        },
        outlook: [])
}

func signal(_ metric: Metric?, _ observed: Double, _ lower: Double, _ upper: Double) -> AnomalyEvent.Signal {
    AnomalyEvent.Signal(metric: metric, observed: observed, expected: Band(lower: lower, median: (lower + upper) / 2, upper: upper), concern: 3)
}

func event(_ kind: AnomalyEvent.Kind, daysAgo: ClosedRange<Int>, signals: [AnomalyEvent.Signal], clinician: Bool = false) -> AnomalyEvent {
    AnomalyEvent(
        id: "\(kind.rawValue)-\(daysAgo.upperBound)", kind: kind, start: day(daysAgo.upperBound), end: day(daysAgo.lowerBound),
        severity: .notable, signals: signals, suggestsClinician: clinician)
}

let illness = event(
    .illnessWarning, daysAgo: 0...1,
    signals: [signal(.restingHeartRate, 64, 55, 59), signal(.respiratoryRate, 16.2, 14.2, 15), signal(.heartRateVariability, 38, 53, 69)],
    clinician: true)
let strain = event(.sustainedStrain, daysAgo: 23...25, signals: [signal(.heartRateVariability, 40, 54, 71), signal(.restingHeartRate, 62, 55, 59)])
let shortSleep = event(.deviation, daysAgo: 3...3, signals: [signal(.sleepDuration, 5.1, 7, 8.5)])
let stress: AnomalyEvent = {
    var event = event(.intradayStress, daysAgo: 0...0, signals: [signal(nil, 92, 70, 78)])
    event.start = day(0).addingTimeInterval(14 * 3600)
    event.end = day(0).addingTimeInterval(15.5 * 3600)
    return event
}()

func snapshot(
    metrics: [Metric: MetricAssessment] = [:], events: [AnomalyEvent] = [], logs: [ManualLog] = [], workouts: [Workout] = []
) -> HealthSnapshot {
    HealthSnapshot(metrics: metrics, events: events, logs: logs, workouts: workouts, calendar: testCalendar, now: testNow)
}
