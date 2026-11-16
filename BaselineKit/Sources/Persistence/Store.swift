import Forecasting
import Foundation
import HealthData
import Insights
import Observation

public struct Feedback: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        case makesSense, falseAlarm
    }

    public var verdict: Verdict?
    public var tags: Set<ManualLog.Kind> = []

    public init(verdict: Verdict? = nil, tags: Set<ManualLog.Kind> = []) {
        self.verdict = verdict
        self.tags = tags
    }
}

/// Two small JSON files in the app's own container, written atomically and encrypted by the
/// system until the first unlock after a restart (background refreshes run while locked).
/// Nothing is synced or sent anywhere.
@MainActor @Observable
public final class Store {
    private struct Journal: Codable {
        var logs: [ManualLog] = []
        var feedback: [String: Feedback] = [:]
        var insights: [String: Sourced<AnomalyInsight>] = [:]
        var reports: [String: Sourced<WeeklyReport>] = [:]
    }

    private var journal = Journal()
    public private(set) var forecasts: ForecastCache = [:]

    private let directory: URL?

    public init(directory: URL?) {
        self.directory = directory
        journal = read("journal.json") ?? Journal()
        forecasts = read("forecasts.json") ?? [:]
    }

    public static func onDisk() -> Store {
        Store(directory: URL.applicationSupportDirectory.appending(path: "Baseline"))
    }

    public var logs: [ManualLog] { journal.logs }

    public func add(_ log: ManualLog) {
        journal.logs.append(log)
        saveJournal()
    }

    public func remove(_ log: ManualLog) {
        journal.logs.removeAll { $0.id == log.id }
        saveJournal()
    }

    public func feedback(for event: AnomalyEvent) -> Feedback {
        journal.feedback[event.id] ?? Feedback()
    }

    public func setFeedback(_ feedback: Feedback, for event: AnomalyEvent) {
        journal.feedback[event.id] = feedback
        saveJournal()
    }

    /// Explanations are kept per state of an event: one more night makes a new explanation.
    public func insight(for event: AnomalyEvent) -> Sourced<AnomalyInsight>? {
        journal.insights[Self.key(event)]
    }

    public func setInsight(_ insight: Sourced<AnomalyInsight>, for event: AnomalyEvent) {
        journal.insights[Self.key(event)] = insight
        saveJournal()
    }

    public func report(forWeekEnding day: Date) -> Sourced<WeeklyReport>? {
        journal.reports[Self.key(day)]
    }

    public func setReport(_ report: Sourced<WeeklyReport>, forWeekEnding day: Date) {
        journal.reports[Self.key(day)] = report
        saveJournal()
    }

    private static func key(_ event: AnomalyEvent) -> String { "\(event.id)|\(key(event.end))" }
    private static func key(_ date: Date) -> String { String(Int(date.timeIntervalSinceReferenceDate)) }

    public func addForecasts(_ fresh: ForecastCache) {
        guard !fresh.isEmpty else { return }
        forecasts.merge(fresh) { _, new in new }
        write(forecasts, to: "forecasts.json")
    }

    public func eraseAll() {
        journal = Journal()
        forecasts = [:]
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func saveJournal() {
        write(journal, to: "journal.json")
    }

    private func read<Value: Decodable>(_ file: String) -> Value? {
        guard let directory, let data = try? Data(contentsOf: directory.appending(path: file)) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func write(_ value: some Encodable, to file: String) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(
                to: directory.appending(path: file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Losing a save must not take the app down; the next change writes again.
            assertionFailure("Could not save \(file): \(error)")
        }
    }
}

public func dailyCSV(_ metrics: [Metric: MetricAssessment]) -> String {
    let columns = Metric.allCases.filter { metrics[$0] != nil }
    let header = ["date"] + columns.flatMap { ["\($0.rawValue)", "\($0.rawValue)_expected_low", "\($0.rawValue)_expected_high"] }
    let days = columns.first.flatMap { metrics[$0]?.days.indices } ?? 0..<0
    func cell(_ value: Double?) -> String { value.map { String($0) } ?? "" }
    let rows = days.map { index in
        let date = metrics[columns[0]]?.days[index].day.formatted(.iso8601.year().month().day()) ?? ""
        return [date] + columns.flatMap { metric -> [String] in
            let day = metrics[metric]?.days[index]
            return [cell(day?.observed), cell(day?.expected?.lower), cell(day?.expected?.upper)]
        }
    }
    return ([header] + rows).map { $0.joined(separator: ",") }.joined(separator: "\n") + "\n"
}
