import Foundation

public protocol HealthDataProvider: Sendable {
    func requestAccess() async throws
    func dailyHistory(days: Int) async throws -> DailyHistory
    func intradayHistory(hours: Int) async throws -> IntradayHistory
}

extension HealthDataProvider {
    public func requestAccess() async throws {}
}

public struct DailyHistory: Sendable {
    public var days: [Date]
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

    public var start: Date
    public var heartRate: [Double]
    public var steps: [Double]
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
    public func days(count: Int, endingAt end: Date) -> [Date] {
        let today = startOfDay(for: end)
        return (0..<count).reversed().compactMap { date(byAdding: .day, value: -$0, to: today) }
    }
}
