import CoreML
import Foundation
import os

/// One forecasting problem: targets that are forecast jointly, and what else the model may look at.
/// Histories are oldest first, with `.nan` for a missing value.
public struct ForecastTask: Sendable {
    public var targets: [[Double]]
    /// Related series whose future is unknown.
    public var pastCovariates: [[Double]]
    public var knownCovariates: [KnownCovariate]

    public init(targets: [[Double]], pastCovariates: [[Double]] = [], knownCovariates: [KnownCovariate] = []) {
        self.targets = targets
        self.pastCovariates = pastCovariates
        self.knownCovariates = knownCovariates
    }

    var rowCount: Int { targets.count + pastCovariates.count + knownCovariates.count }
}

/// A covariate whose values over the forecast horizon are known, such as the day of the week.
public struct KnownCovariate: Sendable {
    public var past: [Double]
    /// Up to one value per forecast step; `.nan` or a shorter array leaves a step unknown.
    public var future: [Double]

    public init(past: [Double], future: [Double]) {
        self.past = past
        self.future = future
    }
}

public enum ForecastError: Error {
    case modelMissing
    case unexpectedModelLayout(String)
    case taskTooLarge(rows: Int, limit: Int)
}

/// Chronos-2-small running on Core ML, entirely on the device.
///
/// The model takes a fixed batch of rows, so tasks are packed into as few calls as fit.
/// `chronos-health/scripts/06_export_coreml.py` produces the model and documents its inputs.
public actor Chronos2Forecaster {
    public static let shared = Chronos2Forecaster()

    /// Seconds of model time and number of model calls since launch, for the diagnostics screen.
    public private(set) var usage = (seconds: 0.0, calls: 0)

    private lazy var loading = Task { try await LoadedModel.load() }
    private let log = Logger(subsystem: "Baseline", category: "Chronos2")

    public init() {}

    /// Loads the model ahead of the first forecast.
    public func prepare() async throws {
        _ = try await loading.value
    }

    /// Forecasts every task. The result has one array per task, holding one expected range
    /// per forecast step for each of the task's targets.
    public func forecast(_ tasks: [ForecastTask]) async throws -> [[[Band]]] {
        let loaded = try await loading.value
        var results = tasks.map { _ in [[Band]]() }
        let clock = ContinuousClock()
        let start = clock.now
        let batches = try Batch.pack(tasks, layout: loaded.layout)
        for batch in batches {
            try Task.checkCancellation()
            let quantiles = try loaded.quantiles(for: batch)
            for (task, rows) in batch.targets {
                results[task] = rows.map { loaded.bands(in: quantiles, row: $0) }
            }
        }
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        usage.seconds += seconds
        usage.calls += batches.count
        log.info("\(tasks.count) tasks in \(batches.count) model calls: \(seconds, format: .fixed(precision: 3)) s")
        return results
    }
}

/// The fixed input shape of the exported graph.
struct ModelLayout: Equatable {
    var rows: Int
    var context: Int
    var horizon: Int
}

/// The inputs of one model call, laid out as `thesis.coreml.fixtures.pack` does:
/// channel 0 holds values, channel 1 holds 1 where the value is observed.
struct Batch {
    var context: [Float]
    var knownFuture: [Float]
    var groups: [Int32]
    /// For each task in this batch, the rows that hold its targets.
    var targets: [(task: Int, rows: Range<Int>)] = []
    private var usedRows = 0
    private let layout: ModelLayout

    private init(layout: ModelLayout) {
        self.layout = layout
        context = Array(repeating: 0, count: layout.rows * 2 * layout.context)
        knownFuture = Array(repeating: 0, count: layout.rows * 2 * layout.horizon)
        // A row that no task uses keeps its own index, which no task has as its group.
        groups = (0..<Int32(layout.rows)).map { $0 }
    }

    /// Packs tasks in order, starting a new batch when the next task does not fit.
    static func pack(_ tasks: [ForecastTask], layout: ModelLayout) throws -> [Batch] {
        var batches: [Batch] = []
        var current = Batch(layout: layout)
        for (index, task) in tasks.enumerated() {
            guard task.rowCount <= layout.rows else {
                throw ForecastError.taskTooLarge(rows: task.rowCount, limit: layout.rows)
            }
            if current.usedRows + task.rowCount > layout.rows {
                batches.append(current)
                current = Batch(layout: layout)
            }
            current.add(task, index: index)
        }
        if current.usedRows > 0 { batches.append(current) }
        return batches
    }

