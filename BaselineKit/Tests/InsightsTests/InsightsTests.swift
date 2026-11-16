import Foundation
import FoundationModels
import HealthData
import Testing

@testable import Forecasting
@testable import Insights

// MARK: Facts and templates

@Test func factsSayWhenAnEventHappened() {
    let now = snapshot()
    #expect(now.when(illness) == "over the last 2 nights")
    #expect(now.when(event(.deviation, daysAgo: 0...0, signals: [])) == "last night")
    #expect(now.when(shortSleep).hasPrefix("on the night to "))
    #expect(now.when(strain).hasPrefix("over the 3 nights to "))
    #expect(now.when(stress) == "today from 14:00 to 15:30")
}

@Test func templateNamesWhatMovedInWhichDirection() {
    let insight = TemplatedInsights.insight(for: EventFacts(illness, in: snapshot()))

    #expect(insight.summary.hasPrefix(
        "Your resting heart rate and respiratory rate were above your expected range and your heart rate variability below it over the last 2 nights."))
    #expect(insight.likelyContributors.count == 3)
    #expect(TemplatedInsights.insight(for: EventFacts(shortSleep, in: snapshot())).summary.hasPrefix("Your sleep was below your expected range"))
    #expect(TemplatedInsights.insight(for: EventFacts(stress, in: snapshot())).summary.contains("above what your activity explains today from 14:00 to 15:30"))
}

@Test func theUsersOwnContextBecomesTheContributors() {
    let evening = day(4).addingTimeInterval(20 * 3600)
    let energy = Array(repeating: 500.0 as Double?, count: 30) + [900, 900, 900] + [500, 500, 500, 500]
    let context = snapshot(
        metrics: [.activeEnergy: assessed(.activeEnergy, energy, expected: Band(lower: 300, median: 500, upper: 700))],
        logs: [ManualLog(date: evening, kind: .alcohol), ManualLog(date: day(20), kind: .caffeine)],
        workouts: [Workout(start: evening, kind: "Long run", minutes: 95, energy: 700)])
    let facts = EventFacts(shortSleep, in: context, tags: [.travel])

    #expect(facts.context.count == 4)
    #expect(facts.context[0] == "You tagged this: travel")
    #expect(facts.context[1].hasPrefix("Alcohol logged on "))
    #expect(facts.context[2].hasPrefix("A 95-minute long run on "))
    #expect(facts.context[3] == "Training load in the days before was above your usual")
    #expect(TemplatedInsights.insight(for: facts).likelyContributors == Array(facts.context.prefix(3)))
    let sleep = Metric.sleepDuration
    #expect(facts.prompt.contains(
        "Below their expected range:\n- sleep: \(sleep.formattedWithUnit(5.1)), below the expected \(sleep.formatted(7))–\(sleep.formatted(8.5))"))
    #expect(!facts.prompt.contains("Above their expected range:"))
    #expect(EventFacts(shortSleep, in: snapshot()).prompt.hasSuffix("Known context: none"))
}

@Test func everyTemplatePassesTheGuardItReplaces() {
    for event in [illness, strain, shortSleep, stress] {
        let facts = EventFacts(event, in: snapshot())
        let insight = TemplatedInsights.insight(for: facts)
        #expect(InsightGuard.accepts(insight.allText, source: facts.prompt), "\(event.kind)")
    }
}

// MARK: Guard

@Test func guardRejectsNumbersThatAreNotInTheFacts() {
    let facts = "- resting heart rate: 64 bpm (expected 55–59)\n- respiratory rate: 16,2 br/min"
    #expect(InsightGuard.accepts("Your resting heart rate was 64, above 55 to 59. Breathing was at 16.2.", source: facts))
    #expect(InsightGuard.inventedNumbers(in: "Aim for 8 hours of sleep; your heart rate was 64.", source: facts) == ["8"])
    #expect(InsightGuard.inventedNumbers(in: "It rose by 9.5.", source: facts) == ["9.5"])
    // By value: the model drops the decimal that the app's formatting keeps.
    #expect(InsightGuard.inventedNumbers(in: "You slept 5 hours, below 7 to 8.5.", source: "sleep 5,0 h, below the expected 7,0–8,5").isEmpty)
}

@Test func guardRejectsDiagnosisAndMedicationLanguage() {
    #expect(InsightGuard.diagnosisTerms(in: "This could be a viral infection.") == ["infection", "viral"])
    #expect(!InsightGuard.accepts("Consider taking ibuprofen.", source: ""))
    #expect(!InsightGuard.accepts("You have a fever.", source: ""))
    #expect(InsightGuard.accepts("Rest, drink water and go to bed early.", source: ""))
}

