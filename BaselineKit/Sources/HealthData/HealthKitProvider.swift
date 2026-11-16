import Foundation
import HealthKit

public struct HealthKitProvider: HealthDataProvider {
    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    private static let beatsPerMinute = HKUnit.count().unitDivided(by: .minute())
    private static let sleepType = HKCategoryType(.sleepAnalysis)
    private static let alcoholType = HKQuantityType(.numberOfAlcoholicBeverages)

    private static let quantities: [Metric: (HKQuantityTypeIdentifier, HKUnit)] = [
        .restingHeartRate: (.restingHeartRate, beatsPerMinute),
        .heartRateVariability: (.heartRateVariabilitySDNN, .secondUnit(with: .milli)),
        .respiratoryRate: (.respiratoryRate, beatsPerMinute),
        .wristTemperature: (.appleSleepingWristTemperature, .degreeCelsius()),
        .steps: (.stepCount, .count()),
        .activeEnergy: (.activeEnergyBurned, .kilocalorie()),
        .vo2Max: (.vo2Max, HKUnit(from: "ml/kg*min")),
    ]

    /// Stamped at night by the watch, so they are bucketed by sleep day. Resting heart
    /// rate is not: Health stores it as one sample per calendar day.
    private static let sampledDuringSleep: Set<Metric> = [.respiratoryRate, .wristTemperature]

