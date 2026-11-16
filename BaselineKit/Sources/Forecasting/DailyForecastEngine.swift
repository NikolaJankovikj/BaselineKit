import Foundation
import HealthData

public enum ForecastMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case univariate
    case joint

    public var id: Self { self }
}

public struct OriginForecast: Sendable, Codable, Equatable {
    public var steps: [Band]
}

/// Forecasts by `DailyForecastEngine.key`. A forecast issued from a past day does not change
/// once that day is over, so it is computed once and kept.
public typealias ForecastCache = [String: OriginForecast]

public struct DayAssessment: Sendable, Equatable, Identifiable {
    public var day: Date
    public var observed: Double?
    public var expected: Band?
    public var simple: Band?
    public var horizon: Int

    public var id: Date { day }

    public var residual: Double? {
        guard let observed, let expected else { return nil }
        return expected.standardizedResidual(of: observed)
    }
}

public struct MetricAssessment: Sendable, Equatable {
    public var metric: Metric
    public var days: [DayAssessment]
    public var outlook: [DayAssessment]
    public var runningTotal: Double?

    public func concern(_ day: DayAssessment) -> Double? {
        guard let direction = metric.concerningDirection, let residual = day.residual else { return nil }
        return direction.sign * residual
    }
}

public struct DailyForecastEngine: Sendable {
    public static let outlookDays = 7
    public static let maxFrozenDays = 7
    public static let deviationThreshold = 2.0
    public static let minimumObservations = 3
    private static let stepsKept = outlookDays + maxFrozenDays

    public var mode: ForecastMode
    private let forecaster: Chronos2Forecaster
    private let calendar: Calendar

    public init(mode: ForecastMode = .univariate, forecaster: Chronos2Forecaster = .shared, calendar: Calendar = .current) {
        self.mode = mode
        self.forecaster = forecaster
        self.calendar = calendar
    }

    public struct Result: Sendable {
        public var metrics: [Metric: MetricAssessment] = [:]
        public var newForecasts: ForecastCache = [:]
    }

    public func assess(_ history: DailyHistory, logs: [ManualLog] = [], depth: Int, cache: ForecastCache = [:]) async throws -> Result {
        guard let today = history.days.indices.last else { return Result() }
        let series = modelSeries(history)
        let firstDay = max(0, today - depth + 1)
        var forecasts = cache
        let fresh = try await missingForecasts(for: max(0, firstDay - 1)...today, series: series, history: history, logs: logs, cache: cache)
        forecasts.merge(fresh) { _, new in new }

        var result = Result()
        for metric in Metric.allCases {
            var assessment = assess(metric, series: series[metric] ?? [], days: history.days, range: firstDay...today, forecasts: forecasts)
            if metric.accumulatesOverDay {
                assessment.runningTotal = history.series(metric).last.flatMap { $0.isFinite ? $0 : nil }
            }
            result.metrics[metric] = assessment
        }
        // A forecast from today still changes as today's data arrives.
        let todayKeys = Set(Metric.allCases.map { key($0, history.days[today]) })
        result.newForecasts = fresh.filter { !todayKeys.contains($0.key) }
        return result
    }

    func key(_ metric: Metric, _ origin: Date) -> String {
        "\(mode.rawValue)|\(metric.rawValue)|\(Int(origin.timeIntervalSinceReferenceDate))"
    }

    /// What the model sees: a total that is still running is not an observation yet.
    private func modelSeries(_ history: DailyHistory) -> [Metric: [Double]] {
        Dictionary(uniqueKeysWithValues: Metric.allCases.map { metric in
            var values = history.series(metric)
            if metric.accumulatesOverDay, !values.isEmpty {
                values[values.count - 1] = .nan
            }
            return (metric, values)
        })
    }

    private func missingForecasts(
        for origins: ClosedRange<Int>, series: [Metric: [Double]], history: DailyHistory, logs: [ManualLog], cache: ForecastCache
    ) async throws -> ForecastCache {
        var tasks: [ForecastTask] = []
        var keys: [[String]] = []
        for origin in origins {
            let day = history.days[origin]
            let ready = Metric.allCases.filter { metric in
                (series[metric]?[...origin].count(where: \.isFinite) ?? 0) >= Self.minimumObservations
            }
            let missing = ready.filter { cache[key($0, day)] == nil }
            guard !missing.isEmpty else { continue }
            func past(_ metric: Metric) -> [Double] { Array(series[metric]?[...origin] ?? []) }
            switch mode {
            case .univariate:
                tasks += missing.map { ForecastTask(targets: [past($0)]) }
                keys += missing.map { [key($0, day)] }
            case .joint:
                // A joint forecast depends on every member of the group, so all are forecast again.
                tasks.append(ForecastTask(
                    targets: ready.map(past),
                    pastCovariates: logCovariates(logs, days: history.days[...origin]),
                    knownCovariates: [weekendCovariate(days: history.days[...origin])]))
                keys.append(ready.map { key($0, day) })
            }
        }
        var fresh: ForecastCache = [:]
        for (taskKeys, targets) in zip(keys, try await forecaster.forecast(tasks)) {
            for (key, bands) in zip(taskKeys, targets) {
                fresh[key] = OriginForecast(steps: Array(bands.prefix(Self.stepsKept)))
            }
        }
        return fresh
    }