@Test func guardRejectsASignalOnTheWrongSideOfItsRange() {
    let facts = EventFacts(strain, in: snapshot()).prompt
    // What the model once wrote about this event: both signals lumped on one side.
    #expect(InsightGuard.misplacedSignals(in: "Your heart rate variability and resting heart rate are below expectations.", source: facts) == ["resting heart rate"])
    #expect(InsightGuard.misplacedSignals(in: "Resting heart rate and heart rate variability were all elevated.", source: facts) == ["heart rate variability"])
    #expect(!InsightGuard.accepts("Your resting heart rate was low.", source: facts))

    #expect(InsightGuard.accepts("Your resting heart rate was above and your heart rate variability below your expected range.", source: facts))
    #expect(InsightGuard.accepts("Heart rate variability was lower than expected. Resting heart rate was higher.", source: facts))
    // A direction without a signal, and a signal the facts say nothing about, are left alone.
    #expect(InsightGuard.accepts("Several signals were elevated. Sleep was low.", source: facts))
}

// MARK: Guided generation

@Test func generableTypesRoundTripThroughGeneratedContent() throws {
    let insight = AnomalyInsight(summary: "s", likelyContributors: ["a", "b"], suggestion: "rest")
    #expect(try AnomalyInsight(insight.generatedContent) == insight)
    let wording = try WeekWording(GeneratedContent(properties: ["headline": "h", "focusForNextWeek": "f"]))
    #expect(try WeekWording(wording.generatedContent).headline == "h")

    // Building a schema validates it.
    for schema in [AnomalyInsight.generationSchema, WeekWording.generationSchema, MetricAdvice.generationSchema] {
        #expect(!schema.debugDescription.isEmpty)
    }
}

@Test(.enabled(if: !SystemLanguageModel.default.isAvailable))
func withoutAppleIntelligenceTheTemplateIsUsed() async {
    let facts = EventFacts(illness, in: snapshot())
    let explained = await InsightGenerator().insight(for: facts)
    #expect(explained == Sourced(TemplatedInsights.insight(for: facts), source: .template))
    #expect(await InsightGenerator().weeklyReport(for: WeekFacts(snapshot())).source == .template)
}

/// Needs a device with Apple Intelligence turned on; skipped elsewhere.
@Test(.enabled(if: SystemLanguageModel.default.isAvailable), arguments: [illness, strain, shortSleep, stress])
func modelOutputParsesAndStaysWithinTheFacts(event: AnomalyEvent) async throws {
    let facts = EventFacts(event, in: snapshot())
    let insight = try #require(await InsightGenerator().generate(AnomalyInsight.self, from: "Explain this event.\n\(facts.prompt)"))

    #expect(!insight.summary.isEmpty && !insight.suggestion.isEmpty)
    #expect((1...3).contains(insight.likelyContributors.count))
    #expect(InsightGuard.inventedNumbers(in: insight.allText, source: facts.prompt).isEmpty)
    #expect(InsightGuard.diagnosisTerms(in: insight.allText).isEmpty)
}

// MARK: Snapshot summaries and Ask

let week = snapshot(
    metrics: [
        .sleepDuration: assessed(.sleepDuration, [7.5, 7.5, 7.5, 7.5, 7.5, 7.5, 7.5, 8, 8, 8, 8, 8, 8, 5], expected: Band(lower: 7, median: 7.75, upper: 8.5)),
        .restingHeartRate: assessed(.restingHeartRate, [60, 60, 60, 60, 60, 60, 60, 56, 56, 56, 56, nil, 56, 56], expected: Band(lower: 55, median: 57, upper: 59)),
    ],
    events: [shortSleep, strain],
    logs: [ManualLog(date: day(2), kind: .caffeine)],
    workouts: [Workout(start: day(1), kind: "Run", minutes: 42.4, energy: 318), Workout(start: day(30), kind: "Ride", minutes: 60, energy: 500)])

