import Forecasting
import Foundation
import HealthData
import Insights
import Observation
import Persistence

/// The app's state: where the data comes from, and what the pipeline made of it.
///
/// A refresh reads the history, forecasts with Chronos-2, scores and detects in Swift, and
/// only then asks for explanations. Every number and flag on screen comes from the first
/// three steps.
@Observable
final class AppModel {
    static let shared = AppModel()

    enum DataSource: String {
        case demo, health
    }

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// Days of history to read: a year of context for the model, plus a margin.
    private static let historyDays = 400
    /// Days assessed before the first screen appears, and in total. The first is enough for
    /// Today and the month chart; the rest fills in the six-month chart.
    private static let recentDepth = 38
    static let fullDepth = 187
    private static let intradayHours = 36

    // MARK: Settings

    private let defaults: UserDefaults

    /// - Parameter defaults: where the three settings are kept. The tests pass their own,
    ///   so that they leave the app's alone; launch arguments reach the standard ones.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dataSource = defaults.string(forKey: "dataSource").flatMap(DataSource.init)
        scenario = defaults.string(forKey: "scenario").flatMap(SyntheticProvider.Scenario.init) ?? .sickWeek
        forecastMode = defaults.string(forKey: "forecastMode").flatMap(ForecastMode.init) ?? .univariate
    }

    /// nil until onboarding is finished.
    var dataSource: DataSource? {
        didSet { defaults.set(dataSource?.rawValue, forKey: "dataSource") }
    }

    var scenario: SyntheticProvider.Scenario {
        didSet { defaults.set(scenario.rawValue, forKey: "scenario") }
    }

    var forecastMode: ForecastMode {
        didSet { defaults.set(forecastMode.rawValue, forKey: "forecastMode") }
    }

    // MARK: State

    private(set) var phase = Phase.idle
    /// True while the older part of the six months is still being assessed.
    private(set) var isExtending = false
    private(set) var history: DailyHistory?
    private(set) var metrics: [Metric: MetricAssessment] = [:]
    private(set) var baseline = BaselineState.learning(nights: 0)
    private(set) var readiness: Readiness?
    private(set) var stress: StressAssessment?
    private(set) var events: [AnomalyEvent] = []
    private(set) var weeklyReport: Sourced<WeeklyReport>?
    private var generatedAdvice: [DayFacts: Sourced<MetricAdvice>] = [:]
    private(set) var store = Store(directory: nil)

    /// Whose journal `store` holds: the demo scenario's or the user's own.
    private var storeOwner: String?
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private let generator = InsightGenerator()
    /// Where Apple Health data comes from. The tests put a stand-in here.
    var healthProvider: () -> any HealthDataProvider = { HealthKitProvider() }

    // MARK: Lifecycle

    /// Switches where the data comes from. The root view reloads whenever the source
    /// changes; until that is done nothing of the previous source stays on screen.
    func choose(_ source: DataSource) {
        guard source != dataSource else { return }
        dataSource = source
        phase = .loading
    }

    /// Reads the data again and reruns the pipeline. A refresh that is already running is
    /// replaced, so a changed setting takes effect at once.
    func refresh() async {
        refreshTask?.cancel()
        let task = Task { await runPipeline() }
        refreshTask = task
        await task.value
        if refreshTask == task { (refreshTask, lastRefresh) = (nil, .now) }
    }

    /// For coming back to the front: last night's data may have arrived since the app was
    /// last looked at. Not on every glance, since the intraday part is recomputed each time.
    func refreshIfStale() async {
        guard refreshTask == nil, Date.now.timeIntervalSince(lastRefresh) > 15 * 60 else { return }
        await refresh()
    }

    /// A refresh nobody is watching: afterwards, notify about what it found.
    func refreshInBackground() async {
        await refresh()
        await Notifier.announce(self)
    }

    private func runPipeline() async {
        guard let dataSource else { return }
        if phase != .ready { phase = .loading }
        do {
            let provider: any HealthDataProvider
            switch dataSource {
            case .demo:
                let synthetic = SyntheticProvider(scenario: scenario)
                provider = synthetic
                if storeOwner != scenario.rawValue {
                    // The synthetic person brings their own journal; nothing of it is saved.
                    store = Store(directory: nil)
                    synthetic.logs.forEach(store.add)
                    storeOwner = scenario.rawValue
                }
            case .health:
                provider = healthProvider()
                try await provider.requestAccess()
                try Task.checkCancellation()
                BaselineBackground.observeHealth()
                if storeOwner != DataSource.health.rawValue {
                    store = Store.onDisk()
                    storeOwner = DataSource.health.rawValue
                }
            }
            let history = try await provider.dailyHistory(days: Self.historyDays)
            self.history = history
            baseline = BaselineState(nights: history.nightsOfData)

            try await assess(history, depth: Self.recentDepth)
            phase = .ready
            isExtending = true
            defer { isExtending = false }

            let intraday = try await provider.intradayHistory(hours: Self.intradayHours)
            let estimate = try await StressEstimator().assess(intraday, baseline: baseline)
            try Task.checkCancellation()
            stress = estimate
            try await assess(history, depth: Self.fullDepth)
            await writeWeeklyReport()
        } catch is CancellationError {
            return
        } catch {
            // A refresh that was replaced has no say any more. The Health access sheet can
            // take a minute to fail, long after the user has gone back to the demo.
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func assess(_ history: DailyHistory, depth: Int) async throws {
        let engine = DailyForecastEngine(mode: forecastMode)
        let result = try await engine.assess(history, logs: store.logs, depth: depth, cache: store.forecasts)
        try Task.checkCancellation()
        store.addForecasts(result.newForecasts)
        metrics = result.metrics
        generatedAdvice = [:]
        readiness = Readiness(result.metrics)
        events = (AnomalyDetector.events(in: result.metrics, baseline: baseline) + (stress?.events ?? [])).sorted { $0.end > $1.end }
    }

    // MARK: Insights

    var snapshot: HealthSnapshot {
        HealthSnapshot(metrics: metrics, events: events, logs: store.logs, workouts: history?.workouts ?? [])
    }

    /// What the Today screen talks about: the most important of the events that are going
    /// on or ended within a day.
    var currentEvent: AnomalyEvent? {
        let yesterday = snapshot.today.addingTimeInterval(-86_400)
        return events.filter { $0.end >= yesterday }.sorted(by: AnomalyEvent.byImportance).first
    }

    /// The explanation of an event, generated once per state of the event and then kept.
    func explanation(of event: AnomalyEvent) async -> Sourced<AnomalyInsight> {
        if let stored = store.insight(for: event) { return stored }
        let facts = EventFacts(event, in: snapshot, tags: store.feedback(for: event).tags)
        let explained = await generator.insight(for: facts)
        store.setInsight(explained, for: event)
        return explained
    }

    /// What to do about one day's value: the template at once, Apple Intelligence's wording
    /// once it is ready and checked. Kept until the next refresh.
    func advice(for metric: Metric, on day: DayAssessment) -> Sourced<MetricAdvice>? {
        guard let facts = DayFacts(metric, day, in: snapshot) else { return nil }
        return generatedAdvice[facts] ?? Sourced(TemplatedInsights.advice(for: facts), source: .template)
    }

    func generateAdvice(for metric: Metric, on day: DayAssessment) async {
        guard let facts = DayFacts(metric, day, in: snapshot), generatedAdvice[facts] == nil else { return }
        let advice = await generator.advice(for: facts)
        guard !Task.isCancelled else { return }
        generatedAdvice[facts] = advice
    }

    private func writeWeeklyReport() async {
        let today = snapshot.today
        if let stored = store.report(forWeekEnding: today) {
            weeklyReport = stored
            return
        }
        let report = await generator.weeklyReport(for: WeekFacts(snapshot))
        store.setReport(report, forWeekEnding: today)
        weeklyReport = report
    }

    // MARK: Journal

    func log(_ kind: ManualLog.Kind) {
        let log = ManualLog(date: .now, kind: kind)
        store.add(log)
        if dataSource == .health {
            Task { try? await HealthKitProvider().save(log) }
        }
    }

    func events(on day: Date, involving metric: Metric) -> [AnomalyEvent] {
        events.filter { event in
            event.kind != .intradayStress && event.start <= day && day <= event.end && event.signals.contains { $0.metric == metric }
        }
    }

    // MARK: Data management

    var csvExport: String { dailyCSV(metrics) }

    func eraseEverything() {
        refreshTask?.cancel()
        store.eraseAll()
        storeOwner = nil
        (history, metrics, readiness, stress, events, weeklyReport) = (nil, [:], nil, nil, [], nil)
        phase = .idle
        dataSource = nil
    }

    #if DEBUG
        func writeDemoDataToHealth() async throws {
            let synthetic = SyntheticProvider(scenario: .healthy)
            try await HealthKitProvider().writeSampleData(
                try await synthetic.dailyHistory(days: 120), intraday: try await synthetic.intradayHistory(hours: Self.intradayHours))
        }
    #endif

    /// The model-against-simple-average comparison on the current history, for both ways of
    /// forecasting.
    func backtest(mode: ForecastMode) async throws -> [BacktestScore] {
        guard let history else { return [] }
        let engine = DailyForecastEngine(mode: mode)
        let (scores, fresh) = try await engine.backtest(history, logs: store.logs, depth: 90, cache: store.forecasts)
        store.addForecasts(fresh)
        return scores
    }
}