    private mutating func add(_ task: ForecastTask, index: Int) {
        let group = Int32(targets.count)
        targets.append((index, usedRows..<usedRows + task.targets.count))
        let unknownFuture = (task.targets + task.pastCovariates).map { ($0, [Double]()) }
        for (history, future) in unknownFuture + task.knownCovariates.map({ ($0.past, $0.future) }) {
            let recent = history.suffix(layout.context)
            Self.write(recent, into: &context, row: usedRows, offset: layout.context - recent.count, length: layout.context)
            Self.write(future.prefix(layout.horizon), into: &knownFuture, row: usedRows, offset: 0, length: layout.horizon)
            groups[usedRows] = group
            usedRows += 1
        }
    }

    /// Writes values and their observed flags into one row of a `rows × 2 × length` buffer.
    private static func write(_ values: some Collection<Double>, into buffer: inout [Float], row: Int, offset: Int, length: Int) {
        let valueStart = row * 2 * length + offset
        for (index, value) in values.enumerated() where value.isFinite {
            buffer[valueStart + index] = Float(value)
            buffer[valueStart + length + index] = 1
        }
    }
}

/// The compiled Core ML model and what its metadata says about its layout.
private struct LoadedModel: @unchecked Sendable {  // MLModel predicts safely from any thread; it predates Sendable.
    let model: MLModel
    let layout: ModelLayout
    /// Positions of q10, q50 and q90 among the model's quantile levels.
    let levels: (lower: Int, median: Int, upper: Int)
    let levelCount: Int

    static func load() async throws -> LoadedModel {
        let configuration = MLModelConfiguration()
        // The graph computes in float32, which the Neural Engine does not run, and a
        // background task may not use the GPU.
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: try await compiledModel(), configuration: configuration)

        let inputs = model.modelDescription.inputDescriptionsByName
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        let quantileLevels = metadata?["quantile_levels"]?.split(separator: ",").compactMap { Double($0) } ?? []
        guard
            let context = inputs["context"]?.multiArrayConstraint?.shape.map(\.intValue), context.count == 3,
            let horizon = inputs["known_future"]?.multiArrayConstraint?.shape.last?.intValue,
            let lower = quantileLevels.firstIndex(of: 0.1),
            let median = quantileLevels.firstIndex(of: 0.5),
            let upper = quantileLevels.firstIndex(of: 0.9)
        else {
            throw ForecastError.unexpectedModelLayout("inputs \(inputs.keys.sorted()), quantile levels \(quantileLevels)")
        }
        return LoadedModel(
            model: model,
            layout: ModelLayout(rows: context[0], context: context[2], horizon: horizon),
            levels: (lower, median, upper),
            levelCount: quantileLevels.count)
    }

    /// The compiled model. The package ships the model as it was exported and compiles it
    /// on first use, keeping the result in Caches; the package's own identifier names the
    /// compiled copy, so a new export is compiled again. A build system that compiled the
    /// model itself is used as is.
    private static func compiledModel() async throws -> URL {
        if let prebuilt = Bundle.module.url(forResource: "Chronos2Small", withExtension: "mlmodelc") { return prebuilt }
        guard let package = Bundle.module.url(forResource: "Chronos2Small", withExtension: "mlpackage") else {
            throw ForecastError.modelMissing
        }
        struct Manifest: Decodable { var rootModelIdentifier: String }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: package.appending(path: "Manifest.json")))
        let folder = URL.cachesDirectory.appending(path: "Baseline")
        let cached = folder.appending(path: "Chronos2Small-\(manifest.rootModelIdentifier).mlmodelc")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        let fresh = try await MLModel.compileModel(at: package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fresh, to: cached)
        return cached
    }

    /// Runs the model on one batch: `rows × levels × horizon` values, row-major.
    func quantiles(for batch: Batch) throws -> [Float] {
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "context": MLMultiArray(MLShapedArray(scalars: batch.context, shape: [layout.rows, 2, layout.context])),
            "known_future": MLMultiArray(MLShapedArray(scalars: batch.knownFuture, shape: [layout.rows, 2, layout.horizon])),
            "group_ids": MLMultiArray(MLShapedArray(scalars: batch.groups, shape: [layout.rows])),
        ])
        let output = try model.prediction(from: inputs)
        guard let quantiles = output.featureValue(for: "quantiles")?.shapedArrayValue(of: Float.self) else {
            throw ForecastError.unexpectedModelLayout("no float `quantiles` output")
        }
        return quantiles.scalars
    }

    func bands(in quantiles: [Float], row: Int) -> [Band] {
        (0..<layout.horizon).map { step in
            func value(_ level: Int) -> Double { Double(quantiles[(row * levelCount + level) * layout.horizon + step]) }
            // Neighbouring quantiles of a compressed model can cross by a hair; keep the band ordered.
            let ordered = [value(levels.lower), value(levels.median), value(levels.upper)].sorted()
            return Band(lower: ordered[0], median: ordered[1], upper: ordered[2])
        }
    }
}