    private static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [sleepType, HKQuantityType(.heartRate), HKObjectType.workoutType()]
        for (identifier, _) in quantities.values { types.insert(HKQuantityType(identifier)) }
        return types
    }

    /// Asks for read access to everything the app shows, and write access for alcohol logs.
    /// The system shows its sheet only for data types it has not asked about yet: when
    /// Apple Health is first connected, and after an update that reads more. Otherwise this
    /// returns at once, so it is called before every read.
    public func requestAccess() async throws {
        try await store.requestAuthorization(toShare: [Self.alcoholType], read: Self.readTypes)
    }

    public func dailyHistory(days count: Int) async throws -> DailyHistory {
        let days = calendar.days(count: count, endingAt: .now)
        guard let first = days.first, let nightStart = calendar.date(byAdding: .hour, value: -SleepDay.startsHoursBeforeMidnight, to: first) else {
            return DailyHistory(days: [], values: [:], workouts: [])
        }
        let sleep = try await asleepIntervals(from: nightStart)
        var values: [Metric: [Double]] = [:]
        for (metric, (identifier, unit)) in Self.quantities where metric != .heartRateVariability {
            values[metric] = try await buckets(
                identifier, unit: unit, sum: metric.accumulatesOverDay,
                from: Self.sampledDuringSleep.contains(metric) ? nightStart : first, every: DateComponents(day: 1), count: count)
        }
        values[.sleepDuration] = days.map { day in
            sleep[day].map(SleepDay.hoursCovered) ?? .nan
        }
        values[.heartRateVariability] = try await nightlyVariability(days: days, from: nightStart, sleep: sleep)
        return DailyHistory(days: days, values: values, workouts: try await workouts(from: first))
    }

    private func buckets(
        _ identifier: HKQuantityTypeIdentifier, unit: HKUnit, sum: Bool,
        from anchor: Date, every interval: DateComponents, count: Int
    ) async throws -> [Double] {
        let starts = (0...count).compactMap { step in
            calendar.date(byAdding: DateComponents(day: interval.day.map { $0 * step }, minute: interval.minute.map { $0 * step }), to: anchor)
        }
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(identifier), predicate: HKQuery.predicateForSamples(withStart: anchor, end: starts.last)),
            options: sum ? .cumulativeSum : .discreteAverage,
            anchorDate: anchor,
            intervalComponents: interval)
        let collection = try await descriptor.result(for: store)
        return starts.dropLast().map { start in
            let statistics = collection.statistics(for: start)
            let quantity = sum ? statistics?.sumQuantity() : statistics?.averageQuantity()
            return quantity?.doubleValue(for: unit) ?? .nan
        }
    }

    private func asleepIntervals(from start: Date) async throws -> [Date: [DateInterval]] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: Self.sleepType, predicate: HKQuery.predicateForSamples(withStart: start, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let asleep = try await descriptor.result(for: store).filter { sample in
            HKCategoryValueSleepAnalysis(rawValue: sample.value).map(HKCategoryValueSleepAnalysis.allAsleepValues.contains) ?? false
        }
        return Dictionary(grouping: asleep.map { DateInterval(start: $0.startDate, end: $0.endDate) }) {
            SleepDay.day(containing: $0.start, calendar: calendar)
        }.mapValues(SleepDay.merged)
    }

    private func nightlyVariability(days: [Date], from start: Date, sleep: [Date: [DateInterval]]) async throws -> [Double] {
        let type = HKQuantityType(.heartRateVariabilitySDNN)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: HKQuery.predicateForSamples(withStart: start, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let byDay = Dictionary(grouping: try await descriptor.result(for: store)) {
            SleepDay.day(containing: $0.startDate, calendar: calendar)
        }
        return days.map { day in
            let samples = byDay[day] ?? []
            let asleep = samples.filter { sample in sleep[day]?.contains { $0.contains(sample.startDate) } ?? false }
            let used = asleep.isEmpty ? samples : asleep
            guard !used.isEmpty else { return .nan }
            return used.reduce(0) { $0 + $1.quantity.doubleValue(for: .secondUnit(with: .milli)) } / Double(used.count)
        }
    }

    private func workoutSamples(from start: Date) async throws -> [HKWorkout] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        return try await descriptor.result(for: store)
    }

    private func workouts(from start: Date) async throws -> [Workout] {
        try await workoutSamples(from: start).map { workout in
            let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()
            return Workout(
                start: workout.startDate, kind: workout.workoutActivityType.name,
                minutes: workout.duration / 60, energy: energy?.doubleValue(for: .kilocalorie()) ?? 0)
        }
    }

    public func intradayHistory(hours: Int) async throws -> IntradayHistory {
        let bin = IntradayHistory.binSeconds
        let end = Date(timeIntervalSinceReferenceDate: (Date.now.timeIntervalSinceReferenceDate / bin).rounded(.down) * bin)
        let count = hours * Int(3600 / bin)
        let start = end.addingTimeInterval(-Double(count) * bin)
        let every = DateComponents(minute: Int(bin / 60))
        let heartRate = try await buckets(.heartRate, unit: Self.beatsPerMinute, sum: false, from: start, every: every, count: count)
        let steps = try await buckets(.stepCount, unit: .count(), sum: true, from: start, every: every, count: count)
        let asleep = try await asleepIntervals(from: start).values.flatMap(\.self)
        let training = try await workoutSamples(from: start).map { DateInterval(start: $0.startDate, end: $0.endDate) }
        let masked = SleepDay.merged(asleep + training)
        var history = IntradayHistory(start: start, heartRate: heartRate, steps: steps.map { $0.isNaN ? 0 : $0 }, isMasked: [])
        history.isMasked = (0..<count).map { index in
            let middle = history.time(ofBin: index).addingTimeInterval(bin / 2)
            return masked.contains { $0.contains(middle) }
        }
        return history
    }

    /// Saves a manual log to Apple Health where Health has a matching type.
    /// Only alcohol has one that a single tap can fill: caffeine in Health is a dose in milligrams.
    public func save(_ log: ManualLog) async throws {
        guard log.kind == .alcohol else { return }
        let drink = HKQuantity(unit: .count(), doubleValue: 1)
        try await store.save(HKQuantitySample(type: Self.alcoholType, quantity: drink, start: log.date, end: log.date))
    }

    public func observeOvernightData(_ onUpdate: @escaping @Sendable () async -> Void) async throws {
        let types: [HKSampleType] = [Self.sleepType, HKQuantityType(.restingHeartRate), HKQuantityType(.heartRateVariabilitySDNN)]
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, finished, error in
                guard error == nil else { return finished() }
                let finished = AnyThreadCompletion(call: finished)
                Task {
                    await onUpdate()
                    finished.call()
                }
            }
            store.execute(query)
            try await store.enableBackgroundDelivery(for: type, frequency: .hourly)
        }
    }
}

