import FoundationModels
import Foundation
import Observation

/// The small on-device model skips the tools for some questions and picks the wrong one for
/// others, so the summaries the question's words point to are always looked up as well.
@MainActor @Observable
public final class AskSession {
    public struct Message: Identifiable, Sendable {
        public enum Role: Sendable { case user, assistant }

        public let id = UUID()
        public var role: Role
        public var text: String
        public var lookups: [Lookup] = []
        /// What the agents are doing while there is no text yet.
        public var activity: String?
    }

    public private(set) var messages: [Message] = []
    public private(set) var isResponding = false

    private let snapshot: HealthSnapshot

    public init(snapshot: HealthSnapshot) {
        self.snapshot = snapshot
    }

    public var usesLanguageModel: Bool { SystemLanguageModel.default.isAvailable }

    /// Loads the model before the first question, which otherwise waits for it.
    public func prewarm() {
        guard usesLanguageModel else { return }
        LanguageModelSession(instructions: Self.triageInstructions).prewarm()
    }

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

        guard usesLanguageModel else {
            messages[answer].text = Self.isGreeting(question) ? Self.greetingWithoutModel : Self.fallback(relevant, overview: snapshot.overview)
            return
        }
        messages[answer].activity = "Reading your message"
        defer { messages[answer].activity = nil }
        // "Thanks" after an answer was sorted as a follow-up and got the answer again. Small
        // talk is plain from its words, so it skips triage; the model still writes the reply.
        let kind = Self.isGreeting(question) ? .greeting : await Self.triage(question, previous: previous)
        switch kind {
        case .greeting, .offTopic: await reply(to: question, into: answer)
        case .data:
            messages[answer].activity = "Looking through your data"
            await research(question, previous: previous, relevant: relevant, into: answer)
            messages[answer].activity = "Writing your answer"
            await write(question, previous: previous, into: answer)
        }
    }

    private var lastExchange: (question: String, answer: String)? {
        guard messages.count >= 2, messages[messages.count - 2].role == .user else { return nil }
        return (messages[messages.count - 2].text, messages[messages.count - 1].text)
    }

    @Generable enum Kind { case greeting, data, offTopic }

    @Generable struct Triage {
        @Guide(description: """
            greeting: hello, thanks, okay, great, goodbye or other small talk with no question in it, also right after an answer. \
            data: anything about their health, body, sleep, energy, activity, training, how they are doing or what to do today, \
            or a follow-up question about the earlier one. \
            offTopic: anything else, such as general knowledge, coding, writing, maths, news or other people.
            """)
        var kind: Kind
    }

    nonisolated static func triage(_ question: String, previous: (question: String, answer: String)?) async -> Kind {
        let session = LanguageModelSession(instructions: triageInstructions)
        // Context goes after the message: put first, it made the model sort "thanks" as a question.
        let earlier = previous.map { "\n(Their previous question, for context only: \($0.question))" } ?? ""
        let triage = try? await session.respond(
            to: "Message to sort: \(question)\(earlier)", generating: Triage.self, options: GenerationOptions(samplingMode: .greedy))
        return triage?.content.kind ?? .data
    }

    nonisolated static let triageInstructions = """
        You sort the messages sent to the chat in Baseline, a wellness app that reads a person's wearable data: \
        sleep, heart rate, heart rate variability, breathing rate, wrist temperature, steps, active energy, cardio fitness, \
        workouts, what they logged and what the app flagged as unusual.
        """

    /// The model's reply to a greeting or to a message this app does not cover. Neither has
    /// data to check against, so it is shown as written.
    private func reply(to message: String, into index: Int) async {
        let session = LanguageModelSession(instructions: Self.replyInstructions)
        _ = await stream("Message: \(message)", in: session, into: index)
    }

    nonisolated static let replyInstructions = """
        You are the coach in the chat of Baseline, a wellness app. You only talk about the person's own wearable data, \
        such as their sleep, heart and activity. Address them as "you" and keep to one or two short sentences.
        If the message is a greeting, thanks or small talk, reply in kind and ask what they would like to know about their data.
        Otherwise the message is about something else: do not answer it or attempt it, not even in part. Say kindly that this \
        is not something this app helps with and that you are not a general assistant, and say what you can help with instead.
        """

    nonisolated static let greetingWithoutModel = "Hi! \(noTopic)"

    nonisolated static func isGreeting(_ message: String) -> Bool {
        let words = message.lowercased().split { !$0.isLetter }.map(String.init)
        return !words.isEmpty && words.count <= 4 && words.allSatisfy(greetingWords.contains)
    }

    private nonisolated static let greetingWords: Set<String> = [
        "hi", "hello", "hey", "hiya", "yo", "thanks", "thank", "thx", "ty", "you", "so", "much", "a", "lot", "bye", "good", "morning",
        "afternoon", "evening", "night", "there", "ok", "okay", "great", "cool", "nice", "cheers", "awesome", "perfect", "got", "it",
    ]

    private func research(_ question: String, previous: (question: String, answer: String)?, relevant: [String], into index: Int) async {
        let tools = Self.tools(for: snapshot) { [weak self] in self?.record($0, into: index) }
        let session = LanguageModelSession(tools: tools, instructions: Self.researchInstructions)
        let earlier = previous.map { "Earlier question: \($0.question)\n" } ?? ""
        // The reply is not used: what matters is which tools it called.
        _ = try? await session.respond(to: "\(earlier)Question: \(question)", options: GenerationOptions(samplingMode: .greedy))

        for summary in relevant { record(Lookup(title: "Matched to your question", result: summary), into: index) }
        guard messages[index].lookups.isEmpty else { return }
        for summary in snapshot.overview { record(Lookup(title: "Your last week at a glance", result: summary), into: index) }
    }

    private func record(_ lookup: Lookup, into index: Int) {
        // The model sometimes repeats a call, and the keyword match may find what it already looked up.
        guard !messages[index].lookups.contains(where: { $0.result == lookup.result }) else { return }
        messages[index].lookups.append(lookup)
    }

    nonisolated static let researchInstructions = """
        You look up a person's wearable data so that someone else can answer their question. Call the tools the question needs, \
        and only those. For what to do today or how they are doing, look up last night's sleep, what was flagged in the last 7 days \
        and their workouts in the last 7 days. When you have looked everything up, reply "done".
        """

    private func write(_ question: String, previous: (question: String, answer: String)?, into index: Int) async {
        let lookups = messages[index].lookups
        let data = lookups.map(\.result).joined(separator: "\n")
        let earlier = previous.map { "Earlier question: \($0.question)\nYour earlier answer: \($0.answer)\n\n" } ?? ""
        let source = earlier + data
        let session = LanguageModelSession(instructions: Self.writerInstructions)
        var prompt = "What was looked up in their data:\n\(data)\n\n\(earlier)Question: \(question)"
        for _ in 0..<2 {
            guard await stream(prompt, in: session, into: index) else { break }
            guard let problem = Self.problem(with: messages[index].text, source: source) else { return }
            messages[index].text = ""
            messages[index].activity = "Checking the wording again"
            prompt = "That answer \(problem). Answer the question again, using only their data."
        }
        messages[index].text = lookups.map(\.result).joined(separator: "\n\n")
    }

    private func stream(_ prompt: String, in session: LanguageModelSession, into index: Int) async -> Bool {
        do {
            // Greedy sampling: the same message about the same data gets the same answer.
            for try await partial in session.streamResponse(to: prompt, options: GenerationOptions(samplingMode: .greedy)) {
                messages[index].text = partial.content
            }
            return true
        } catch {
            return false
        }
    }

    nonisolated static let writerInstructions = """
        You are the coach in Baseline, a wellness app, answering a person's question about their own wearable data. Address them as "you".
        Use only what was looked up in their data. Never state a number, date or event that is not in it. Name days and nights the way it does.
        Answer in three to five short sentences of everyday words: first the direct answer, then what it means for them and why.
        Leave out expected ranges unless they ask for detail; then give the numbers and ranges.
        When they ask what to do, give one concrete suggestion for what is outside its expected range. \
        Only if nothing is outside it, say they can go about their usual day. Do not give advice they did not ask for.
        Never repeat your earlier answer: answer only the new question.
        If the data does not answer the question, say so and say what you can tell them instead.
        You may put the key point in **bold**. No headings.
        You are not a clinician: never name a disease or condition, never diagnose, never mention medication, \
        and do not tell them to see a doctor; the app decides that separately.
        """

    nonisolated static func problem(with text: String, source: String) -> String? {
        let numbers = InsightGuard.inventedNumbers(in: text, source: source)
        if !numbers.isEmpty { return "used numbers that are not in their data (\(numbers.joined(separator: ", ")))" }
        if !InsightGuard.diagnosisTerms(in: text).isEmpty { return "used medical language; you must not diagnose or mention medication" }
        let signals = InsightGuard.misplacedSignals(in: text, source: source)
        if !signals.isEmpty { return "put \(signals.joined(separator: " and ")) on the wrong side of the expected range" }
        if !InsightGuard.misplacedDays(in: text, source: source).isEmpty { return "named a day the data does not call last night or yesterday" }
        return nil
    }

    nonisolated static func fallback(_ relevant: [String], overview: [String]) -> String {
        relevant.isEmpty ? (overview.prefix(2) + [noTopic]).joined(separator: "\n\n") : relevant.joined(separator: "\n\n")
    }

    nonisolated static let noTopic = "Ask about your sleep, a metric such as heart rate or steps, your workouts, your logs or what was flagged."
}
