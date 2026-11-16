import Foundation

/// Checks on text the language model wrote, before the app shows it. The model only
/// explains; if it adds a number or drifts toward a diagnosis, the template is used instead.
public enum InsightGuard {
    /// Stems that would make a wellness note read as a diagnosis or as medication advice.
    static let diagnosisTerms = [
        "diagnos", "disease", "disorder", "syndrome", "infection", "infected", "virus", "viral", "bacteri",
        "covid", "influenza", "the flu", "fever", "pneumonia", "arrhythmia", "fibrillation", "hypertension",
        "apnea", "diabet", "cancer", "heart attack", "stroke", "medication", "medicine", "antibiotic",
        "ibuprofen", "paracetamol", "aspirin", "prescri", "dosage", "you have a ", "you are suffering",
    ]

    /// Numbers in `text` that do not occur in `source`, compared by value: "7" is "7,0".
    public static func inventedNumbers(in text: String, source: String) -> [String] {
        let known = Set(numbers(in: source).map(\.value))
        return numbers(in: text).filter { !known.contains($0.value) }.map(\.text)
    }

    /// "last night" or "yesterday" in `text` when `source` does not say it. The model may
    /// repeat these, not work them out: it used them for nights and days further back.
    public static func misplacedDays(in text: String, source: String) -> [String] {
        unsupported(["last night", "yesterday"], in: text, source: source)
    }

    /// The `phrases` that `text` uses and `source` does not.
    static func unsupported(_ phrases: [String], in text: String, source: String) -> [String] {
        phrases.filter { text.localizedCaseInsensitiveContains($0) && !source.localizedCaseInsensitiveContains($0) }
    }

    public static func diagnosisTerms(in text: String) -> [String] {
        let lowered = text.lowercased()
        return diagnosisTerms.filter(lowered.contains)
    }

    /// Signals that `text` puts on the wrong side of their range.
    ///
    /// The source says "resting heart rate 64 bpm, above the expected 55–59". The model
    /// tends to lump signals together ("heart rate and its variability were both elevated"),
    /// so a sentence that only speaks of one direction may not name a signal that the
    /// source has on the other side.
    public static func misplacedSignals(in text: String, source: String) -> [String] {
        var sides: [String: Set<String>] = [:]
        for match in source.lowercased().matches(of: signalSide) {
            sides[String(match.output.1), default: []].insert(String(match.output.2))
        }
        var misplaced: [String] = []
        // "breathing rate" is the model's own word for it.
        for sentence in text.lowercased().replacing("breathing rate", with: "respiratory rate").split(whereSeparator: { ".;!?\n".contains($0) }) {
            let words = Set(sentence.split { !$0.isLetter }.map(String.init))
            let saysAbove = !words.isDisjoint(with: aboveWords)
            let saysBelow = !words.isDisjoint(with: belowWords)
            guard saysAbove != saysBelow else { continue }
            let wrongSide = saysAbove ? "below" : "above"
            misplaced += sides.filter { sentence.contains($0.key) && $0.value == [wrongSide] }.keys
        }
        return misplaced.sorted()
    }

    /// Whether `text` only uses numbers and day words from `source`, keeps every signal on
    /// the side of its range that `source` gives it, and stays clear of diagnosis language.
    public static func accepts(_ text: String, source: String) -> Bool {
        inventedNumbers(in: text, source: source).isEmpty && diagnosisTerms(in: text).isEmpty
            && misplacedSignals(in: text, source: source).isEmpty && misplacedDays(in: text, source: source).isEmpty
    }

    /// "<signal> <value>, above the expected", as the summaries and facts word a reading.
    /// Longer names come first so that "heart rate" does not claim the other two.
    nonisolated(unsafe) private static let signalSide =
        /(resting heart rate|heart rate variability|respiratory rate|wrist temperature|active energy|cardio fitness|heart rate|sleep|steps)\b[^\n;]*?, (above|below|within) the expected/
    private static let aboveWords: Set<String> = ["above", "higher", "high", "elevated", "raised", "increased"]
    private static let belowWords: Set<String> = ["below", "lower", "low", "reduced", "decreased"]

    private static func numbers(in text: String) -> [(text: String, value: Double)] {
        text.matches(of: /\d+(?:[.,]\d+)?/).compactMap { match in
            Double(match.output.replacing(",", with: ".")).map { (String(match.output), $0) }
        }
    }
}
