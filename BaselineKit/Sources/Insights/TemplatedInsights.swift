import Forecasting

public enum TemplatedInsights {
    public static func insight(for facts: EventFacts) -> AnomalyInsight {
        AnomalyInsight(
            summary: summary(facts),
            likelyContributors: facts.context.isEmpty ? usualContributors(facts.kind) : Array(facts.context.prefix(3)),
            suggestion: suggestion(facts.kind))
    }

    private static func summary(_ facts: EventFacts) -> String {
        if facts.kind == .intradayStress {
            return "Your heart rate stayed above what your activity explains \(facts.when). This is an estimate from heart rate alone."
        }
        let above = facts.signals.filter(\.isAbove).map(\.name)
        let below = facts.signals.filter { !$0.isAbove }.map(\.name)
        func were(_ names: [String]) -> String { names.count == 1 ? "was" : "were" }
        let sentence: String
        switch (above.isEmpty, below.isEmpty) {
        case (false, true): sentence = "Your \(list(above)) \(were(above)) above your expected range \(facts.when)."
        case (true, false): sentence = "Your \(list(below)) \(were(below)) below your expected range \(facts.when)."
        case (false, false):
            sentence = "Your \(list(above)) \(were(above)) above your expected range and your \(list(below)) below it \(facts.when)."
        case (true, true): sentence = "Some of your signals were outside their expected range \(facts.when)."
        }
        switch facts.kind {
        case .illnessWarning: return sentence + " Several vitals moving together like this is worth paying attention to."
        case .sustainedStrain: return sentence + " Together that often means your body has not fully recovered."
        case .deviation, .intradayStress: return sentence
        }
    }

    private static func list(_ names: [String]) -> String {
        names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    private static func usualContributors(_ kind: AnomalyEvent.Kind) -> [String] {
        switch kind {
        case .illnessWarning: ["The early stages of feeling unwell", "Short or disrupted sleep", "Alcohol or a late, heavy meal"]
        case .sustainedStrain: ["Accumulated training load", "Too little recovery between hard days", "Short sleep"]
        case .deviation: ["A demanding day before", "A late night or disrupted sleep", "Alcohol or a late meal"]
        case .intradayStress: ["Mental or emotional pressure", "Caffeine", "Heat or too little to drink"]
        }
    }

    private static func suggestion(_ kind: AnomalyEvent.Kind) -> String {
        switch kind {
        case .illnessWarning: "Take it easy: prioritise rest, fluids and an early night, and leave hard training until your numbers settle."
        case .sustainedStrain: "Plan an easy or rest day and give yourself a full night of sleep before the next hard session."
        case .deviation: "Keep today light and see whether tonight brings you back into your range."
        case .intradayStress: "A few minutes of slow breathing or a short walk can help your heart rate settle."
        }
    }

    public static func advice(for facts: DayFacts) -> MetricAdvice {
        let meaning = facts.isBetter ? "That is better than usual for you." : "That is worse than usual for you."
        let context = facts.context.first.map { " \($0) may be part of it." } ?? ""
        return MetricAdvice(summary: "\(facts.reading). \(meaning)\(context)", action: action(for: facts))
    }

    static func action(for facts: DayFacts) -> String {
        switch (facts.metric, facts.isBetter) {
        case (.restingHeartRate, false), (.wristTemperature, false), (.respiratoryRate, false):
            "Keep today easy: skip hard training, drink plenty of water and get to bed early."
        case (.heartRateVariability, false): "Choose rest or light movement today, and protect your sleep tonight."
        case (.sleepDuration, false): "Go to bed earlier tonight, and skip caffeine after midday and alcohol in the evening."
        case (.steps, false), (.activeEnergy, false): "Fit in a walk today; even a short one after a meal helps."
        case (.vo2Max, false): "Add some steady cardio this week, such as brisk walks or easy runs."
        case (.restingHeartRate, true), (.heartRateVariability, true): "You are well recovered: a good day for a harder session if you planned one."
        case (.sleepDuration, true): "Extra sleep helps recovery. If you feel rested, keep your usual bedtime."
        case (.steps, true), (.activeEnergy, true): "A big day of activity: eat well, drink water and sleep well tonight."
        case (.vo2Max, true): "Your cardio fitness is up: keep the training that got you here."
        case (.wristTemperature, true), (.respiratoryRate, true): "Nothing to act on; keep your routine."
        }
    }

    public static func report(for facts: WeekFacts) -> WeeklyReport {
        let headline =
            facts.flagged.isEmpty ? "A steady week"
            : facts.flaggedKinds.contains(.illnessWarning) ? "A week that asked for rest"
            : "A mostly steady week, with \(facts.flagged.count == 1 ? "one stretch" : "a few stretches") flagged"
        var highlights = Array(facts.improvements.prefix(3))
        if highlights.count < 3, facts.isMostlyWithinRange, let withinRange = facts.withinRange {
            highlights.append(withinRange)
        }
        return WeeklyReport(
            headline: headline, highlights: highlights, concerns: Array((facts.flagged + facts.setbacks).prefix(3)),
            focusForNextWeek: focus(facts.flaggedKinds))
    }

    private static func focus(_ kinds: [AnomalyEvent.Kind]) -> String {
        if kinds.contains(.illnessWarning) { return "Ease back in: let your vitals settle before you train hard again." }
        if kinds.contains(.sustainedStrain) { return "Follow hard sessions with an easy day and a full night of sleep." }
        if kinds.contains(.intradayStress) { return "Try a short breathing break on busy afternoons." }
        if kinds.contains(.deviation) { return "Keep your bedtime regular and watch how your range responds." }
        return "Keep the routine that is working."
    }
}
