import FoundationModels
import Foundation
import Observation

/// The Ask chat. Each question goes to the model together with the user's data, summarised
/// by code: the summaries the question is about, then the last week at a glance.
///
/// The small on-device model was bad at picking a lookup tool: asked about one thing it
/// often looked up another, and the app then showed that lookup as the answer. Given the
/// data up front, it only has to read.
@MainActor @Observable
public final class AskSession {
    public struct Message: Identifiable, Sendable {
        public enum Role: Sendable { case user, assistant }

        public let id = UUID()
        public var role: Role
        public var text: String
        /// What the answer was written from, when the model wrote it.
        public var facts: String?
    }

    public private(set) var messages: [Message] = []
    public private(set) var isResponding = false

    private let snapshot: HealthSnapshot

    public init(snapshot: HealthSnapshot) {
        self.snapshot = snapshot
    }

    public var usesLanguageModel: Bool { SystemLanguageModel.default.isAvailable }

    public func ask(_ question: String) async {
        guard !isResponding else { return }
        let previous = lastExchange
        messages.append(Message(role: .user, text: question))
        messages.append(Message(role: .assistant, text: ""))
        let answer = messages.count - 1
        isResponding = true
        defer { isResponding = false }

        // A follow-up such as "what should I do about it?" is about what the last question was.
        var relevant = snapshot.summaries(about: question)
        if relevant.isEmpty, let previous { relevant = snapshot.summaries(about: previous.question) }
        let data = (relevant + snapshot.overview.filter { !relevant.contains($0) }).joined(separator: "\n")

        guard usesLanguageModel, let worded = await word(question, data: data, previous: previous) else {
            messages[answer].text = Self.fallback(relevant, overview: snapshot.overview)
            return
        }
        (messages[answer].text, messages[answer].facts) = (worded, data)
    }

    private var lastExchange: (question: String, answer: String)? {
        guard messages.count >= 2, messages[messages.count - 2].role == .user else { return nil }
        return (messages[messages.count - 2].text, messages[messages.count - 1].text)
    }

    /// The model's answer, if it passes `InsightGuard`; one retry is told what was wrong.
    private func word(_ question: String, data: String, previous: (question: String, answer: String)?) async -> String? {
        let earlier = previous.map { "Earlier question: \($0.question)\nYour earlier answer: \($0.answer)\n\n" } ?? ""
        let source = earlier + data
        let session = LanguageModelSession(instructions: Self.instructions)
        var prompt = "Their data:\n\(data)\n\n\(earlier)Question: \(question)"
        for _ in 0..<2 {
            // Greedy sampling: the same question about the same data gets the same answer.
            guard let text = try? await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy)).content else {
                return nil
            }
            guard let problem = Self.problem(with: text, source: source) else { return text }
            prompt = "That answer \(problem). Answer the question again, using only their data."
        }
        return nil
    }

    /// What `InsightGuard` objects to in `text`, worded for the model; nil if nothing.
    nonisolated static func problem(with text: String, source: String) -> String? {
        let numbers = InsightGuard.inventedNumbers(in: text, source: source)
        if !numbers.isEmpty { return "used numbers that are not in their data (\(numbers.joined(separator: ", ")))" }
        if !InsightGuard.diagnosisTerms(in: text).isEmpty { return "used medical language; you must not diagnose or mention medication" }
        let signals = InsightGuard.misplacedSignals(in: text, source: source)
        if !signals.isEmpty { return "put \(signals.joined(separator: " and ")) on the wrong side of the expected range" }
        if !InsightGuard.misplacedDays(in: text, source: source).isEmpty { return "named a day the data does not call last night or yesterday" }
        return nil
    }

    /// Without the model, or when it cannot word a checked answer: the summaries the question
    /// is about, or, for a question none fits, the last night and what was flagged.
    nonisolated static func fallback(_ relevant: [String], overview: [String]) -> String {
        relevant.isEmpty ? (overview.prefix(2) + [noTopic]).joined(separator: "\n\n") : relevant.joined(separator: "\n\n")
    }

    nonisolated static let noTopic = "Ask about your sleep, a metric such as heart rate or steps, your workouts, your logs or what was flagged."

    nonisolated static let instructions = """
        You are a calm health coach inside a wearable app, answering a person's question about their own data. Address them as "you".
        Answer exactly the question asked, in at most four short sentences, using only their data. Start with the direct answer.
        Never state a number, date or event that is not in their data. Name days and nights the way the data does.
        If the data does not answer the question, say so in one sentence and say what you can tell them instead.
        If what they ask about is outside its expected range, or they ask what to do, end with one specific thing to do today or tonight.
        \(InsightGenerator.safetyRules)
        """
}
