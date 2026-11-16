import Foundation
import HealthData
import Testing

@testable import Forecasting

/// The whole daily pipeline on the synthetic person, with the real model.
private struct Scenario {
    var history: DailyHistory
    var result: DailyForecastEngine.Result
    var baseline: BaselineState
    var events: [AnomalyEvent]

    init(_ scenario: SyntheticProvider.Scenario, depth: Int = 45) async throws {
        let provider = SyntheticProvider(scenario: scenario, now: TestClock.now, calendar: TestClock.calendar)
        history = try await provider.dailyHistory(days: 400)
        result = try await DailyForecastEngine(calendar: TestClock.calendar).assess(history, depth: depth)
        baseline = BaselineState(nights: history.nightsOfData)
        events = AnomalyDetector.events(in: result.metrics, baseline: baseline)
    }
}

@Test func sickWeekRaisesAnIllnessWarningThatPersistsToToday() async throws {
    let sick = try await Scenario(.sickWeek)

    let warning = try #require(sick.events.first { $0.kind == .illnessWarning })
    #expect(TestClock.daysAgo(warning.start) == 3 && TestClock.daysAgo(warning.end) == 0)
    #expect(warning.suggestsClinician)
    #expect(warning.signals.count >= 3)

    // The expected range stays where it was before the illness instead of adapting to it.
    let restingHeartRate = try #require(sick.result.metrics[.restingHeartRate])
    #expect(restingHeartRate.days.suffix(4).map(\.horizon) == [1, 2, 3, 4])
    let readiness = try #require(Readiness(sick.result.metrics))
    #expect(readiness.score < 50)
}

@Test func healthyHistoryHasItsScriptedEventsAndNoIllnessWarning() async throws {
    let healthy = try await Scenario(.healthy)

    #expect(!healthy.events.contains { $0.kind == .illnessWarning })
    #expect(try #require(Readiness(healthy.result.metrics)).score > 70)

    let strain = try #require(healthy.events.first { $0.kind == .sustainedStrain })
    #expect(TestClock.daysAgo(strain.end) == 23)
    let afterAlcohol = try #require(healthy.events.first { TestClock.daysAgo($0.end) == 12 })
    #expect(afterAlcohol.signals.count >= 2)
    #expect(healthy.events.contains { TestClock.daysAgo($0.end) == 40 && $0.title == "Short sleep" })
}

@Test func coldStartShowsProvisionalRangesAndFlagsNothing() async throws {
    let cold = try await Scenario(.coldStart)

    #expect(cold.baseline == .learning(nights: 9))
    #expect(cold.events.isEmpty)
    let today = try #require(cold.result.metrics[.restingHeartRate]?.days.last)
    #expect(today.expected != nil)
    #expect(Readiness(cold.result.metrics) != nil)
    // Too little history at first for any range.
    #expect(cold.result.metrics[.restingHeartRate]?.days.first?.expected == nil)
}

@Test func todaysRunningTotalsAreShownButNotScored() async throws {
    let healthy = try await Scenario(.healthy, depth: 10)

    let steps = try #require(healthy.result.metrics[.steps])
    #expect(steps.days.last?.observed == nil)
    #expect(steps.days.last?.expected != nil)
    #expect(try #require(steps.runningTotal) > 0)
    #expect(steps.outlook.count == DailyForecastEngine.outlookDays)
    #expect(steps.outlook.allSatisfy { $0.expected != nil && $0.simple != nil })
}

@Test func cachedForecastsAreReused() async throws {
    let first = try await Scenario(.healthy, depth: 10)
    let engine = DailyForecastEngine(calendar: TestClock.calendar)
    let again = try await engine.assess(first.history, depth: 10, cache: first.result.newForecasts)

    // Everything but today's still-changing forecast came from the cache.
    #expect(!first.result.newForecasts.isEmpty)
    #expect(again.newForecasts.isEmpty)
    #expect(again.metrics == first.result.metrics)
}

@Test func jointModeForecastsEveryMetricFromOneGroup() async throws {
    let provider = SyntheticProvider(scenario: .healthy, now: TestClock.now, calendar: TestClock.calendar)
    let history = try await provider.dailyHistory(days: 120)
    let joint = DailyForecastEngine(mode: .joint, calendar: TestClock.calendar)
    let result = try await joint.assess(history, logs: provider.logs, depth: 5)

    for metric in Metric.allCases {
        #expect(result.metrics[metric]?.days.last?.expected != nil, "\(metric)")
    }
    #expect(result.newForecasts.keys.allSatisfy { $0.hasPrefix("joint|") })
}

@Test func backtestComparesTheModelWithTheSimpleAverage() async throws {
    let healthy = try await Scenario(.healthy)
    let engine = DailyForecastEngine(calendar: TestClock.calendar)
    let (scores, _) = try await engine.backtest(healthy.history, depth: 40, cache: healthy.result.newForecasts)

    let restingHeartRate = try #require(scores.first { $0.metric == .restingHeartRate })
    #expect(restingHeartRate.days > 30)
    // A q10–q90 band should hold roughly four values in five.
    #expect((0.6...0.95).contains(restingHeartRate.modelCoverage))
    #expect((0.6...0.95).contains(restingHeartRate.simpleCoverage))
    #expect(restingHeartRate.modelError < 2 * restingHeartRate.simpleError)
}

@Test func stressEpisodeIsFoundAndSleepIsNotScored() async throws {
    let provider = SyntheticProvider(scenario: .healthy, now: TestClock.now, calendar: TestClock.calendar)
    let intraday = try await provider.intradayHistory(hours: 36)
    let stress = try await StressEstimator().assess(intraday, baseline: .established)

    let episode = try #require(stress.events.first)
    #expect(stress.events.count == 1)
    #expect(episode.kind == .intradayStress)
    // The synthetic person had a tense 90 minutes that began four and a half hours ago.
    let began = TestClock.now.addingTimeInterval(-4.5 * 3600)
    #expect(abs(episode.start.timeIntervalSince(began)) <= 600)
    #expect(episode.end.timeIntervalSince(episode.start) >= 60 * 60)

    #expect(stress.points.count == 12 * 12)
    let asleep = stress.points.filter { TestClock.calendar.component(.hour, from: $0.time) < 7 }
    #expect(asleep.allSatisfy { $0.score == nil && $0.expected == nil })
    #expect(stress.level == .low)

    let learning = try await StressEstimator().assess(intraday, baseline: .learning(nights: 3))
    #expect(learning.events.isEmpty)
}
