import Foundation
import FoundationModels
import HealthData

extension AskSession {
    public struct Lookup: Sendable, Equatable, Identifiable {
        public var title: String
        public var result: String

        public var id: String { title + result }
    }

    typealias Record = @MainActor @Sendable (Lookup) -> Void

    nonisolated static func tools(for snapshot: HealthSnapshot, record log: @escaping Record) -> [any Tool] {
        [
            DataTool<NightArguments>(
                name: "sleep", description: "One night's sleep and overnight vitals: resting heart rate, heart rate variability, breathing rate and wrist temperature",
                log: log
            ) { Lookup(title: "Sleep: \(snapshot.nightLabel(endingOn: snapshot.day(daysAgo: $0.nightsAgo)))", result: snapshot.sleepSummary(for: snapshot.day(daysAgo: $0.nightsAgo))) },
            DataTool<MetricArguments>(
                name: "metric", description: "Average, lowest, highest and latest value of one metric over recent days, against its expected range", log: log
            ) { arguments in
                let metric = Metric(rawValue: arguments.metric) ?? .restingHeartRate
                return Lookup(title: "\(metric.title), \(period(arguments.days))", result: snapshot.statsSummary(of: metric, days: arguments.days))
            },
            DataTool<DaysArguments>(name: "workouts", description: "The workouts they did in recent days", log: log) {
                Lookup(title: "Workouts, \(period($0.days))", result: snapshot.workoutsSummary(days: $0.days))
            },
            DataTool<DaysArguments>(name: "logs", description: "What they logged in recent days: alcohol, caffeine, feeling sick, stress, hard training, travel", log: log) {
                Lookup(title: "Logs, \(period($0.days))", result: snapshot.logsSummary(days: $0.days))
            },
            DataTool<DaysArguments>(name: "flagged", description: "What the app flagged as unusual in recent days, such as strain, short sleep or a stress episode", log: log) {
                Lookup(title: "Flagged, \(period($0.days))", result: snapshot.anomaliesSummary(days: $0.days))
            },
        ]
    }

    nonisolated static func period(_ days: Int) -> String {
        days == 1 ? "today" : "last \(days) days"
    }
}

struct DataTool<Arguments: Generable & Sendable>: Tool {
    let name: String
    let description: String
    let log: AskSession.Record
    let look: @Sendable (Arguments) -> AskSession.Lookup

    func call(arguments: Arguments) async throws -> String {
        let lookup = look(arguments)
        // Shown in the chat as the call is made, before the model has the result.
        await log(lookup)
        return lookup.result
    }
}

@Generable struct NightArguments {
    @Guide(description: "Which night: 0 for last night, 1 for the night before, and so on", .range(0...13))
    var nightsAgo: Int
}

@Generable struct DaysArguments {
    @Guide(description: "How many days back to look: 1 for today, 7 for a week, 30 for a month, 90 for three months", .range(1...90))
    var days: Int
}

@Generable struct MetricArguments {
    @Guide(description: "The metric", .anyOf(Metric.allCases.map(\.rawValue)))
    var metric: String
    @Guide(description: "How many days back to look: 7 for a week, 30 for a month, 90 for three months", .range(1...90))
    var days: Int
}