    private func weekendCovariate(days: ArraySlice<Date>) -> KnownCovariate {
        func flag(_ day: Date) -> Double { calendar.isDateInWeekend(day) ? 1 : 0 }
        let future = days.last.map { last in
            (1...Self.stepsKept).compactMap { calendar.date(byAdding: .day, value: $0, to: last) }
        }
        return KnownCovariate(past: days.map(flag), future: (future ?? []).map(flag))
    }

    /// A 0/1 series per kind of logged event that occurs in `days`. A kind that was never
    /// logged is left out: a constant covariate tells the model nothing.
    private func logCovariates(_ logs: [ManualLog], days: ArraySlice<Date>) -> [[Double]] {
        [ManualLog.Kind.alcohol, .illness].compactMap { kind in
            let logged = Set(logs.filter { $0.kind == kind }.map { calendar.startOfDay(for: $0.date) })
            let flags = days.map { logged.contains($0) ? 1.0 : 0.0 }
            return flags.contains(1) ? flags : nil
        }
    }

    private func assess(_ metric: Metric, series: [Double], days: [Date], range: ClosedRange<Int>, forecasts: ForecastCache) -> MetricAssessment {
        func model(_ origin: Int, _ ahead: Int) -> Band? {
            guard days.indices.contains(origin), let steps = forecasts[key(metric, days[origin])]?.steps else { return nil }
            return steps.indices.contains(ahead - 1) ? steps[ahead - 1] : nil
        }
        func simple(_ origin: Int, _: Int) -> Band? {
            days.indices.contains(origin) ? SimpleAverage.band(history: series[...origin]) : nil
        }
        func select(_ forecast: (Int, Int) -> Band?) -> Anchoring.Selection {
            Anchoring.select(
                observed: series, steps: range, maxFrozenSteps: Self.maxFrozenDays,
                threshold: Self.deviationThreshold, forecast: forecast)
        }
        let expected = select(model)
        let baseline = select(simple)
        let history = range.enumerated().map { offset, index in
            DayAssessment(
                day: days[index], observed: series[index].isFinite ? series[index] : nil,
                expected: expected.bands[offset], simple: baseline.bands[offset], horizon: expected.horizons[offset])
        }
        let today = range.upperBound
        let outlook = (1...Self.outlookDays).compactMap { ahead -> DayAssessment? in
            guard let day = calendar.date(byAdding: .day, value: ahead, to: days[today]) else { return nil }
            let horizon = today + ahead - expected.anchor
            return DayAssessment(
                day: day, observed: nil, expected: model(expected.anchor, horizon),
                simple: simple(baseline.anchor, today + ahead - baseline.anchor), horizon: horizon)
        }
        return MetricAssessment(metric: metric, days: history, outlook: outlook)
    }
}

public struct BacktestScore: Sendable, Identifiable, Equatable {
    public var metric: Metric
    public var days: Int
    public var modelError: Double
    public var simpleError: Double
    public var modelCoverage: Double
    public var simpleCoverage: Double

    public var id: Metric { metric }
}

extension DailyForecastEngine {
    /// The thesis's comparison on the user's own data: Chronos-2 against the simple average,
    /// one day ahead, over the last `depth` complete days. Ranges are not frozen here, so
    /// this measures forecasting, not anomaly detection.
    public func backtest(_ history: DailyHistory, logs: [ManualLog] = [], depth: Int, cache: ForecastCache = [:]) async throws -> (scores: [BacktestScore], newForecasts: ForecastCache) {
        guard let today = history.days.indices.last, today >= 2 else { return ([], [:]) }
        let series = modelSeries(history)
        let scored = max(1, today - depth)...(today - 1)
        let fresh = try await missingForecasts(
            for: (scored.lowerBound - 1)...(scored.upperBound - 1), series: series, history: history, logs: logs, cache: cache)
        let forecasts = cache.merging(fresh) { _, new in new }

        let scores = Metric.allCases.compactMap { metric -> BacktestScore? in
            let values = series[metric] ?? []
            let pairs: [(value: Double, model: Band, simple: Band)] = scored.compactMap { day in
                guard values[day].isFinite,
                    let model = forecasts[key(metric, history.days[day - 1])]?.steps.first,
                    let simple = SimpleAverage.band(history: values[..<day])
                else { return nil }
                return (values[day], model, simple)
            }
            guard !pairs.isEmpty else { return nil }
            func mean(_ term: ((value: Double, model: Band, simple: Band)) -> Double) -> Double {
                pairs.reduce(0) { $0 + term($1) } / Double(pairs.count)
            }
            return BacktestScore(
                metric: metric, days: pairs.count,
                modelError: mean { abs($0.value - $0.model.median) },
                simpleError: mean { abs($0.value - $0.simple.median) },
                modelCoverage: mean { $0.model.contains($0.value) ? 1 : 0 },
                simpleCoverage: mean { $0.simple.contains($0.value) ? 1 : 0 })
        }
        return (scores, fresh)
    }
}
