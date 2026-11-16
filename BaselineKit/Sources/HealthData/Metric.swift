import Foundation

public enum Metric: String, CaseIterable, Codable, Sendable, Identifiable {
    case restingHeartRate
    case heartRateVariability
    case respiratoryRate
    case wristTemperature
    case sleepDuration
    case steps
    case activeEnergy
    case vo2Max

    public var id: Self { self }

    public var title: String {
        switch self {
        case .restingHeartRate: "Resting heart rate"
        case .heartRateVariability: "Heart rate variability"
        case .respiratoryRate: "Respiratory rate"
        case .wristTemperature: "Wrist temperature"
        case .sleepDuration: "Sleep"
        case .steps: "Steps"
        case .activeEnergy: "Active energy"
        case .vo2Max: "Cardio fitness"
        }
    }

    public var unit: String {
        switch self {
        case .restingHeartRate: "bpm"
        case .heartRateVariability: "ms"
        case .respiratoryRate: "br/min"
        case .wristTemperature: "°C"
        case .sleepDuration: "h"
        case .steps: "steps"
        case .activeEnergy: "kcal"
        case .vo2Max: "VO₂ max"
        }
    }

    private var fractionDigits: Int {
        switch self {
        case .restingHeartRate, .heartRateVariability, .steps, .activeEnergy: 0
        case .respiratoryRate, .sleepDuration, .vo2Max: 1
        case .wristTemperature: 2
        }
    }

    public var isOvernight: Bool {
        switch self {
        case .restingHeartRate, .heartRateVariability, .respiratoryRate, .wristTemperature, .sleepDuration: true
        case .steps, .activeEnergy, .vo2Max: false
        }
    }

    public var accumulatesOverDay: Bool { self == .steps || self == .activeEnergy }

    public var concerningDirection: Direction? {
        switch self {
        case .restingHeartRate, .respiratoryRate, .wristTemperature: .above
        case .heartRateVariability, .sleepDuration: .below
        case .steps, .activeEnergy, .vo2Max: nil
        }
    }

    public func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    public func formattedWithUnit(_ value: Double) -> String {
        "\(formatted(value)) \(unit)"
    }
}

public enum Direction: String, Codable, Sendable {
    case above, below

    public var sign: Double { self == .above ? 1 : -1 }
}
