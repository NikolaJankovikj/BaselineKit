import FoundationModels
import os

/// The model never computes anything: it gets facts worded by code, answers through guided
/// generation, and the answer is shown only if `InsightGuard` accepts it.
public struct InsightGenerator: Sendable {
    public init() {}

    public static var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static let safetyRules = """
        You are not a clinician: never name a disease or condition, never diagnose, and never mention medication.
        Any suggestion must be a general wellness action: sleep, rest, recovery, hydration, lighter training, slow breathing or mindfulness.
        Do not tell the person to see a doctor; the app decides that separately.
        """

    private static let instructions = """
        You talk with a person about their own wearable data in calm, plain language. Address them as "you".
        Use only the facts you are given. Never add numbers, dates or facts of your own.
        \(safetyRules)
        Explain what the facts show and give one suggestion. Keep every field short.
        """

    private static let log = Logger(subsystem: "Baseline", category: "Insights")

    public func insight(for facts: EventFacts) async -> Sourced<AnomalyInsight> {
        let template = TemplatedInsights.insight(for: facts)
        guard let generated = await generate(AnomalyInsight.self, from: "Explain this event.\n\(facts.prompt)"),
            InsightGuard.accepts(generated.allText, source: facts.prompt)
        else { return Sourced(template, source: .template) }
        return Sourced(generated, source: .appleIntelligence)
    }

    public func advice(for facts: DayFacts) async -> Sourced<MetricAdvice> {
        guard let generated = await generate(MetricAdvice.self, from: "Say what this reading means and what to do.\n\(facts.prompt)"),
            InsightGuard.accepts(generated.allText, source: facts.prompt)
        else { return Sourced(TemplatedInsights.advice(for: facts), source: .template) }
        return Sourced(generated, source: .appleIntelligence)
    }

    public func weeklyReport(for facts: WeekFacts) async -> Sourced<WeeklyReport> {
        var report = TemplatedInsights.report(for: facts)
        guard let wording = await generate(WeekWording.self, from: "Word this week's report.\n\(facts.prompt)"),
            InsightGuard.accepts("\(wording.headline)\n\(wording.focusForNextWeek)", source: facts.prompt)
        else { return Sourced(report, source: .template) }
        report.headline = wording.headline
        report.focusForNextWeek = wording.focusForNextWeek
        return Sourced(report, source: .appleIntelligence)
    }

    func generate<Content: Generable>(_ type: Content.Type, from prompt: String) async -> Content? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            // Greedy sampling: the same facts always get the same explanation.
            return try await session.respond(to: prompt, generating: type, options: GenerationOptions(samplingMode: .greedy)).content
        } catch {
            Self.log.info("Falling back to the template: \(error.localizedDescription)")
            return nil
        }
    }
}