@Test func summariesAreShortAndFormattedByCode() {
    // Above, below or within is said in words: the model is not asked to compare numbers.
    let lastNight = week.sleepSummary(for: testNow)
    // The night is named as people name it, and each side of the range has its own line.
    let lines = lastNight.split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines[0].hasPrefix("Last night (") && lines[0].hasSuffix("): 1 of 2 overnight signals were outside their expected range."))
    #expect(lines[1].hasPrefix("Below their expected range: sleep \(Metric.sleepDuration.formattedWithUnit(5)), below the expected "))
    #expect(lines[2] == "Within their expected range: resting heart rate 56 bpm, within the expected 55–59.")
    #expect(week.sleepSummary(for: day(2)).hasPrefix("Tuesday night ("))
    #expect(week.sleepSummary(for: day(40)).hasPrefix("No overnight data for "))

    let stats = week.statsSummary(of: .restingHeartRate, days: 7)
    #expect(stats.hasPrefix("Resting heart rate over the last 7 days: average 56 bpm, lowest 56, highest 56."))
    #expect(stats.contains("Latest, today ("))
    #expect(stats.contains("56 bpm, within the expected 55–59. "))
    // Zero counts are not mentioned: the model read "7 above and 0 below" as "none outside".
    #expect(stats.hasSuffix("All 6 days were within their expected range."))
    #expect(week.statsSummary(of: .sleepDuration, days: 7).hasSuffix("Of 7 days, 1 was below their expected range."))
    #expect(week.statsSummary(of: .restingHeartRate, days: 14).hasSuffix("Of 13 days, 7 were above their expected range."))
    #expect(week.statsSummary(of: .vo2Max, days: 7) == "No cardio fitness data in the last 7 days.")

    #expect(week.workoutsSummary(days: 7).hasPrefix("Workouts in the last 7 days: Run, 42 min, 318 kcal yesterday ("))
    #expect(week.workoutsSummary(days: 1) == "No workouts in the last 1 days.")
    #expect(week.logsSummary(days: 7).hasPrefix("Logged in the last 7 days: Caffeine on "))
    let flagged = week.anomaliesSummary(days: 7).split(separator: "\n")
    #expect(flagged.count == 3 && flagged[0] == "Flagged in the last 7 days:" && flagged[1].hasPrefix("Short sleep, on the night to "))
    #expect(flagged.last?.hasPrefix("Below their expected range: sleep ") == true)
    #expect(week.anomaliesSummary(days: 2) == "Nothing was flagged in the last 2 days.")
}

// MARK: Weekly report

@Test func weeklyReportComesFromTheWeeksFacts() {
    let facts = WeekFacts(week)

    // Better or worse is decided by code. Sleep moved by less than is worth a sentence.
    #expect(facts.improvements == ["Resting heart rate came down to 56 bpm, from 60 bpm the week before"])
    #expect(facts.setbacks.isEmpty)
    #expect(facts.withinRange == "12 of 13 overnight readings were within their expected range")
    #expect(facts.flagged.count == 1 && facts.flagged[0].hasPrefix("Short sleep, on the night to "))
    #expect(facts.prompt.contains("Went well:\n- Resting heart rate came down to 56 bpm"))
    #expect(facts.prompt.contains("Changed for the worse:\n- nothing\nFlagged:\n- Short sleep"))

    let report = TemplatedInsights.report(for: facts)
    #expect(report.headline == "A mostly steady week, with one stretch flagged")
    #expect(report.highlights == facts.improvements + ["12 of 13 overnight readings were within their expected range"])
    #expect(report.concerns == facts.flagged)
    #expect(InsightGuard.accepts(report.allText, source: facts.prompt))

    let quiet = TemplatedInsights.report(for: WeekFacts(snapshot()))
    #expect(quiet.headline == "A steady week" && quiet.concerns.isEmpty)
    #expect(quiet.focusForNextWeek == "Keep the routine that is working.")
}

@Test func aWorseWeekIsReportedAsASetbackAndTheMainEventComesFirst() {
    let worse = snapshot(metrics: [
        .heartRateVariability: assessed(.heartRateVariability, Array(repeating: 62, count: 7) + Array(repeating: 53, count: 7), expected: Band(lower: 53, median: 61, upper: 69)),
        .steps: assessed(.steps, Array(repeating: 9000, count: 7) + Array(repeating: 7000, count: 7), expected: Band(lower: 6000, median: 9000, upper: 12000)),
    ], events: [stress, illness])
    let facts = WeekFacts(worse)

    // Fewer steps is not a setback worth reporting; lower variability is.
    #expect(facts.improvements.isEmpty)
    #expect(facts.setbacks == ["Heart rate variability fell to 53 ms, from 62 ms the week before"])
    // The event that suggests a clinician leads, though the stress episode is more recent.
    #expect(facts.flagged.map { $0.prefix(7) } == ["Several", "High in"])
    let report = TemplatedInsights.report(for: facts)
    // 53 ms is the lower edge of the range, so every night still counts as within it.
    #expect(report.highlights == ["7 of 7 overnight readings were within their expected range"])
    #expect(report.concerns == facts.flagged + facts.setbacks)
}

/// Needs a device with Apple Intelligence turned on; skipped elsewhere.
@Test(.enabled(if: SystemLanguageModel.default.isAvailable))
func theModelWordsTheWeekButTheListsStayFacts() async {
    let facts = WeekFacts(week)
    let report = await InsightGenerator().weeklyReport(for: facts)
    let template = TemplatedInsights.report(for: facts)

    #expect(report.content.highlights == template.highlights)
    #expect(report.content.concerns == template.concerns)
    #expect(!report.content.headline.isEmpty && !report.content.focusForNextWeek.isEmpty)
    #expect(InsightGuard.accepts(report.content.allText, source: facts.prompt))
}

