import Foundation
import HealthData
import Testing

@testable import Forecasting

private func events(_ concerns: [Metric: [Double?]], baseline: BaselineState = .established) -> [AnomalyEvent] {
    var metrics = Dictionary(uniqueKeysWithValues: concerns.map { ($0, assessment($0, concerns: $1)) })
    let dayCount = concerns.values.first?.count ?? 0
    for metric in Metric.allCases where metrics[metric] == nil {
        metrics[metric] = assessment(metric, concerns: Array(repeating: 0, count: dayCount))
    }
    return AnomalyDetector.events(in: metrics, baseline: baseline)
}

@Test func twoVitalsAboveRangeOnTwoNightsIsAnIllnessWarning() throws {
    let found = events([
        .restingHeartRate: [0, 2.5, 3, 0],
        .respiratoryRate: [0, 1.5, 4, 0],
        .heartRateVariability: [0, 0, 2.2, 0],
    ])

    let warning = try #require(found.first)
    #expect(found.count == 1)
    #expect(warning.kind == .illnessWarning)
    #expect(TestClock.daysAgo(warning.start) == 2 && TestClock.daysAgo(warning.end) == 1)
    #expect(warning.signals.compactMap(\.metric) == [.respiratoryRate, .restingHeartRate, .heartRateVariability])
    #expect(warning.severity == .notable)
    #expect(!warning.suggestsClinician)
}

@Test func oneNightOfElevatedVitalsIsNotAnIllnessWarning() {
    let found = events([.restingHeartRate: [0, 3.5, 0], .wristTemperature: [0, 3.5, 0]])
    #expect(found.map(\.kind) == [.deviation])
}

@Test func clinicianIsSuggestedWhenTheWarningPersistsOrIsSevere() {
    let persistent = events([.restingHeartRate: [2, 2, 2, 2], .wristTemperature: [2, 2, 2, 2]])
    #expect(persistent.first?.suggestsClinician == true)
    #expect(persistent.first?.severity == .strong)

    let severe = events([.restingHeartRate: [0, 2, 2], .wristTemperature: [0, 2, 5.5]])
    #expect(severe.first?.suggestsClinician == true)
}

@Test func heartRateUpAndVariabilityDownForThreeNightsIsSustainedStrain() {
    let strained: [Double?] = [0, 1.5, 2.5, 1.5, 0]
    let found = events([.restingHeartRate: strained, .heartRateVariability: strained])
    #expect(found.map(\.kind) == [.sustainedStrain])

    let twoNights: [Double?] = [0, 1.5, 2.5, 0, 0]
    #expect(events([.restingHeartRate: twoNights, .heartRateVariability: twoNights]).map(\.kind) == [.deviation])
}

@Test func deviationsOfTheSameNightsAreOneEvent() throws {
    let found = events([
        .sleepDuration: [0, 2.1, 0, 0],
        .heartRateVariability: [0, 2.4, 1.5, 0],
    ])

    let event = try #require(found.first)
    #expect(found.count == 1)
    #expect(event.title == "Low heart rate variability and 1 more")
    // The variability run goes on for a night while the value stays outside its range.
    #expect(TestClock.daysAgo(event.start) == 2 && TestClock.daysAgo(event.end) == 1)
}

@Test func aSingleMildDeviationIsNotReported() {
    #expect(events([.sleepDuration: [0, 2.4, 0]]).isEmpty)
    #expect(events([.sleepDuration: [0, 3.2, 0]]).first?.title == "Short sleep")
    #expect(events([.heartRateVariability: [0, -4, 0], .steps: [0, 4, 0]]).isEmpty)
}

@Test func nothingIsFlaggedWhileTheBaselineIsLearning() {
    let concerns: [Metric: [Double?]] = [.restingHeartRate: [4, 4, 4], .wristTemperature: [4, 4, 4]]
    #expect(events(concerns, baseline: .learning(nights: 9)).isEmpty)
    #expect(!events(concerns).isEmpty)
}
