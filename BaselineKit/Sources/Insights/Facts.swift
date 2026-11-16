import Forecasting
import Foundation
import HealthData

public struct EventFacts: Sendable, Equatable {
    public struct Signal: Sendable, Equatable {
        public var name: String
        public var isAbove: Bool
        public var detail: String
    }

    public var kind: AnomalyEvent.Kind
    public var title: String
    public var when: String
    public var signals: [Signal]
    public var context: [String]
    public var suggestsClinician: Bool

    public init(_ event: AnomalyEvent, in snapshot: HealthSnapshot, tags: Set<ManualLog.Kind> = []) {
        kind = event.kind
        title = event.title
        when = snapshot.when(event)
        signals = event.signals.map {
            Signal(name: $0.title.lowercased(), isAbove: $0.observed > $0.expected.median, detail: $0.comparison)
        }
        suggestsClinician = event.suggestsClinician
        context = tags.sorted { $0.rawValue < $1.rawValue }.map { "You tagged this: \($0.title.lowercased())" }
        guard event.kind != .intradayStress else { return }
        context += Self.context(from: event.start, to: event.end, in: snapshot)
    }

    static func context(from start: Date, to end: Date, in snapshot: HealthSnapshot) -> [String] {
        // An evening log explains the night that follows it.
        let window = snapshot.calendar.date(byAdding: .day, value: -1, to: start).map { DateInterval(start: $0, end: max($0, end)) }
        var context = snapshot.logs.filter { window?.contains($0.date) ?? false }.map { "\($0.kind.title) logged \(snapshot.whenLabel($0.date))" }
        if let longest = snapshot.workouts.filter({ window?.contains($0.start) ?? false && $0.minutes >= 75 }).max(by: { $0.minutes < $1.minutes }) {
            context.append("A \(Int(longest.minutes.rounded()))-minute \(longest.kind.lowercased()) \(snapshot.whenLabel(longest.start))")
        }
        if loadWasHigh(before: start, in: snapshot) {
            context.append("Training load in the days before was above your usual")
        }
        return context
    }

    private static func loadWasHigh(before start: Date, in snapshot: HealthSnapshot) -> Bool {
        let energy = (snapshot.metrics[.activeEnergy]?.days ?? []).filter { $0.day < start }.compactMap(\.observed)
        let recent = energy.suffix(3)
        let usual = energy.dropLast(3).suffix(28)
        guard recent.count == 3, usual.count >= 14 else { return false }
        return recent.reduce(0, +) / 3 >= 1.25 * usual.reduce(0, +) / Double(usual.count)
    }

    /// The signals above their range, then those below; a side without signals is left out.
    /// They are never given as one mixed list: the model then calls all of them "elevated".
    var sides: [(heading: String, signals: [Signal])] {
        [("Above their expected range", true), ("Below their expected range", false)]
            .map { heading, isAbove in (heading, signals.filter { $0.isAbove == isAbove }) }
            .filter { !$0.signals.isEmpty }
    }

    public var prompt: String {
        var lines = ["Event: \(title)", "When: \(when)"]
        for side in sides {
            lines.append("\(side.heading):")
            lines += side.signals.map { "- \($0.name): \($0.detail)" }
        }
        lines.append(context.isEmpty ? "Known context: none" : "Known context:")
        lines += context.map { "- \($0)" }
        return lines.joined(separator: "\n")
    }
}

public struct DayFacts: Sendable, Hashable {
    public var metric: Metric
    public var isBetter: Bool
    public var reading: String
    public var context: [String]

    public init?(_ metric: Metric, _ day: DayAssessment, in snapshot: HealthSnapshot) {
        guard let observed = day.observed, let expected = day.expected, !expected.contains(observed) else { return nil }
        self.metric = metric
        // Where neither side signals strain, as for steps, less is the worse side.
        isBetter = (observed > expected.upper) != ((metric.concerningDirection ?? .below) == .above)
        reading = "\(metric.title) \(snapshot.whenLabel(day.day)): \(expected.comparison(of: observed, unit: metric.unit, format: metric.formatted))"
        context = EventFacts.context(from: day.day, to: day.day, in: snapshot)
    }

