import Foundation
import HealthData
import Testing

@testable import Forecasting

@Test func standardizedResidualIsInSigmaUnitsOfTheBandWidth() {
    let band = Band(lower: 8, median: 10, upper: 12)
    #expect(abs(band.sigma - 4 / 2.5631) < 1e-12)
    #expect(abs(band.standardizedResidual(of: 13) - 3 / band.sigma) < 1e-12)
    #expect(band.contains(12) && !band.contains(12.01))
    #expect(Band(lower: 5, median: 5, upper: 5).standardizedResidual(of: 5.1).isFinite)
}

@Test func simpleAverageIsTheMeanAndSpreadOfRecentObservedValues() throws {
    let band = try #require(SimpleAverage.band(history: [.nan, 1, 2, 3]))
    let spread = (2.0 / 3).squareRoot()
    #expect(abs(band.median - 2) < 1e-12)
    #expect(abs(band.upper - (2 + 1.28155 * spread)) < 1e-4)
    #expect(abs(band.sigma - spread) < 1e-9)

    #expect(SimpleAverage.band(history: [1, .nan, 2]) == nil)
    let old = Array(repeating: 100.0, count: 12) + Array(repeating: 5.0, count: SimpleAverage.window)
    #expect(SimpleAverage.band(history: old)?.median == 5)
}

private func adaptive(_ observed: [Double]) -> (Int, Int) -> Band? {
    { origin, _ in unitBand(around: observed[origin]) }
}

@Test func rangeStaysFrozenWhileValuesKeepDeviating() {
    let observed: [Double] = [10, 10, 10, 20, 20, 20, 10]
    let selection = Anchoring.select(observed: observed, steps: 1...6, maxFrozenSteps: 7, threshold: 2, forecast: adaptive(observed))

    #expect(selection.horizons == [1, 1, 1, 2, 3, 4])
    #expect(selection.bands.map { $0?.median } == Array(repeating: 10, count: 6))
    #expect(selection.anchor == 6)
}

@Test func frozenRangeIsReleasedAfterTheLimit() {
    let observed: [Double] = [10, 10, 10, 20, 20, 20, 10]
    let selection = Anchoring.select(observed: observed, steps: 1...6, maxFrozenSteps: 2, threshold: 2, forecast: adaptive(observed))

    #expect(selection.horizons == [1, 1, 1, 2, 1, 1])
    #expect(selection.bands.map { $0?.median } == [10, 10, 10, 10, 20, 20])
}

@Test func aRunSurvivesAMissingValueAndABorderlineOne() {
    // 11.5 is inside 2σ but outside the range, so it does not end the run that 20 started.
    let observed: [Double] = [10, 10, 20, .nan, 11.5, 10]
    let selection = Anchoring.select(observed: observed, steps: 1...5, maxFrozenSteps: 7, threshold: 2, forecast: adaptive(observed))

    #expect(selection.horizons == [1, 1, 2, 3, 4])
    #expect(selection.anchor == 5)
}

@Test func readinessIs88WhenEverySignalIsAsExpectedAndDropsWithConcern() throws {
    let overnight = Metric.allCases.filter(\.isOvernight)
    var metrics = Dictionary(uniqueKeysWithValues: overnight.map { ($0, assessment($0, concerns: [0])) })
    #expect(Readiness(metrics)?.score == 88)

    metrics[.restingHeartRate] = assessment(.restingHeartRate, concerns: [3])
    let strained = try #require(Readiness(metrics))
    // 0.7 × 87.5 + 0.3 × 12.5
    #expect(strained.score == 65)
    #expect(strained.contributions.first?.metric == .restingHeartRate)

    metrics[.heartRateVariability] = assessment(.heartRateVariability, concerns: [-3])
    #expect(try #require(Readiness(metrics)).score > strained.score)
}

@Test func readinessUsesOnlyTheSignalsLastNightLeft() {
    let onlySleep = [Metric.sleepDuration: assessment(.sleepDuration, concerns: [1])]
    #expect(Readiness(onlySleep)?.score == 66)
    #expect(Readiness([.sleepDuration: assessment(.sleepDuration, concerns: [nil])]) == nil)
    #expect(Readiness([.steps: assessment(.steps, concerns: [0])]) == nil)
}

@Test func baselineIsEstablishedAfterFourteenNights() {
    #expect(BaselineState(nights: 13) == .learning(nights: 13))
    #expect(BaselineState(nights: 14).isEstablished)
}
