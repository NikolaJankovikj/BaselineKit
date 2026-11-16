import Forecasting
import Foundation
import HealthData

public struct HealthSnapshot: Sendable {
    public var metrics: [Metric: MetricAssessment]
    public var events: [AnomalyEvent]
    public var logs: [ManualLog]
    public var workouts: [Workout]
    public var calendar: Calendar
    public var today: Date

    public init(
        metrics: [Metric: MetricAssessment], events: [AnomalyEvent], logs: [ManualLog], workouts: [Workout],
        calendar: Calendar = .current, now: Date = .now
    ) {
        self.metrics = metrics
        self.events = events
        self.logs = logs
        self.workouts = workouts
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
    }

    func dayLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated).day().month(.abbreviated))
    }

    func timeLabel(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// "today (Fri, 13 Nov)", "yesterday (Thu, 12 Nov)" or "on Wed, 11 Nov". The relative
    /// word is said here, where it is true: working it out, the model called a day two days
    /// back "yesterday", so in Ask it may only repeat it (`AskSession.checked`).
    func whenLabel(_ date: Date) -> String {
        switch calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day {
        case 0: "today (\(dayLabel(date)))"
        case 1: "yesterday (\(dayLabel(date)))"
        default: "on \(dayLabel(date))"
        }
    }

    /// "Last night (Thu, 12 Nov to Fri, 13 Nov)" or "Wednesday night (Wed, 11 Nov to Thu, 12 Nov)",
    /// for the night that ended on `morning`. Named the way people name a night, with both
    /// dates: given only "the night to Thursday", the model called it "last night".
    func nightLabel(endingOn morning: Date) -> String {
        let evening = calendar.date(byAdding: .day, value: -1, to: morning) ?? morning
        let name = morning == today
            ? "Last"
            : evening.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
        return "\(name) night (\(dayLabel(evening)) to \(dayLabel(morning)))"
    }

    func day(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
    }

    func nights(of event: AnomalyEvent) -> Int {
        (calendar.dateComponents([.day], from: event.start, to: event.end).day ?? 0) + 1
    }

    public func when(_ event: AnomalyEvent) -> String {
        if event.kind == .intradayStress {
            let day = calendar.isDate(event.start, inSameDayAs: today) ? "today" : "on \(dayLabel(event.start))"
            return "\(day) from \(timeLabel(event.start)) to \(timeLabel(event.end))"
        }
        let nights = nights(of: event)
        if event.end == today {
            return nights == 1 ? "last night" : "over the last \(nights) nights"
        }
        return nights == 1 ? "on the night to \(dayLabel(event.end))" : "over the \(nights) nights to \(dayLabel(event.end))"
    }

    public func sleepSummary(for date: Date) -> String {
        let day = calendar.startOfDay(for: date)
        let nights = Metric.allCases.filter(\.isOvernight).compactMap { metric in
            metrics[metric]?.days.first { $0.day == day && $0.observed != nil }.map { (metric: metric, night: $0) }
        }
        guard !nights.isEmpty else { return "No overnight data for \(nightLabel(endingOn: day))." }
        // One line per side of the range, never a mixed list: the model then calls every
        // signal in it "elevated", or every one "low".
        let sides = Dictionary(grouping: nights) { $0.night.side }
        let lines = [("above", "Above their"), ("below", "Below their"), ("within", "Within their"), (nil, "No")].compactMap { side, heading in
            sides[side].map { readings in
                "\(heading) expected range: " + readings.map { "\($0.metric.title.lowercased()) \(reading($0.night, of: $0.metric))" }.joined(separator: "; ") + "."
            }
        }
        let outside = nights.count { $0.night.isOutsideExpected }
        return (["\(nightLabel(endingOn: day)): \(outside) of \(nights.count) overnight signals were outside their expected range."] + lines)
            .joined(separator: "\n")
    }

    private func reading(_ day: DayAssessment, of metric: Metric) -> String {
        guard let observed = day.observed else { return "no value" }
        guard let expected = day.expected else { return metric.formattedWithUnit(observed) }
        return expected.comparison(of: observed, unit: metric.unit, format: metric.formatted)
    }

    public func workoutsSummary(days: Int) -> String {
        let recent = workouts.filter { $0.start >= day(daysAgo: days - 1) }.suffix(8)
        guard !recent.isEmpty else { return "No workouts in the last \(days) days." }
        let lines = recent.map { workout in
            "\(workout.kind), \(Int(workout.minutes.rounded())) min, \(Int(workout.energy.rounded())) kcal \(whenLabel(workout.start))"
        }
        return "Workouts in the last \(days) days: " + lines.joined(separator: "; ") + "."
    }

    public func logsSummary(days: Int) -> String {
        let recent = logs.filter { $0.date >= day(daysAgo: days - 1) }.sorted { $0.date < $1.date }.suffix(10)
        guard !recent.isEmpty else { return "Nothing was logged in the last \(days) days." }
        return "Logged in the last \(days) days: " + recent.map { "\($0.kind.title) \(whenLabel($0.date))" }.joined(separator: "; ") + "."
    }

    public func statsSummary(of metric: Metric, days: Int) -> String {
        let assessed = (metrics[metric]?.days ?? []).suffix(days).filter { $0.observed != nil }
        let values = assessed.compactMap(\.observed)
        guard let latest = assessed.last, let lowest = values.min(), let highest = values.max() else {
            return "No \(metric.title.lowercased()) data in the last \(days) days."
        }
        let average = values.reduce(0, +) / Double(values.count)
        let above = assessed.count { $0.side == "above" }
        let below = assessed.count { $0.side == "below" }
        // Zero counts are left out: "7 above and 0 below" came back as "none were outside".
        let outside = [(above, "above"), (below, "below")].filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? "was" : "were") \($0.1)" }
        let spread = outside.isEmpty
            ? "All \(assessed.count) days were within their expected range."
            : "Of \(assessed.count) days, \(outside.joined(separator: " and ")) their expected range."
        return "\(metric.title) over the last \(days) days: average \(metric.formattedWithUnit(average)), "
            + "lowest \(metric.formatted(lowest)), highest \(metric.formatted(highest)). "
            + "Latest, \(whenLabel(latest.day)): \(reading(latest, of: metric)). \(spread)"
    }

    public func anomaliesSummary(days: Int) -> String {
        let recent = events.filter { $0.end >= day(daysAgo: days - 1) }.prefix(6)
        guard !recent.isEmpty else { return "Nothing was flagged in the last \(days) days." }
        let lines = recent.flatMap { event in
            let facts = EventFacts(event, in: self)
            return ["\(facts.title), \(facts.when)."]
                + facts.sides.map { side in "\(side.heading): " + side.signals.map { "\($0.name) \($0.detail)" }.joined(separator: "; ") + "." }
                + (facts.context.isEmpty ? [] : ["Known context: \(facts.context.joined(separator: "; "))."])
        }
        return (["Flagged in the last \(days) days:"] + lines).joined(separator: "\n")
    }
}