/// HealthKit lets an observer's completion handler be called from any thread; its type
/// just predates `Sendable`.
private struct AnyThreadCompletion: @unchecked Sendable {
    let call: () -> Void
}

extension HKWorkoutActivityType {
    fileprivate var name: String {
        switch self {
        case .running: "Run"
        case .walking: "Walk"
        case .hiking: "Hike"
        case .cycling: "Ride"
        case .swimming: "Swim"
        case .yoga: "Yoga"
        case .highIntensityIntervalTraining: "HIIT"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength"
        default: "Workout"
        }
    }
}

extension HealthKitProvider {
    /// Debug aid: copies a (synthetic) history into Apple Health, so the HealthKit path has
    /// data in the simulator. Wrist temperature and workouts are left out: the first is
    /// read-only in HealthKit, the second needs a workout session to write.
    public func writeSampleData(_ history: DailyHistory, intraday: IntradayHistory) async throws {
        let writable: [Metric] = [.restingHeartRate, .heartRateVariability, .respiratoryRate, .steps, .activeEnergy]
        let heartRate = HKQuantityType(.heartRate)
        let steps = HKQuantityType(.stepCount)
        let types = writable.compactMap { Self.quantities[$0].map { HKQuantityType($0.0) as HKSampleType } } + [Self.sleepType, heartRate]
        try await store.requestAuthorization(toShare: Set(types), read: [])
        // Writing again replaces what an earlier run wrote; otherwise steps and energy add up.
        for type in types {
            try await store.deleteObjects(of: type, predicate: HKQuery.predicateForObjects(from: .default()))
        }

        var samples: [HKSample] = []
        let firstIntradayDay = calendar.startOfDay(for: intraday.start)
        for (index, day) in history.days.enumerated() {
            let wake = day.addingTimeInterval(7 * 3600)
            guard wake <= .now else { continue }
            for metric in writable {
                // Today's totals are still growing, and the days with intraday bins get their steps from those.
                let isCovered = metric.accumulatesOverDay && (day == history.days.last || (metric == .steps && day >= firstIntradayDay))
                guard !isCovered, let (identifier, unit) = Self.quantities[metric], let value = history.values[metric]?[index], value.isFinite else { continue }
                // Daily totals span the waking day; everything else is stamped mid-sleep.
                let span = metric.accumulatesOverDay
                    ? DateInterval(start: wake, duration: 14 * 3600)
                    : DateInterval(start: wake.addingTimeInterval(-4 * 3600), duration: 60)
                samples.append(HKQuantitySample(
                    type: HKQuantityType(identifier), quantity: HKQuantity(unit: unit, doubleValue: value), start: span.start, end: span.end))
            }
            if let hours = history.values[.sleepDuration]?[index], hours.isFinite {
                samples.append(HKCategorySample(
                    type: Self.sleepType, value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    start: wake.addingTimeInterval(-hours * 3600), end: wake))
            }
        }
        for bin in intraday.heartRate.indices {
            let start = intraday.time(ofBin: bin)
            let end = start.addingTimeInterval(IntradayHistory.binSeconds)
            if intraday.heartRate[bin].isFinite {
                samples.append(HKQuantitySample(
                    type: heartRate, quantity: HKQuantity(unit: Self.beatsPerMinute, doubleValue: intraday.heartRate[bin]), start: start, end: end))
            }
            if intraday.steps[bin] >= 1 {
                samples.append(HKQuantitySample(type: steps, quantity: HKQuantity(unit: .count(), doubleValue: intraday.steps[bin].rounded()), start: start, end: end))
            }
        }
        try await store.save(samples)
    }
}
