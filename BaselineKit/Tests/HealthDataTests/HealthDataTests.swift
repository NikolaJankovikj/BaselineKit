import Foundation
import Testing

@testable import HealthData

private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}

private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

/// A Friday, 17:00.
private let now = date(13, 17)

@Test func aNightBelongsToTheDayOfWakingUp() {
    #expect(SleepDay.day(containing: date(9, 23, 30), calendar: calendar) == date(10, 0))
    #expect(SleepDay.day(containing: date(10, 3), calendar: calendar) == date(10, 0))
    #expect(SleepDay.day(containing: date(9, 17, 59), calendar: calendar) == date(9, 0))
    #expect(SleepDay.day(containing: date(9, 18), calendar: calendar) == date(10, 0))
}

@Test func overlappingSleepRecordsCountOnce() {
    let watch = DateInterval(start: date(9, 22), end: date(10, 2))
    let phone = DateInterval(start: date(10, 1), end: date(10, 6))
    let nap = DateInterval(start: date(10, 13), end: date(10, 13, 30))
    #expect(SleepDay.hoursCovered(by: [nap, phone, watch]) == 8.5)
    #expect(SleepDay.merged([phone, watch]) == [DateInterval(start: date(9, 22), end: date(10, 6))])
}

@Test func syntheticHistoryIsRepeatableAndEndsToday() async throws {
    let provider = SyntheticProvider(scenario: .healthy, now: now, calendar: calendar)
    let history = try await provider.dailyHistory(days: 400)
    let again = try await provider.dailyHistory(days: 400)

    #expect(history.days.count == 400)
    #expect(history.days.last == date(13, 0))
    for metric in Metric.allCases {
        #expect(history.series(metric).count == 400)
        #expect(history.series(metric).map(\.bitPattern) == again.series(metric).map(\.bitPattern))
    }
    // 17:00: about 70% of the day's steps so far.
    let steps = history.series(.steps)
    #expect(try #require(steps.last) < 0.9 * steps.dropLast().suffix(30).reduce(0, +) / 30)
    #expect(history.nightsOfData > 370)
    #expect(!history.workouts.isEmpty)
}

@Test func sickWeekLiftsVitalsOverTheLastFourNights() async throws {
    let sick = try await SyntheticProvider(scenario: .sickWeek, now: now, calendar: calendar).dailyHistory(days: 120)
    func rise(_ metric: Metric) -> Double {
        let values = sick.series(metric)
        let before = values.dropLast(4).suffix(30).filter(\.isFinite)
        return values.suffix(4).reduce(0, +) / 4 - before.reduce(0, +) / Double(before.count)
    }
    #expect(rise(.restingHeartRate) > 4)
    #expect(rise(.respiratoryRate) > 1)
    #expect(rise(.wristTemperature) > 0.4)
    #expect(rise(.heartRateVariability) < -8)
}

@Test func coldStartHasNineDaysAndNoLogs() async throws {
    let provider = SyntheticProvider(scenario: .coldStart, now: now, calendar: calendar)
    let history = try await provider.dailyHistory(days: 400)
    #expect(history.days.count == 9)
    #expect(history.nightsOfData == 9)
    #expect(provider.logs.isEmpty)
    #expect(SyntheticProvider(scenario: .healthy, now: now, calendar: calendar).logs.map(\.kind) == [.alcohol, .hardTraining])
}

@Test func intradayHistoryHasFiveMinuteBinsAndMasksSleep() async throws {
    let intraday = try await SyntheticProvider(scenario: .healthy, now: now, calendar: calendar).intradayHistory(hours: 36)

    #expect(intraday.heartRate.count == 36 * 12)
    #expect(intraday.steps.count == intraday.heartRate.count && intraday.isMasked.count == intraday.heartRate.count)
    #expect(intraday.time(ofBin: intraday.heartRate.count) == now)
    for bin in intraday.isMasked.indices where calendar.component(.hour, from: intraday.time(ofBin: bin)) < 7 {
        #expect(intraday.isMasked[bin] && intraday.steps[bin] == 0)
    }
    #expect(intraday.heartRate.contains { $0.isNaN } && intraday.heartRate.contains { $0.isFinite })
}
