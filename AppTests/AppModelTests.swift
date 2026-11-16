import Foundation
import HealthData
import Testing
@testable import Baseline

/// Apple Health that never gets its access sheet answered: the request hangs until the
/// test lets it fail, the way the real one fails with a timeout after a minute.
private struct UnansweredHealth: HealthDataProvider {
    struct TimedOut: LocalizedError {
        var errorDescription: String? { "Authorization session timed out" }
    }

    let asked: AsyncStream<Void>.Continuation
    let timeout: AsyncStream<Void>

    func requestAccess() async throws {
        asked.yield()
        // Like the real request, the wait takes no notice of its caller being cancelled.
        await Task.detached { for await _ in timeout {} }.value
        throw TimedOut()
    }

    func dailyHistory(days: Int) async throws -> DailyHistory { DailyHistory(days: [], values: [:], workouts: []) }
    func intradayHistory(hours: Int) async throws -> IntradayHistory { IntradayHistory(start: .now, heartRate: [], steps: [], isMasked: []) }
}

@MainActor
private func modelWithUnansweredHealth() -> (model: AppModel, asked: AsyncStream<Void>, timeOut: () -> Void) {
    let (asked, askedContinuation) = AsyncStream.makeStream(of: Void.self)
    let (timeout, timeoutContinuation) = AsyncStream.makeStream(of: Void.self)
    // Settings of its own: these tests run inside the app and must leave its settings alone.
    let defaults = UserDefaults(suiteName: "AppModelTests")!
    defaults.removePersistentDomain(forName: "AppModelTests")
    let model = AppModel(defaults: defaults)
    // The few days of the first-days scenario keep the demo's own load short.
    model.scenario = .coldStart
    model.healthProvider = { UnansweredHealth(asked: askedContinuation, timeout: timeout) }
    return (model, asked, { timeoutContinuation.finish() })
}

/// What a tester did: connect Apple Health, see nothing happen, go on with the demo. A
/// minute later the Health request failed and took the app over, with no way back.
@Test @MainActor func aHealthRequestThatFailsLateLeavesTheDemoAlone() async {
    let (model, asked, timeOut) = modelWithUnansweredHealth()

    model.choose(.health)
    #expect(model.phase == .loading)
    let abandoned = Task { await model.refresh() }
    for await _ in asked { break }

    model.choose(.demo)
    await model.refresh()
    #expect(model.phase == .ready)

    timeOut()
    await abandoned.value
    #expect(model.dataSource == .demo)
    #expect(model.phase == .ready)
}

@Test @MainActor func aHealthRequestThatFailsCanBeLeftForTheDemo() async {
    let (model, _, timeOut) = modelWithUnansweredHealth()

    model.choose(.health)
    timeOut()
    await model.refresh()
    #expect(model.phase == .failed("Authorization session timed out"))

    // The failure screen's second button.
    model.choose(.demo)
    #expect(model.phase == .loading)
    await model.refresh()
    #expect(model.phase == .ready)
}
