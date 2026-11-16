/// Chooses which past forecast each step's expected range comes from.
///
/// Normally that is the one-step-ahead forecast from the step before. But a forecaster that
/// has seen a deviating value adapts to it and would call the next deviating value normal.
/// So while values keep deviating, the range stays the one forecast before the run began,
/// reaching further ahead each step. After `maxFrozenSteps` the deviation is taken as the
/// new normal and the range follows the data again.
///
/// A run starts with a clear deviation (`threshold`, in σ) and lasts while values stay
/// outside the range. Without that hysteresis one borderline value inside a run would
/// release the range into the middle of the deviation.
///
/// This is the thesis's fixed personal reference: each window is scored as if it followed
/// the resting context directly.
enum Anchoring {
    struct Selection {
        /// The expected range of each step, nil where no forecast was available.
        var bands: [Band?] = []
        /// How many steps ahead of its forecast origin each range is; above 1 inside a run.
        var horizons: [Int] = []
        /// The origin to use for the steps after the last one.
        var anchor: Int
    }

    /// - Parameter forecast: the range for `origin + ahead`, forecast from data up to and including `origin`.
    static func select(
        observed: [Double], steps: ClosedRange<Int>, maxFrozenSteps: Int, threshold: Double,
        forecast: (_ origin: Int, _ ahead: Int) -> Band?
    ) -> Selection {
        var selection = Selection(anchor: steps.lowerBound - 1)
        for step in steps {
            let ahead = step - selection.anchor
            let band = forecast(selection.anchor, ahead)
            selection.bands.append(band)
            selection.horizons.append(ahead)

            let value = observed[step]
            let deviates = band.map { band in
                guard value.isFinite else { return false }
                return ahead == 1 ? abs(band.standardizedResidual(of: value)) >= threshold : !band.contains(value)
            } ?? false
            // A step without data inside a run does not end the run.
            let staysFrozen = deviates || (!value.isFinite && ahead > 1 && band != nil)
            if !(staysFrozen && ahead < maxFrozenSteps) {
                selection.anchor = step
            }
        }
        return selection
    }
}
