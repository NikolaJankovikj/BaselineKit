import Forecasting
import HealthData
import SwiftUI

extension Color {
    /// Baseline's own accent: a deep teal.
    static let brand = Color(red: 0.07, green: 0.53, blue: 0.55)
    /// Values outside their expected range.
    static let outside = Color.orange

    static let page = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

extension Metric {
    var symbol: String {
        switch self {
        case .restingHeartRate: "heart.fill"
        case .heartRateVariability: "waveform.path.ecg"
        case .respiratoryRate: "lungs.fill"
        case .wristTemperature: "thermometer.medium"
        case .sleepDuration: "bed.double.fill"
        case .steps: "figure.walk"
        case .activeEnergy: "flame.fill"
        case .vo2Max: "figure.run"
        }
    }

    var tint: Color {
        switch self {
        case .restingHeartRate: .red
        case .heartRateVariability: .purple
        case .respiratoryRate: .cyan
        case .wristTemperature: .orange
        case .sleepDuration: .indigo
        case .steps: .green
        case .activeEnergy: .pink
        case .vo2Max: .teal
        }
    }

    /// Why the app reads this, in the words of the permission screen.
    var purpose: String {
        switch self {
        case .restingHeartRate: "Rises with strain, poor recovery and oncoming illness."
        case .heartRateVariability: "Drops when your body is under load; the core recovery signal."
        case .respiratoryRate: "Very stable from night to night, so a rise stands out."
        case .wristTemperature: "A raised sleeping temperature often comes with illness."
        case .sleepDuration: "Short nights explain many deviations the next day."
        case .steps: "Shows how active a day was."
        case .activeEnergy: "Your training load, which shapes the following night."
        case .vo2Max: "Your long-term cardio fitness trend."
        }
    }
}

extension AnomalyEvent {
    var symbol: String {
        switch kind {
        case .deviation: signals.first?.metric?.symbol ?? "exclamationmark.circle.fill"
        case .illnessWarning: "cross.case.fill"
        case .sustainedStrain: "battery.25percent"
        case .intradayStress: "bolt.heart.fill"
        }
    }

    var tint: Color {
        switch severity {
        case .mild: .yellow
        case .notable: .orange
        case .strong: .red
        }
    }
}

/// A rounded card on the page background.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: .rect(cornerRadius: 22))
    }
}

/// The small coloured heading of a card.
struct CardTitle: View {
    var title: String
    var symbol: String
    var tint: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
    }
}

/// Where a value sits relative to its expected range: the range is the tinted stretch in
/// the middle of the track.
struct RangeBar: View {
    var observed: Double
    var expected: Band
    var tint: Color

    var body: some View {
        GeometryReader { geometry in
            let lower = geometry.size.width * fraction(expected.lower)
            let upper = geometry.size.width * fraction(expected.upper)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.opacity(0.35))
                    .frame(width: upper - lower)
                    .offset(x: lower)
                Circle().fill(expected.contains(observed) ? tint : Color.outside)
                    .overlay(Circle().stroke(Color.card, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .offset(x: geometry.size.width * fraction(observed) - 6)
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    /// Position along the track, which spans the expected range plus two of its widths on
    /// either side.
    private func fraction(_ value: Double) -> CGFloat {
        let width = max(expected.upper - expected.lower, .leastNonzeroMagnitude)
        return min(max((value - (expected.lower - 2 * width)) / (5 * width), 0), 1)
    }
}

extension DayAssessment {
    /// "In range", "Above range" or "Below range"; nil without a value or a range.
    var rangeStatus: String? {
        guard let observed, let expected else { return nil }
        return expected.contains(observed) ? "In range" : observed > expected.upper ? "Above range" : "Below range"
    }

    var isOutside: Bool {
        guard let observed, let expected else { return false }
        return !expected.contains(observed)
    }
}

