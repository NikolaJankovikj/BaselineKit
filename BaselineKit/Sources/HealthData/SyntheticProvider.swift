import Foundation

public struct SyntheticProvider: HealthDataProvider {
    public enum Scenario: String, CaseIterable, Sendable, Identifiable {
        case sickWeek
        case healthy
        case coldStart

        public var id: Self { self }
    }

    public var scenario: Scenario
    public var now: Date
    public var calendar: Calendar

    public init(scenario: Scenario = .sickWeek, now: Date = .now, calendar: Calendar = .current) {
        self.scenario = scenario
        self.now = now
        self.calendar = calendar
    }

    public var logs: [ManualLog] {
        guard scenario != .coldStart else { return [] }
        return [(Script.alcoholNight + 1, ManualLog.Kind.alcohol), (Script.hardBlock.upperBound, .hardTraining)]
            .compactMap { daysAgo, kind in
                calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))
                    .map { ManualLog(date: $0.addingTimeInterval(20 * 3600), kind: kind) }
            }
    }

    public func dailyHistory(days requested: Int) async throws -> DailyHistory {
        let count = scenario == .coldStart ? min(requested, Script.coldStartDays) : requested
        let days = calendar.days(count: count, endingAt: now)
        var rng = SeededGenerator(seed: 7)
        var values = Dictionary(uniqueKeysWithValues: Metric.allCases.map { ($0, [Double]()) })
        var workouts: [Workout] = []
        var fatigue = 0.0
        var yesterdayEnergy = Level.activeEnergy

        for (index, day) in days.enumerated() {
            let script = Script(daysAgo: count - 1 - index, scenario: scenario)
            let weekday = calendar.component(.weekday, from: day)
            let isWeekend = weekday == 1 || weekday == 7

            fatigue = 0.6 * fatigue + 0.8 * rng.gaussian()
            let strain = fatigue + 0.7 * (yesterdayEnergy - Level.activeEnergy) / 230
            let ill = script.illness
            var night: [Metric: Double] = [
                .restingHeartRate: Level.restingHeartRate + 1.3 * strain + 0.8 * rng.gaussian() + 9 * ill + script.heartRate,
                .heartRateVariability: max(12, Level.hrv - 4.5 * strain + 3.5 * rng.gaussian() - 22 * ill + script.variability),
                .respiratoryRate: 14.6 + 0.12 * strain + 0.3 * rng.gaussian() + 1.8 * ill,
                .wristTemperature: 35.4 + 0.2 * rng.gaussian() + 0.9 * ill + script.temperature,
                .sleepDuration: 7.3 + (isWeekend ? 0.5 : 0) + 0.6 * rng.gaussian() + 0.5 * ill + script.sleep,
            ]
            if !script.isScripted, rng.unit() < 0.03 {
                night = [:]
            }

            let trains = script.hardTraining || (ill == 0 && rng.unit() < 0.4)
            let minutes = !trains ? 0 : script.hardTraining ? 95 : 35 + 35 * rng.unit()
            let activity = 1 - 0.55 * ill
            let energy = max(120, (Level.activeEnergy - 180 + 7.5 * minutes + 60 * rng.gaussian()) * activity)
            let steps = max(800, (7800 + (isWeekend ? 900 : 0) + 45 * minutes + 1900 * rng.gaussian()) * activity)
            if trains {
                let start = day.addingTimeInterval(18 * 3600)
                workouts.append(Workout(start: start, kind: minutes > 80 ? "Long run" : "Run", minutes: minutes, energy: 7.5 * minutes))
            }
            let dayFraction = index == count - 1 ? now.timeIntervalSince(day) / 86_400 : 1

            for metric in Metric.allCases where metric.isOvernight {
                values[metric]?.append(night[metric] ?? .nan)
            }
            values[.steps]?.append((steps * dayFraction).rounded())
            values[.activeEnergy]?.append((energy * dayFraction).rounded())
            let measuresFitness = trains && rng.unit() < 0.6
            values[.vo2Max]?.append(measuresFitness ? 44 + 0.004 * Double(index) + 0.4 * rng.gaussian() : .nan)
            yesterdayEnergy = energy
        }
        return DailyHistory(days: days, values: values, workouts: workouts)
    }

    public func intradayHistory(hours: Int) async throws -> IntradayHistory {
        let bin = IntradayHistory.binSeconds
        let end = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / bin).rounded(.down) * bin)
        let count = hours * Int(3600 / bin)
        let start = end.addingTimeInterval(-Double(count) * bin)
        let today = calendar.startOfDay(for: now)
        let wakeUp = today.addingTimeInterval(7.5 * 3600)
        let recent = end.addingTimeInterval(-4.5 * 3600)
        let stress = DateInterval(start: recent >= wakeUp ? recent : today.addingTimeInterval(-10 * 3600), duration: 90 * 60)
        // Sitting still from half an hour before, so the rise is not the tail of a walk.
        let seated = DateInterval(start: stress.start.addingTimeInterval(-30 * 60), end: stress.end)
        let illnessBump = scenario == .sickWeek ? 7.0 : 0

        var rng = SeededGenerator(seed: 11)
        var history = IntradayHistory(start: start, heartRate: [], steps: [], isMasked: [])
        var previousSteps = 0.0
        for index in 0..<count {
            let time = start.addingTimeInterval(Double(index) * bin)
            let hour = time.timeIntervalSince(calendar.startOfDay(for: time)) / 3600
            let asleep = hour >= 23.5 || hour < 7
            let inWorkout = scenario != .sickWeek && (18..<19).contains(hour) && time < today
            let stressed = scenario != .coldStart && stress.contains(time)
            let sitting = scenario != .coldStart && seated.contains(time)
            let commuting = (8..<8.67).contains(hour) || (17.33..<17.83).contains(hour)

            let steps: Double =
                if asleep { 0 }
                else if inWorkout { 620 + 120 * rng.unit() }
                else if sitting { 10 * rng.unit() }
                else if commuting { 400 + 150 * rng.unit() }
                else if rng.unit() < 0.18 { 150 + 300 * rng.unit() }
                else { 25 * rng.unit() }
            var heartRate = asleep
                ? Level.restingHeartRate - 4 + 1.2 * rng.gaussian()
                : Level.restingHeartRate + 9 + 0.05 * (0.6 * steps + 0.4 * previousSteps) + 2.5 * rng.gaussian()
            if inWorkout { heartRate = 140 + 6 * rng.gaussian() }
            if stressed { heartRate += 19 }
            heartRate += illnessBump
            let observed = rng.unit() < (asleep ? 0.6 : 0.85)

            history.heartRate.append(observed ? heartRate : .nan)
            history.steps.append(steps.rounded())
            history.isMasked.append(asleep || inWorkout)
            previousSteps = steps
        }
        return history
    }
}