@Test func questionsAreRoutedToTheSummariesTheyAreAbout() {
    #expect(week.summaries(about: "How did I sleep last night?").first == week.sleepSummary(for: testNow))
    #expect(week.summaries(about: "How has my resting heart rate been this month?") == [week.statsSummary(of: .restingHeartRate, days: 30)])
    // "heart rate variability" is not the resting heart rate.
    #expect(week.summaries(about: "Why is my heart rate variability low?") == [week.statsSummary(of: .heartRateVariability, days: 7)])
    #expect(week.summaries(about: "What did I train this week?") == [week.workoutsSummary(days: 7)])
    #expect(week.summaries(about: "Did the coffee matter?") == [week.logsSummary(days: 7)])
    #expect(week.summaries(about: "What was flagged?") == [week.anomaliesSummary(days: 7)])
    #expect(week.summaries(about: "Tell me a joke").isEmpty)
    // Different questions, different answers, and none of them a summary of something else.
    #expect(AskSession.fallback(week.summaries(about: "How many steps?"), overview: week.overview) == week.statsSummary(of: .steps, days: 7))
    #expect(AskSession.fallback([], overview: week.overview).hasSuffix(AskSession.noTopic))
}

@Test func theRetryIsToldWhatWasWrong() {
    let source = week.sleepSummary(for: testNow)
    #expect(AskSession.problem(with: "You slept 6.5 hours.", source: source)?.contains("(6.5)") == true)
    #expect(AskSession.problem(with: "That sounds like an infection.", source: source)?.contains("medical") == true)
    #expect(AskSession.problem(with: "Your sleep was below your expected range.", source: source) == nil)
}

@Test @MainActor func withoutTheModelAskAnswersFromTheData() async {
    guard !SystemLanguageModel.default.isAvailable else { return }
    let session = AskSession(snapshot: week)
    await session.ask("What did I train this week?")
    #expect(session.messages.map(\.role) == [.user, .assistant])
    #expect(session.messages.last?.text == week.workoutsSummary(days: 7))
}

/// Needs a device with Apple Intelligence turned on; skipped elsewhere.
@Test(.enabled(if: SystemLanguageModel.default.isAvailable), arguments: QuickQuestion.allCases) @MainActor
func askAnswersEachQuestionWithinItsData(question: QuickQuestion) async throws {
    let session = AskSession(snapshot: week)
    await session.ask(question.rawValue)

    let answer = try #require(session.messages.last)
    #expect(!answer.text.isEmpty)
    #expect(InsightGuard.accepts(answer.text, source: answer.facts ?? answer.text))
}

// MARK: Advice on one day

let highHeartRate = assessed(.restingHeartRate, [57, 64], expected: Band(lower: 55, median: 57, upper: 59))

@Test func aDayOutsideItsRangeGetsAdviceForItsSide() throws {
    let context = snapshot(logs: [ManualLog(date: day(1).addingTimeInterval(20 * 3600), kind: .alcohol)])
    let worse = try #require(DayFacts(.restingHeartRate, highHeartRate.days[1], in: context))
    #expect(!worse.isBetter)
    #expect(worse.reading.hasPrefix("Resting heart rate today (") && worse.reading.hasSuffix("64 bpm, above the expected 55–59"))
    #expect(worse.context.first?.hasPrefix("Alcohol logged yesterday") == true)
    let advice = TemplatedInsights.advice(for: worse)
    #expect(advice.summary.contains("worse than usual") && advice.summary.contains("Alcohol logged yesterday"))
    #expect(InsightGuard.accepts(advice.allText, source: worse.prompt))

    // In range there is nothing to say; for variability, higher is the better side.
    #expect(DayFacts(.restingHeartRate, highHeartRate.days[0], in: context) == nil)
    let hrv = assessed(.heartRateVariability, [80], expected: Band(lower: 50, median: 60, upper: 70))
    #expect(try #require(DayFacts(.heartRateVariability, hrv.days[0], in: snapshot())).isBetter)
    // Fewer steps than expected is the worse side, though steps never signal strain.
    let steps = assessed(.steps, [2000], expected: Band(lower: 6000, median: 9000, upper: 12000))
    #expect(try #require(DayFacts(.steps, steps.days[0], in: snapshot())).isBetter == false)
}

/// Needs a device with Apple Intelligence turned on; skipped elsewhere.
@Test(.enabled(if: SystemLanguageModel.default.isAvailable))
func theModelsAdviceStaysWithinTheFacts() async throws {
    let facts = try #require(DayFacts(.restingHeartRate, highHeartRate.days[1], in: snapshot()))
    let advice = await InsightGenerator().advice(for: facts)
    #expect(!advice.content.action.isEmpty)
    #expect(InsightGuard.accepts(advice.content.allText, source: facts.prompt))
}
