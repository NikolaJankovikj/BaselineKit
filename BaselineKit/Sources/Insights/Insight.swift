import FoundationModels

@Generable(description: "A calm, plain-language explanation of one flagged event in a person's wearable data")
public struct AnomalyInsight: Codable, Sendable, Equatable {
    @Guide(description: "What happened, in one or two sentences, using only the given facts")
    public var summary: String
    @Guide(description: "Short phrases naming everyday factors that could contribute; no diseases or conditions", .count(1...3))
    public var likelyContributors: [String]
    @Guide(description: "One general wellness suggestion: rest, sleep, hydration, lighter training or slow breathing")
    public var suggestion: String

    public init(summary: String, likelyContributors: [String], suggestion: String) {
        self.summary = summary
        self.likelyContributors = likelyContributors
        self.suggestion = suggestion
    }

    var allText: String { ([summary, suggestion] + likelyContributors).joined(separator: "\n") }
}

@Generable(description: "What one out-of-range reading in a person's wearable data means, and what to do about it")
public struct MetricAdvice: Codable, Sendable, Equatable {
    @Guide(description: "One sentence on what the reading means, linking it to the known context if there is any")
    public var summary: String
    @Guide(description: "One specific thing to do today or tonight; a general wellness action")
    public var action: String

    public init(summary: String, action: String) {
        self.summary = summary
        self.action = action
    }

    var allText: String { "\(summary)\n\(action)" }
}

public struct WeeklyReport: Codable, Sendable, Equatable {
    public var headline: String
    public var highlights: [String]
    public var concerns: [String]
    public var focusForNextWeek: String

    public init(headline: String, highlights: [String], concerns: [String], focusForNextWeek: String) {
        self.headline = headline
        self.highlights = highlights
        self.concerns = concerns
        self.focusForNextWeek = focusForNextWeek
    }

    var allText: String { ([headline, focusForNextWeek] + highlights + concerns).joined(separator: "\n") }
}

public enum InsightSource: String, Codable, Sendable {
    case appleIntelligence
    case template
}

public struct Sourced<Content: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var content: Content
    public var source: InsightSource

    public init(_ content: Content, source: InsightSource) {
        self.content = content
        self.source = source
    }
}

/// The two parts of the weekly report that are wording, not fact. The model writes these;
/// what went well and what was flagged are lists of facts and stay as code wrote them. Left
/// to choose, the model praised metrics that had got worse and dropped the main event.
@Generable(description: "The wording of a short weekly summary of a person's wearable data")
struct WeekWording {
    @Guide(description: "A title for the week in a few words, such as 'A steady week'; not the dates")
    var headline: String
    @Guide(description: "One general wellness focus for the coming week, in one sentence")
    var focusForNextWeek: String
}