extension Band {
    func comparison(of value: Double, unit: String, format: (Double) -> String) -> String {
        "\(format(value)) \(unit), \(side(of: value)) the expected \(format(lower))–\(format(upper))"
    }

    func side(of value: Double) -> String {
        value > upper ? "above" : value < lower ? "below" : "within"
    }
}

extension DayAssessment {
    var side: String? {
        guard let observed, let expected else { return nil }
        return expected.side(of: observed)
    }

    var isOutsideExpected: Bool {
        guard let observed, let expected else { return false }
        return !expected.contains(observed)
    }
}

extension AnomalyEvent.Signal {
    var comparison: String {
        expected.comparison(of: observed, unit: metric?.unit ?? "bpm", format: formatted)
    }
}

public enum QuickQuestion: String, CaseIterable, Identifiable, Sendable {
    case lastNight = "How did I sleep last night?"
    case today = "What should I do today?"
    case flagged = "What was flagged this week?"
    case heartRate = "How has my resting heart rate been this month?"

    public var id: Self { self }
}

extension HealthSnapshot {
    public var overview: [String] {
        [sleepSummary(for: today), anomaliesSummary(days: 7), logsSummary(days: 7), workoutsSummary(days: 7)]
            + Metric.allCases.filter { metrics[$0] != nil }.map { statsSummary(of: $0, days: 7) }
    }

    /// ponytail: keyword routing, a classifier if questions outgrow the word lists.
    public func summaries(about question: String) -> [String] {
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        func mentions(_ stems: [String]) -> Bool { words.contains { word in stems.contains(where: word.hasPrefix) } }
        func mentions(_ stems: String...) -> Bool { mentions(stems) }
        let days = mentions("year", "quarter") ? 90 : mentions("month", "weeks") ? 30 : 7

        var found: [String] = []
        let asksForAdvice = mentions("should", "plan", "advice", "advise", "recommend", "doing")
        if asksForAdvice || mentions("sleep", "slept", "night", "bed", "tired") {
            found += [sleepSummary(for: today), statsSummary(of: .sleepDuration, days: days)]
        }
        let isVariability = mentions("hrv", "variability")
        let metricStems: [(Metric, [String])] = [
            (.restingHeartRate, isVariability ? [] : ["heart", "pulse", "rhr", "bpm"]),
            (.heartRateVariability, ["hrv", "variability"]),
            (.respiratoryRate, ["breath", "respirat"]),
            (.wristTemperature, ["temperature", "temp", "fever", "warm"]),
            (.steps, ["step", "walk"]),
            (.activeEnergy, ["energy", "calorie", "kcal", "active"]),
            (.vo2Max, ["vo2", "cardio", "fitness"]),
        ]
        for (metric, stems) in metricStems where mentions(stems) {
            found.append(statsSummary(of: metric, days: days))
        }
        if mentions("workout", "train", "exercise", "run", "ride", "gym", "sport", "swim") { found.append(workoutsSummary(days: days)) }
        if mentions("log", "alcohol", "drink", "beer", "wine", "caffeine", "coffee", "sick", "ill", "travel") {
            found.append(logsSummary(days: days))
        }
        if asksForAdvice || mentions("flag", "unusual", "warn", "wrong", "alert", "anomal", "worry", "concern", "stress", "ok", "okay", "fine", "normal") {
            found.append(anomaliesSummary(days: days))
        }
        return found
    }
}