    public var prompt: String {
        var lines = ["Reading: \(reading)", "For this metric that is \(isBetter ? "the better" : "the worse") side of the range."]
        lines.append(context.isEmpty ? "Known context: none" : "Known context:")
        lines += context.map { "- \($0)" }
        lines.append("Usual advice: \(TemplatedInsights.action(for: self))")
        return lines.joined(separator: "\n")
    }
}

/// What is known about the last seven days, worded by code. Which changes are for the
/// better and which for the worse is decided here: the language model gets them as two
/// lists and does not have to judge a number.
public struct WeekFacts: Sendable, Equatable {
    public var range: String
    public var improvements: [String] = []
    public var setbacks: [String] = []
    public var flagged: [String]
    public var flaggedKinds: [AnomalyEvent.Kind]
    public var withinRange: String?
    public var isMostlyWithinRange: Bool

    public init(_ snapshot: HealthSnapshot) {
        let weekStart = snapshot.day(daysAgo: 6)
        range = "\(snapshot.dayLabel(weekStart)) – \(snapshot.dayLabel(snapshot.today))"
        var readings = 0
        var inside = 0
        for metric in Metric.allCases {
            let days = snapshot.metrics[metric]?.days ?? []
            func mean(_ slice: ArraySlice<DayAssessment>) -> Double? {
                let values = slice.compactMap(\.observed)
                return values.count >= 4 ? values.reduce(0, +) / Double(values.count) : nil
            }
            let thisWeek = days.suffix(7)
            if metric.isOvernight {
                for day in thisWeek {
                    guard let observed = day.observed, let expected = day.expected else { continue }
                    readings += 1
                    inside += expected.contains(observed) ? 1 : 0
                }
            }
            guard let now = mean(thisWeek), let before = mean(days.dropLast(7).suffix(7)),
                let wording = Self.wording(for: metric), abs(now - before) >= wording.notableChange * abs(before)
            else { continue }
            let isBetter = (now > before) == wording.higherIsBetter
            let verb = isBetter ? wording.better : wording.worse
            let sentence = "\(metric.title) \(verb) to \(metric.formattedWithUnit(now)), from \(metric.formattedWithUnit(before)) the week before"
            if isBetter {
                improvements.append(sentence)
            } else if !wording.worse.isEmpty {
                setbacks.append(sentence)
            }
        }
        withinRange = readings > 0 ? "\(inside) of \(readings) overnight readings were within their expected range" : nil
        isMostlyWithinRange = readings > 0 && 5 * inside >= 4 * readings
        let recent = snapshot.events.filter { $0.end >= weekStart }.sorted(by: AnomalyEvent.byImportance)
        flagged = recent.map { "\($0.title), \(snapshot.when($0))" }
        flaggedKinds = recent.map(\.kind)
    }

    /// How a change of a metric's weekly average reads, and how large a relative change is
    /// worth a sentence: roughly twice what a weekly average of that metric wobbles by on its
    /// own. Metrics whose average says little either way have no wording; an empty `worse`
    /// means a fall is not reported as a setback.
    private static func wording(for metric: Metric) -> (higherIsBetter: Bool, better: String, worse: String, notableChange: Double)? {
        switch metric {
        case .restingHeartRate: (false, "came down", "rose", 0.03)
        case .heartRateVariability: (true, "rose", "fell", 0.08)
        case .sleepDuration: (true, "went up", "went down", 0.06)
        case .steps: (true, "went up", "", 0.1)
        case .respiratoryRate, .wristTemperature, .activeEnergy, .vo2Max: nil
        }
    }

    public var prompt: String {
        func list(_ title: String, _ items: [String]) -> [String] {
            ["\(title):"] + (items.isEmpty ? ["- nothing"] : items.map { "- \($0)" })
        }
        var lines = ["Week: \(range)"]
        lines += list("Went well", improvements + (isMostlyWithinRange ? [withinRange].compactMap(\.self) : []))
        lines += list("Changed for the worse", setbacks)
        lines += list("Flagged", flagged)
        return lines.joined(separator: "\n")
    }
}
