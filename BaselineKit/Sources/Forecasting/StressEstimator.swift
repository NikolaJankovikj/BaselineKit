import Foundation
import HealthData

public struct StressAssessment: Sendable, Equatable {
    public enum Level: String, Sendable {
        case low, moderate, high
    }

    public struct Point: Sendable, Equatable, Identifiable {
        public var time: Date
        public var heartRate: Double?
        public var expected: Band?
        public var score: Double?

        public var id: Date { time }
    }

    public var points: [Point] = []
    public var level: Level?
    public var events: [AnomalyEvent] = []
}

public struct StressEstimator: Sendable {
    /// Bins an expected range stays frozen during an episode (see `Anchoring`): 80 minutes,
    /// the model's whole horizon.
    static let maxFrozenBins = 16
    static let activeSteps = 60.0
    static let elevatedScore = 2.0
    /// Elevated bins closer than this belong to one episode: heart-rate samples are sparse.
    static let episodeGapBins = 2
    static let minimumEpisodeBins = 3
    static let minimumRestingBins = 12
    private static let binsPerHour = Int(3600 / IntradayHistory.binSeconds)

    private let forecaster: Chronos2Forecaster

    public init(forecaster: Chronos2Forecaster = .shared) {
        self.forecaster = forecaster
    }

    public func assess(_ history: IntradayHistory, scoredHours: Int = 12, baseline: BaselineState) async throws -> StressAssessment {
        let count = history.heartRate.count
        let scored = min(count - 1, scoredHours * Self.binsPerHour)
        guard scored > 0 else { return StressAssessment() }
        let first = count - scored
        // Sleep and workouts are a different regime, so they are not part of the resting reference.
        let resting = zip(history.heartRate, history.isMasked).map { $1 ? .nan : $0 }
        var seen = 0
        let restingSeen = resting.map { value in
            seen += value.isFinite ? 1 : 0
            return seen
        }

        // Steps are measured alongside heart rate, so for a scored bin they are known.
        let tasks = ((first - 1)..<(count - 1)).map { origin in
            ForecastTask(
                targets: [Array(resting[...origin])],
                knownCovariates: [KnownCovariate(past: Array(history.steps[...origin]), future: Array(history.steps[(origin + 1)...]))])
        }
        let forecasts = try await forecaster.forecast(tasks).map { $0.first ?? [] }
        let selection = Anchoring.select(
            observed: resting, steps: first...(count - 1), maxFrozenSteps: Self.maxFrozenBins, threshold: Self.elevatedScore
        ) { origin, ahead in
            let steps = forecasts[origin - (first - 1)]
            guard restingSeen[origin] >= Self.minimumRestingBins, steps.indices.contains(ahead - 1) else { return nil }
            return steps[ahead - 1]
        }

        var assessment = StressAssessment()
        assessment.points = (first..<count).map { bin in
            let expected = selection.bands[bin - first]
            let moving = max(history.steps[bin], history.steps[bin - 1]) >= Self.activeSteps
            let score = resting[bin].isFinite && !moving ? expected?.standardizedResidual(of: resting[bin]) : nil
            return StressAssessment.Point(
                time: history.time(ofBin: bin), heartRate: history.heartRate[bin].isFinite ? history.heartRate[bin] : nil,
                expected: history.isMasked[bin] ? nil : expected, score: score)
        }
        assessment.level = Self.level(of: assessment.points.suffix(Self.binsPerHour))
        assessment.events = baseline.isEstablished ? Self.episodes(in: assessment.points) : []
        return assessment
    }

    private static func level(of lastHour: ArraySlice<StressAssessment.Point>) -> StressAssessment.Level? {
        let scores = lastHour.compactMap(\.score)
        guard !scores.isEmpty else { return nil }
        let excess = scores.reduce(0) { $0 + max(0, $1) } / Double(scores.count)
        return excess < 0.75 ? .low : excess < 1.75 ? .moderate : .high
    }

    private static func episodes(in points: [StressAssessment.Point]) -> [AnomalyEvent] {
        let elevated = points.indices.filter { bin in
            guard points[bin].score != nil, let heartRate = points[bin].heartRate, let expected = points[bin].expected else { return false }
            return heartRate > expected.upper
        }
        var runs: [ClosedRange<Int>] = []
        for bin in elevated {
            if let last = runs.last, bin - last.upperBound <= episodeGapBins + 1 {
                runs[runs.count - 1] = last.lowerBound...bin
            } else {
                runs.append(bin...bin)
            }
        }
        return runs.filter { $0.count >= minimumEpisodeBins }.compactMap { run -> AnomalyEvent? in
            guard let peak = run.max(by: { (points[$0].score ?? 0) < (points[$1].score ?? 0) }),
                let heartRate = points[peak].heartRate, let expected = points[peak].expected,
                let score = points[peak].score, score >= elevatedScore
            else { return nil }
            let start = points[run.lowerBound].time
            return AnomalyEvent(
                id: "\(AnomalyEvent.Kind.intradayStress.rawValue)-\(Int(start.timeIntervalSinceReferenceDate))",
                kind: .intradayStress, start: start,
                end: points[run.upperBound].time.addingTimeInterval(IntradayHistory.binSeconds),
                severity: score >= 4 ? .strong : .notable,
                signals: [AnomalyEvent.Signal(metric: nil, observed: heartRate, expected: expected, concern: score)])
        }
    }
}