private enum Level {
    static let restingHeartRate = 57.0
    static let hrv = 62.0
    static let activeEnergy = 560.0
}

private struct Script {
    static let coldStartDays = 9
    static let alcoholNight = 12
    static let hardBlock = 24...26
    static let shortSleepNight = 40
    static let illnessCourse = [0.85, 1.0, 0.9, 0.55]

    var illness = 0.0
    var hardTraining = false
    var heartRate = 0.0
    var variability = 0.0
    var temperature = 0.0
    var sleep = 0.0

    var isScripted: Bool { illness > 0 || heartRate != 0 || sleep != 0 }

    init(daysAgo: Int, scenario: SyntheticProvider.Scenario) {
        guard scenario != .coldStart else { return }
        if scenario == .sickWeek, Self.illnessCourse.indices.contains(daysAgo) {
            illness = Self.illnessCourse[daysAgo]
        }
        hardTraining = Self.hardBlock.contains(daysAgo)
        if daysAgo == Self.alcoholNight {
            (heartRate, variability, temperature, sleep) = (6, -18, 0.3, -1.5)
        }
        if Self.hardBlock.contains(daysAgo + 1) {
            (heartRate, variability) = (5, -16)
        }
        if daysAgo == Self.shortSleepNight {
            sleep = -2.6
        }
    }
}

/// SplitMix64: small, seedable, and the same on every platform.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double.random(in: 0..<1, using: &self) }

    mutating func gaussian() -> Double {
        let radius = (-2 * log(Double.random(in: .leastNonzeroMagnitude...1, using: &self))).squareRoot()
        return radius * cos(2 * .pi * unit())
    }
}
