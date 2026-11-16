import Foundation

/// An expected range for one value: a forecast's q10, median and q90.
public struct Band: Sendable, Codable, Hashable {
    public var lower: Double
    public var median: Double
    public var upper: Double

    public init(lower: Double, median: Double, upper: Double) {
        self.lower = lower
        self.median = median
        self.upper = upper
    }

    /// The q10–q90 width of a Gaussian, in standard deviations.
    static let widthPerSigma = 2.5631

    /// The spread the band implies, as the thesis scores it: (q90 − q10) / 2.5631, so that
    /// residuals of every forecaster are in σ units. Floored so a flat history cannot divide by zero.
    public var sigma: Double {
        max((upper - lower) / Self.widthPerSigma, 1e-6 * max(1, abs(median)))
    }

    /// Thesis anomaly score: (observed − median) / σ̂. Signed; positive is above expected.
    public func standardizedResidual(of observed: Double) -> Double {
        (observed - median) / sigma
    }

    public func contains(_ value: Double) -> Bool {
        value >= lower && value <= upper
    }
}

/// The thesis's sanity-floor forecaster: the mean and spread of recent values, as a flat band.
public enum SimpleAverage {
    /// Four weeks: long enough to average out the weekly rhythm, short enough to follow a season.
    public static let window = 28

    /// μ ± 1.2816σ of the last `window` observed values; nil when there are too few to judge.
    public static func band(history: some Collection<Double>) -> Band? {
        let recent = history.suffix(window).filter(\.isFinite)
        guard recent.count >= DailyForecastEngine.minimumObservations else { return nil }
        let mean = recent.reduce(0, +) / Double(recent.count)
        let variance = recent.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(recent.count)
        let halfWidth = Band.widthPerSigma / 2 * variance.squareRoot()
        return Band(lower: mean - halfWidth, median: mean, upper: mean + halfWidth)
    }
}
