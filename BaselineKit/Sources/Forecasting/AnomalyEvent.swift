import Foundation
import HealthData

/// Something worth telling the user about: one or more signals outside their expected range.
public struct AnomalyEvent: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// One or more metrics on the concerning side of their range.
        case deviation
        /// Heart rate, breathing and temperature up together on consecutive nights.
        case illnessWarning
        /// Heart rate up and its variability down for several nights.
        case sustainedStrain
        /// Daytime heart rate above what activity explains.
        case intradayStress
    }

    public enum Severity: Int, Codable, Sendable, Comparable {
        case mild, notable, strong

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Signal: Codable, Sendable, Hashable {
        /// nil for intraday heart rate, which is not a daily metric.
        public var metric: Metric?
        public var observed: Double
        public var expected: Band
        /// σ toward the concerning side.
        public var concern: Double

        public var title: String { metric?.title ?? "Heart rate" }

        public func formatted(_ value: Double) -> String {
            metric?.formatted(value) ?? value.formatted(.number.precision(.fractionLength(0)))
        }

        /// "66 bpm (expected 54–60)"
        public var summary: String {
            "\(formatted(observed)) \(metric?.unit ?? "bpm") (expected \(formatted(expected.lower))–\(formatted(expected.upper)))"
        }
    }

    /// Stable across runs, so feedback and explanations stay attached: the kind and the start.
    public var id: String
    public var kind: Kind
    /// The first day (its midnight), or the start time of an intraday event.
    public var start: Date
    /// The last day (its midnight), or the end time of an intraday event.
    public var end: Date
    public var severity: Severity
    /// The signals outside their range, each on its most deviating day, most deviating first.
    public var signals: [Signal]
    /// Persistent or severe enough to suggest talking to a clinician. Decided by the rules
    /// here and shown from this flag, never left to the language model.
    public var suggestsClinician = false

    /// Whether `first` matters more than `second`: an event that suggests a clinician, then
    /// an overnight event before a daytime stress estimate, then the more severe, then the later.
    public static func byImportance(_ first: AnomalyEvent, _ second: AnomalyEvent) -> Bool {
        func rank(_ event: AnomalyEvent) -> (Int, Int, Int, Date) {
            (event.suggestsClinician ? 1 : 0, event.kind == .intradayStress ? 0 : 1, event.severity.rawValue, event.end)
        }
        return rank(first) > rank(second)
    }

    public var title: String {
        switch kind {
        case .deviation:
            guard let first = signals.first?.metric else { return "Outside expected range" }
            return signals.count == 1 ? first.deviationTitle : "\(first.deviationTitle) and \(signals.count - 1) more"
        case .illnessWarning: return "Several vitals elevated"
        case .sustainedStrain: return "Signs of sustained strain"
        case .intradayStress: return "High intraday stress"
        }
    }
}

extension Metric {
    /// What a value on the concerning side of the range is called.
    fileprivate var deviationTitle: String {
        switch self {
        case .restingHeartRate: "Elevated resting heart rate"
        case .heartRateVariability: "Low heart rate variability"
        case .respiratoryRate: "Elevated respiratory rate"
        case .wristTemperature: "Elevated wrist temperature"
        case .sleepDuration: "Short sleep"
        case .steps, .activeEnergy, .vo2Max: "Unusual \(title.lowercased())"
        }
    }
}

/// The rules that turn assessed days into events.
public enum AnomalyDetector {
    /// Nights in a row that make an illness warning.
    static let illnessNights = 2
    /// Nights in a row that make sustained strain.
    static let strainNights = 3
    /// Nights of an illness warning from which the app suggests a clinician.
    static let persistentNights = 4
    /// σ on any one signal from which it does so regardless of duration.
    static let severeConcern = 5.0
    /// The vitals that tend to rise together when the body is fighting something.
    static let illnessSignals: [Metric] = [.restingHeartRate, .respiratoryRate, .wristTemperature]
    static let strainSignals: [Metric] = [.restingHeartRate, .heartRateVariability]

