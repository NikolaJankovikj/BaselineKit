import Foundation
import HealthData
import Insights
import Testing

@testable import Forecasting
@testable import Persistence

private let night = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let band = Band(lower: 55, median: 57, upper: 59)

private func event(nights: Int) -> AnomalyEvent {
    AnomalyEvent(
        id: "illnessWarning-1", kind: .illnessWarning, start: night, end: night.addingTimeInterval(Double(nights - 1) * 86_400),
        severity: .notable, signals: [AnomalyEvent.Signal(metric: .restingHeartRate, observed: 64, expected: band, concern: 3)])
}

private func temporaryDirectory() -> URL {
    URL.temporaryDirectory.appending(path: "BaselineStoreTests-\(UUID().uuidString)")
}

@MainActor @Test func journalAndForecastsSurviveARestart() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = ManualLog(date: night, kind: .alcohol)
    let insight = Sourced(AnomalyInsight(summary: "s", likelyContributors: ["c"], suggestion: "rest"), source: .template)

    let store = Store(directory: directory)
    store.add(log)
    store.add(ManualLog(date: night, kind: .caffeine))
    store.remove(store.logs[1])
    store.setFeedback(Feedback(verdict: .makesSense, tags: [.illness, .travel]), for: event(nights: 2))
    store.setInsight(insight, for: event(nights: 2))
    store.addForecasts(["univariate|steps|1": OriginForecast(steps: [band])])

    let reopened = Store(directory: directory)
    #expect(reopened.logs == [log])
    #expect(reopened.feedback(for: event(nights: 2)) == Feedback(verdict: .makesSense, tags: [.illness, .travel]))
    #expect(reopened.insight(for: event(nights: 2)) == insight)
    #expect(reopened.forecasts == ["univariate|steps|1": OriginForecast(steps: [band])])
}

@MainActor @Test func anEventThatGrewNeedsANewExplanationButKeepsItsFeedback() {
    let store = Store(directory: nil)
    store.setFeedback(Feedback(verdict: .falseAlarm), for: event(nights: 2))
    store.setInsight(Sourced(AnomalyInsight(summary: "two nights", likelyContributors: [], suggestion: ""), source: .template), for: event(nights: 2))

    #expect(store.insight(for: event(nights: 3)) == nil)
    #expect(store.feedback(for: event(nights: 3)).verdict == .falseAlarm)
    #expect(store.feedback(for: AnomalyEvent(id: "other", kind: .deviation, start: night, end: night, severity: .mild, signals: [])) == Feedback())
}

@MainActor @Test func erasingRemovesTheFiles() {
    let directory = temporaryDirectory()
    let store = Store(directory: directory)
    store.add(ManualLog(date: night, kind: .stress))
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "journal.json").path))

    store.eraseAll()
    #expect(store.logs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(Store(directory: directory).logs.isEmpty)
}

@Test func csvHasOneRowPerDayAndBlanksForMissingValues() {
    let days = [
        DayAssessment(day: Date(timeIntervalSince1970: 0), observed: 58, expected: nil, simple: nil, horizon: 1),
        DayAssessment(day: Date(timeIntervalSince1970: 86_400), observed: nil, expected: band, simple: nil, horizon: 1),
    ]
    let csv = dailyCSV([.restingHeartRate: MetricAssessment(metric: .restingHeartRate, days: days, outlook: [])])

    #expect(csv == """
        date,restingHeartRate,restingHeartRate_expected_low,restingHeartRate_expected_high
        1970-01-01,58.0,,
        1970-01-02,,55.0,59.0

        """)
}
