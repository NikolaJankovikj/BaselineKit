import Foundation
import Testing

@testable import Forecasting

/// What `chronos-health/scripts/06_export_coreml.py` wrote: tasks and the answers of the
/// stock PyTorch pipeline.
struct GoldenFixtures: Decodable {
    struct Task: Decodable {
        struct Known: Decodable {
            var past: [Double?]
            var future: [Double?]
        }

        var name: String
        var target: [[Double?]]
        var past: [[Double?]]?
        var known: [Known]?
        /// target × quantile level × step
        var quantiles: [[[Double]]]

        var forecastTask: ForecastTask {
            func values(_ series: [Double?]) -> [Double] { series.map { $0 ?? .nan } }
            return ForecastTask(
                targets: target.map(values),
                pastCovariates: (past ?? []).map(values),
                knownCovariates: (known ?? []).map { KnownCovariate(past: values($0.past), future: values($0.future)) })
        }
    }

    var quantileLevels: [Double]
    var tolerance: Double
    var tasks: [Task]

    static func load() throws -> GoldenFixtures {
        let url = try #require(Bundle.module.url(forResource: "chronos2_golden", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(GoldenFixtures.self, from: Data(contentsOf: url))
    }

    /// Largest |band − reference| over a task's targets and steps, as a fraction of the
    /// reference q10–q90 width (or of the level, for a flat reference).
    func worstError(of bands: [[Band]], for task: Task) throws -> Double {
        let lower = try #require(quantileLevels.firstIndex(of: 0.1))
        let median = try #require(quantileLevels.firstIndex(of: 0.5))
        let upper = try #require(quantileLevels.firstIndex(of: 0.9))
        var worst = 0.0
        for (target, reference) in zip(bands, task.quantiles) {
            for (step, band) in target.enumerated() {
                let width = max(reference[upper][step] - reference[lower][step], 1e-3 * (1 + abs(reference[median][step])))
                let errors = [band.lower - reference[lower][step], band.median - reference[median][step], band.upper - reference[upper][step]]
                worst = max(worst, errors.map(abs).max()! / width)
            }
        }
        return worst
    }
}

@Test func coreMLModelMatchesPyTorchOnEveryGoldenFixture() async throws {
    let fixtures = try GoldenFixtures.load()
    let forecasts = try await Chronos2Forecaster.shared.forecast(fixtures.tasks.map(\.forecastTask))

    #expect(forecasts.count == fixtures.tasks.count)
    for (task, bands) in zip(fixtures.tasks, forecasts) {
        #expect(bands.count == task.target.count, "\(task.name)")
        let error = try fixtures.worstError(of: bands, for: task)
        #expect(error < fixtures.tolerance, "\(task.name) is off by \(error) of the band width")
    }
}

@Test func tasksInOneBatchDoNotInfluenceEachOther() async throws {
    let fixtures = try GoldenFixtures.load()
    let tasks = fixtures.tasks.map(\.forecastTask)
    let together = try await Chronos2Forecaster.shared.forecast(tasks)
    let alone = try await Chronos2Forecaster.shared.forecast([tasks[0]])

    let first = try #require(together.first?.first)
    let onItsOwn = try #require(alone.first?.first)
    for (a, b) in zip(first, onItsOwn) {
        #expect(abs(a.median - b.median) < 1e-3 * a.sigma)
    }
}

@Test func packingLeftPadsHistoryAndGroupsRowsByTask() throws {
    let layout = ModelLayout(rows: 6, context: 4, horizon: 2)
    let withCovariates = ForecastTask(
        targets: [[5, .nan, 7]],
        pastCovariates: [[1, 2, 3]],
        knownCovariates: [KnownCovariate(past: [0, 1, 0], future: [1, .nan])])
    let batches = try Batch.pack([withCovariates, ForecastTask(targets: [[9]])], layout: layout)

    let batch = try #require(batches.first)
    #expect(batches.count == 1)
    // Row 0: one step of padding, then 5, a gap, 7; followed by the observed flags.
    #expect(Array(batch.context[0..<8]) == [0, 5, 0, 7, 0, 1, 0, 1])
    #expect(batch.groups == [0, 0, 0, 1, 4, 5])
    #expect(batch.targets.map(\.rows) == [0..<1, 3..<4])
    // Only the known covariate (row 2) has a future, and only its first step is known.
    #expect(Array(batch.knownFuture[8..<12]) == [1, 0, 1, 0])
    #expect(batch.knownFuture[0..<8].allSatisfy { $0 == 0 })
}

@Test func packingStartsANewBatchWhenATaskDoesNotFit() throws {
    let layout = ModelLayout(rows: 3, context: 4, horizon: 2)
    let pair = ForecastTask(targets: [[1, 2], [3, 4]])
    let batches = try Batch.pack([pair, pair], layout: layout)

    #expect(batches.count == 2)
    #expect(batches.map { $0.targets.map(\.task) } == [[0], [1]])
    #expect(throws: ForecastError.self) {
        try Batch.pack([ForecastTask(targets: [[1], [2], [3], [4]])], layout: layout)
    }
}
