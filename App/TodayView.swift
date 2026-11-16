import Charts
import Forecasting
import HealthData
import Insights
import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showsSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if case .learning(let nights) = model.baseline {
                    BaselineBanner(nights: nights)
                }
                ReadinessCard()
                if let event = model.currentEvent {
                    InsightCard(event: event)
                }
                StressCard()
                MetricGrid()
                Text("Wellness insights, not medical advice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color.page)
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack { SettingsView() }
        }
        .refreshable { await model.refresh() }
        .navigationDestination(for: Metric.self) { MetricDetailView(metric: $0) }
        .navigationDestination(for: AnomalyEvent.self) { EventDetailView(event: $0) }
    }
}

private struct BaselineBanner: View {
    var nights: Int

    var body: some View {
        Card {
            CardTitle(title: "Learning your baseline", symbol: "chart.line.uptrend.xyaxis", tint: .brand)
            ProgressView(value: Double(nights), total: Double(BaselineState.nightsNeeded))
                .tint(.brand)
            Text("\(nights) of \(BaselineState.nightsNeeded) nights. Expected ranges are provisional until then, and nothing is flagged.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReadinessCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            CardTitle(title: "Readiness", symbol: "gauge.with.needle.fill", tint: .brand)
            if let readiness = model.readiness {
                HStack(spacing: 16) {
                    ReadinessRing(score: readiness.score)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.label(readiness.score))
                            .font(.title2.bold())
                        Text(Self.explanation(readiness))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                ForEach(readiness.contributions) { contribution in
                    NavigationLink(value: contribution.metric) {
                        ContributionRow(contribution: contribution)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No overnight data yet. Wear your watch to sleep and your readiness appears here in the morning.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func label(_ score: Int) -> String {
        switch score {
        case 80...: "Ready"
        case 60..<80: "Steady"
        case 40..<60: "Go easy"
        default: "Recover"
        }
    }

    private static func explanation(_ readiness: Readiness) -> String {
        let outside = readiness.contributions.filter { !$0.expected.contains($0.observed) && $0.concern > 0 }
        guard !outside.isEmpty else { return "Last night's signals are within or better than your expected ranges." }
        let names = outside.map { $0.metric.title.lowercased() }.formatted(.list(type: .and))
        return "Outside your expected range last night: \(names)."
    }
}

private struct ReadinessRing: View {
    var score: Int

    private var tint: Color {
        score >= 75 ? .green : score >= 50 ? .yellow : .orange
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 10)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(score, format: .number)
                .font(.system(.title, design: .rounded).bold())
        }
        .frame(width: 84, height: 84)
        .accessibilityElement()
        .accessibilityLabel("Readiness \(score) of 100")
    }
}

private struct ContributionRow: View {
    var contribution: Readiness.Contribution

    var body: some View {
        let metric = contribution.metric
        HStack(spacing: 12) {
            Image(systemName: metric.symbol)
                .foregroundStyle(metric.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title).font(.subheadline.weight(.medium))
                Text("\(metric.formattedWithUnit(contribution.observed)) · expected \(metric.formatted(contribution.expected.lower))–\(metric.formatted(contribution.expected.upper))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            RangeBar(observed: contribution.observed, expected: contribution.expected, tint: metric.tint)
                .frame(width: 64)
        }
        .contentShape(.rect)
    }
}

private struct InsightCard: View {
    @Environment(AppModel.self) private var model
    var event: AnomalyEvent
    @State private var insight: Sourced<AnomalyInsight>?

    var body: some View {
        NavigationLink(value: event) {
            Card {
                HStack {
                    CardTitle(title: event.title, symbol: event.symbol, tint: event.tint)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                Text(model.snapshot.when(event).capitalizedFirst)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let insight {
                    Text(insight.content.summary)
                    Label(insight.content.suggestion.capitalizedFirst, systemImage: "lightbulb.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    InsightSourceLabel(source: insight.source)
                } else {
                    ProgressView()
                }
                if event.suggestsClinician {
                    ClinicianNote()
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: event) { insight = await model.explanation(of: event) }
    }
}

struct ClinicianNote: View {
    var body: some View {
        Label("These signals have persisted or are well outside your range. If you feel unwell, or this continues, consider talking to a clinician.", systemImage: "stethoscope")
            .font(.footnote)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.12), in: .rect(cornerRadius: 12))
    }
}

struct InsightSourceLabel: View {
    var source: InsightSource

    var body: some View {
        Label(
            source == .appleIntelligence ? "Explained on this device by Apple Intelligence" : "Summary written from your data",
            systemImage: source == .appleIntelligence ? "sparkles" : "text.alignleft"
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private struct StressCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack {
                CardTitle(title: "Stress", symbol: "bolt.heart.fill", tint: .purple)
                Spacer()
                Text("Estimate")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: .capsule)
            }
            if let stress = model.stress, !stress.points.isEmpty {
                Text(Self.label(stress.level))
                    .font(.title2.bold())
                Chart(stress.points) { point in
                    if let score = point.score {
                        RectangleMark(
                            xStart: .value("From", point.time),
                            xEnd: .value("To", point.time.addingTimeInterval(IntradayHistory.binSeconds)),
                            yStart: .value("Expected", 0),
                            yEnd: .value("Above expected", min(max(score, 0.25), 6))
                        )
                        .foregroundStyle(score >= 2 ? Color.outside : Color.purple.opacity(0.4))
                    }
                }
                .chartXScale(domain: Self.span(of: stress))
                .chartYScale(domain: 0...6)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: 72)
                // The level is said in words above; 144 bars are noise to VoiceOver.
                .accessibilityHidden(true)
                Text("Heart rate above what your activity explains over the last 12 hours. Sleep, workouts and movement are left out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.isExtending {
                ProgressView()
            } else {
                Text("No recent heart rate data.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// All scored hours, so the hours asleep show as the gap they are.
    private static func span(of stress: StressAssessment) -> ClosedRange<Date> {
        let start = stress.points.first?.time ?? .now
        let end = (stress.points.last?.time ?? start).addingTimeInterval(IntradayHistory.binSeconds)
        return start...end
    }

    private static func label(_ level: StressAssessment.Level?) -> String {
        switch level {
        case .low: "Low"
        case .moderate: "Moderate"
        case .high: "High"
        case nil: "No recent reading"
        }
    }
}

private struct MetricGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            ForEach(Metric.allCases) { metric in
                if let assessment = model.metrics[metric] {
                    NavigationLink(value: metric) {
                        MetricTile(assessment: assessment)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct MetricTile: View {
    var assessment: MetricAssessment

    var body: some View {
        let metric = assessment.metric
        let latest = assessment.days.last { $0.observed != nil }
        VStack(alignment: .leading, spacing: 6) {
            Label(metric.title, systemImage: metric.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(metric.tint)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text((assessment.runningTotal ?? latest?.observed).map(metric.formatted) ?? "–")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text(metric.unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Sparkline(days: assessment.days.suffix(14), tint: metric.tint)
            Text(status(latest))
                .font(.caption2)
                .foregroundStyle(assessment.runningTotal == nil && latest?.isOutside == true ? Color.outside : .secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: .rect(cornerRadius: 18))
    }

    private func status(_ latest: DayAssessment?) -> String {
        let metric = assessment.metric
        if assessment.runningTotal != nil, let expected = assessment.days.last?.expected {
            return "Expected \(metric.formatted(expected.lower))–\(metric.formatted(expected.upper)) today"
        }
        guard let latest, let status = latest.rangeStatus else { return "No expected range yet" }
        return latest.day == assessment.days.last?.day ? status : "\(status) · \(latest.day.formatted(.dateTime.weekday().day()))"
    }
}

private struct Sparkline: View {
    var days: ArraySlice<DayAssessment>
    var tint: Color

    var body: some View {
        Chart(days) { day in
            if let expected = day.expected {
                AreaMark(x: .value("Day", day.day), yStart: .value("Low", expected.lower), yEnd: .value("High", expected.upper))
                    .foregroundStyle(tint.opacity(0.18))
                    .interpolationMethod(.monotone)
            }
            if let observed = day.observed {
                LineMark(x: .value("Day", day.day), y: .value("Value", observed))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                if day.isOutside {
                    PointMark(x: .value("Day", day.day), y: .value("Value", observed))
                        .foregroundStyle(Color.outside)
                        .symbolSize(28)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 40)
        .accessibilityHidden(true)
    }
}
