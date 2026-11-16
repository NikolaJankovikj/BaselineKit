import Foundation
import HealthData

/// How much history the expected ranges have to go on.
public enum BaselineState: Sendable, Equatable {
    /// Ranges are shown but provisional, and nothing is flagged yet.
    case learning(nights: Int)
    case established

    public static let nightsNeeded = 14

    public init(nights: Int) {
        self = nights >= Self.nightsNeeded ? .established : .learning(nights: nights)
    }

    public var isEstablished: Bool { self == .established }
}

/// A 0–100 summary of how last night's signals sit relative to their expected ranges.
/// A heuristic for orientation, not a clinical score.
public struct Readiness: Sendable, Equatable {
    public struct Contribution: Sendable, Equatable, Identifiable {
        public var metric: Metric
        public var observed: Double
        public var expected: Band
        /// σ toward the metric's concerning side; negative is better than expected.
        public var concern: Double
        /// This signal's own 0–100 score.
        public var score: Double

        public var id: Metric { metric }
    }

    public var score: Int
    /// Most concerning first.
    public var contributions: [Contribution]

    /// Heart rate and its variability respond to most kinds of strain, so they weigh most.
    static let weights: [Metric: Double] = [
        .heartRateVariability: 0.3, .restingHeartRate: 0.3, .sleepDuration: 0.2,
        .respiratoryRate: 0.1, .wristTemperature: 0.1,
    ]

    /// The weighted mean of the signal scores, over the signals last night left.
    /// nil when it left none that has an expected range.
    public init?(_ metrics: [Metric: MetricAssessment]) {
        var contributions: [Contribution] = []
        var weighted = 0.0
        var totalWeight = 0.0
        for (metric, weight) in Self.weights {
            guard let assessment = metrics[metric], let today = assessment.days.last,
                let observed = today.observed, let expected = today.expected, let concern = assessment.concern(today)
            else { continue }
            let score = Self.signalScore(concern: concern)
            contributions.append(Contribution(metric: metric, observed: observed, expected: expected, concern: concern, score: score))
            weighted += weight * score
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        score = Int((weighted / totalWeight).rounded())
        self.contributions = contributions.sorted { $0.concern > $1.concern }
    }

    /// A logistic in the concern: 88 when a signal is exactly as expected, 66 at 1σ toward
    /// its concerning side, 34 at 2σ, 12 at 3σ; better than expected approaches 100.
    static func signalScore(concern: Double) -> Double {
        100 / (1 + exp(1.3 * (concern - 1.5)))
    }
}