    /// Events in the assessed days, newest first. None while the baseline is still learning.
    public static func events(in metrics: [Metric: MetricAssessment], baseline: BaselineState) -> [AnomalyEvent] {
        guard baseline.isEstablished, let days = metrics.values.first?.days.map(\.day) else { return [] }
        let detector = Detector(metrics: metrics, days: days)

        let illness = detector.runs(atLeast: illnessNights, where: detector.looksLikeIllness)
        let strain = detector.runs(atLeast: strainNights) { detector.looksStrained($0) && !detector.looksLikeIllness($0) }
        let illnessStory = illnessSignals + [.heartRateVariability]
        var events = illness.map { run in
            var event = detector.event(.illnessWarning, run, metrics: illnessStory)
            let peak = event.signals.map(\.concern).max() ?? 0
            event.severity = run.count >= persistentNights ? .strong : .notable
            event.suggestsClinician = run.count >= persistentNights || peak >= severeConcern
            return event
        }
        events += strain.map { detector.event(.sustainedStrain, $0, metrics: strainSignals) }

        // Whatever else is outside its range, one event per stretch of days rather than per metric.
        var deviations: [(run: ClosedRange<Int>, metrics: [Metric])] = []
        for metric in Metric.allCases where metric.concerningDirection != nil {
            // A combined event already tells the story of the signals it involves.
            let covered = (illnessStory.contains(metric) ? illness : []) + (strainSignals.contains(metric) ? strain : [])
            for run in detector.deviationRuns(of: metric) where !covered.contains(where: { $0.overlaps(run) }) {
                deviations.append((run, [metric]))
            }
        }
        for deviation in deviations.sorted(by: { $0.run.lowerBound < $1.run.lowerBound }) {
            if let last = events.last, last.kind == .deviation, let lastRun = detector.run(of: last), lastRun.overlaps(deviation.run) {
                let merged = min(lastRun.lowerBound, deviation.run.lowerBound)...max(lastRun.upperBound, deviation.run.upperBound)
                events[events.count - 1] = detector.event(.deviation, merged, metrics: last.signals.compactMap(\.metric) + deviation.metrics)
            } else {
                events.append(detector.event(.deviation, deviation.run, metrics: deviation.metrics))
            }
        }
        return events.filter(isWorthReporting).sorted { $0.end > $1.end }
    }

    /// One metric slightly outside its range for one night happens every few weeks by chance.
    /// It stays visible on the chart but is not an event.
    private static func isWorthReporting(_ event: AnomalyEvent) -> Bool {
        event.kind != .deviation || event.severity > .mild || event.signals.count > 1
    }
}

private struct Detector {
    let metrics: [Metric: MetricAssessment]
    let days: [Date]

    func concern(_ metric: Metric, _ day: Int) -> Double? {
        metrics[metric].flatMap { $0.concern($0.days[day]) }
    }

    /// On the concerning side of the expected range.
    private func isOutside(_ metric: Metric, _ day: Int) -> Bool {
        guard let assessment = metrics[metric], let observed = assessment.days[day].observed,
            let expected = assessment.days[day].expected, let direction = metric.concerningDirection
        else { return false }
        return direction == .above ? observed > expected.upper : observed < expected.lower
    }

    /// At least two of resting heart rate, respiratory rate and wrist temperature above range.
    func looksLikeIllness(_ day: Int) -> Bool {
        AnomalyDetector.illnessSignals.count { isOutside($0, day) } >= 2
    }

    /// Resting heart rate above range and its variability below.
    func looksStrained(_ day: Int) -> Bool {
        AnomalyDetector.strainSignals.allSatisfy { isOutside($0, day) }
    }

    /// Stretches of days outside the range that include a clear deviation: the same
    /// hysteresis that keeps the expected range frozen.
    func deviationRuns(of metric: Metric) -> [ClosedRange<Int>] {
        runs(atLeast: 1) { isOutside(metric, $0) }.filter { run in
            run.contains { (concern(metric, $0) ?? 0) >= DailyForecastEngine.deviationThreshold }
        }
    }

    /// Maximal runs of consecutive days that satisfy `condition`.
    func runs(atLeast minimum: Int, where condition: (Int) -> Bool) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for day in 0...days.count {
            if day < days.count, condition(day) {
                start = start ?? day
            } else if let first = start {
                if day - first >= minimum { runs.append(first...(day - 1)) }
                start = nil
            }
        }
        return runs
    }

    func run(of event: AnomalyEvent) -> ClosedRange<Int>? {
        guard let first = days.firstIndex(of: event.start), let last = days.firstIndex(of: event.end) else { return nil }
        return first...last
    }

    /// An event over `run`, described by each metric's most deviating day in it.
    func event(_ kind: AnomalyEvent.Kind, _ run: ClosedRange<Int>, metrics involved: [Metric]) -> AnomalyEvent {
        let signals = involved.compactMap { metric -> AnomalyEvent.Signal? in
            guard let worst = run.max(by: { (concern(metric, $0) ?? -.infinity) < (concern(metric, $1) ?? -.infinity) }),
                isOutside(metric, worst), let day = metrics[metric]?.days[worst],
                let observed = day.observed, let expected = day.expected, let concern = concern(metric, worst)
            else { return nil }
            return AnomalyEvent.Signal(metric: metric, observed: observed, expected: expected, concern: concern)
        }.sorted { $0.concern > $1.concern }

        let peak = signals.first?.concern ?? 0
        let start = days[run.lowerBound]
        return AnomalyEvent(
            id: "\(kind.rawValue)-\(Int(start.timeIntervalSinceReferenceDate))", kind: kind,
            start: start, end: days[run.upperBound],
            severity: peak >= 4 || run.count >= 4 ? .strong : peak >= 3 || run.count >= 2 ? .notable : .mild,
            signals: signals)
    }
}
