import Foundation

/// Where the app's health data comes from: HealthKit, or a synthetic person for demos and tests.
public protocol HealthDataProvider: Sendable {
    /// Asks the user for access, where the source needs that before it can be read.
    func requestAccess() async throws
    /// The last `days` days ending today.
    func dailyHistory(days: Int) async throws -> DailyHistory
    /// The last `hours` hours in 5-minute bins.
    func intradayHistory(hours: Int) async throws -> IntradayHistory
}

extension HealthDataProvider {
    public func requestAccess() async throws {}
}

public struct DailyHistory: Sendable {
    /// Consecutive local midnights, oldest first; the last one is today.
    public var days: [Date]
    /// One array per metric, aligned with `days`; `.nan` where nothing was recorded.
    public var values: [Metric: [Double]]
    public var workouts: [Workout]

    public init(days: [Date], values: [Metric: [Double]], workouts: [Workout]) {
        self.days = days
        self.values = values
        self.workouts = workouts
    }

    public func series(_ metric: Metric) -> [Double] {
        values[metric] ?? Array(repeating: .nan, count: days.count)
    }

    /// Nights with at least one overnight signal: how much the baseline has to learn from.
    public var nightsOfData: Int {
        let overnight = Metric.allCases.filter(\.isOvernight).map(series)
        return days.indices.count { day in overnight.contains { $0[day].isFinite } }
    }
}

public struct Workout: Sendable, Codable, Hashable {
    public var start: Date
    public var kind: String
    public var minutes: Double
    public var energy: Double

    public init(start: Date, kind: String, minutes: Double, energy: Double) {
        self.start = start
        self.kind = kind
        self.minutes = minutes
        self.energy = energy
    }
}

public struct IntradayHistory: Sendable {
    public static let binSeconds: TimeInterval = 300

    /// Start of the first bin.
    public var start: Date
    /// Mean heart rate per bin in bpm; `.nan` where there was no sample.
    public var heartRate: [Double]
    /// Steps taken in each bin.
    public var steps: [Double]
    /// Asleep or in a workout: such bins are neither scored nor part of the resting reference.
    public var isMasked: [Bool]

    public init(start: Date, heartRate: [Double], steps: [Double], isMasked: [Bool]) {
        self.start = start
        self.heartRate = heartRate
        self.steps = steps
        self.isMasked = isMasked
    }

    public func time(ofBin index: Int) -> Date {
        start.addingTimeInterval(Double(index) * Self.binSeconds)
    }
}

extension Calendar {
    /// `count` consecutive midnights ending with the day that contains `end`.
    public func days(count: Int, endingAt end: Date) -> [Date] {
        let today = startOfDay(for: end)
        return (0..<count).reversed().compactMap { date(byAdding: .day, value: -$0, to: today) }
    }
}
