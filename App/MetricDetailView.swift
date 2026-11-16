import Charts
import Forecasting
import HealthData
import Insights
import SwiftUI

/// One metric over time, against the range Chronos-2 expected for each day and the range
/// it expects for the coming week.
struct MetricDetailView: View {
    /// One value per day makes a single-day view pointless, so the spans start at a week.
    enum Span: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90
        case halfYear = 180

        var id: Self { self }

        var label: String {
            switch self {
            case .week: "W"
            case .month: "M"
            case .quarter: "3M"
            case .halfYear: "6M"
            }
        }
    }

    @Environment(AppModel.self) private var model
    var metric: Metric
    @State var span = Span.month
    @State var comparesSimple = false
    @State private var selection: Date?

    private var assessment: MetricAssessment? { model.metrics[metric] }
    private var history: ArraySlice<DayAssessment> { (assessment?.days ?? []).suffix(span.rawValue) }

    /// The day under the finger, or the latest day that has a value.
    private var focused: DayAssessment? {
        if let selection {
            let day = Calendar.current.startOfDay(for: selection)
            return (history + (assessment?.outlook ?? [])).first { $0.day == day }
        }
        return history.last { $0.observed != nil }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Span", selection: $span) {
                    ForEach(Span.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Card {
                    FocusedDay(metric: metric, day: focused)
                    chart
                    legend
                }
                if let day = focused, let advice = model.advice(for: metric, on: day) {
                    AdviceCard(advice: advice)
                        .task(id: day.day) {
                            // Waits for the finger to rest, so scrubbing does not start a generation per day.
                            try? await Task.sleep(for: .milliseconds(400))
                            guard !Task.isCancelled else { return }
                            await model.generateAdvice(for: metric, on: day)
                        }
                }
                if let day = focused, let event = model.events(on: day.day, involving: metric).first {
                    NavigationLink(value: event) {
                        Card {
                            HStack {
                                CardTitle(title: event.title, symbol: event.symbol, tint: event.tint)
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            Text("This day is part of a flagged event. Tap for what moved and why.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Card {
                    Toggle("Compare with a simple average", isOn: $comparesSimple)
                    Text("The grey lines are the range a plain \(SimpleAverage.window)-day average would expect. The shaded range comes from Chronos-2, a forecasting model that runs on this device. Seeing both keeps the model honest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Card {
                    CardTitle(title: "About \(metric.title.lowercased())", symbol: metric.symbol, tint: metric.tint)
                    Text(metric.purpose)
                    if let tomorrow = assessment?.outlook.first?.expected {
                        Text("Expected tomorrow: \(metric.formatted(tomorrow.lower))–\(metric.formatted(tomorrow.upper)) \(metric.unit)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color.page)
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chart: some View {
        Chart {
            ForEach(history) { day in
                marks(for: day, isOutlook: false)
            }
            ForEach(assessment?.outlook ?? []) { day in
                marks(for: day, isOutlook: true)
            }
            if let selection {
                RuleMark(x: .value("Selected", Calendar.current.startOfDay(for: selection), unit: .day))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartXSelection(value: $selection)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 240)
        .overlay(alignment: .topTrailing) {
            if model.isExtending, span == .halfYear {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ChartContentBuilder
    private func marks(for day: DayAssessment, isOutlook: Bool) -> some ChartContent {
        let x = PlottableValue.value("Day", day.day, unit: .day)
        if let expected = day.expected {
            AreaMark(x: x, yStart: .value("Low", expected.lower), yEnd: .value("High", expected.upper), series: .value("Range", isOutlook ? "outlook" : "expected"))
                .foregroundStyle(metric.tint.opacity(isOutlook ? 0.1 : 0.22))
            LineMark(x: x, y: .value("Median", expected.median), series: .value("Line", isOutlook ? "outlook median" : "median"))
                .foregroundStyle(metric.tint.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        if comparesSimple, let simple = day.simple {
            LineMark(x: x, y: .value("Simple low", simple.lower), series: .value("Line", "simple low"))
                .foregroundStyle(.gray)
                .lineStyle(StrokeStyle(lineWidth: 1))
            LineMark(x: x, y: .value("Simple high", simple.upper), series: .value("Line", "simple high"))
                .foregroundStyle(.gray)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        if let observed = day.observed {
            LineMark(x: x, y: .value("Value", observed), series: .value("Line", "value"))
                .foregroundStyle(metric.tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            PointMark(x: x, y: .value("Value", observed))
                .foregroundStyle(day.isOutside ? Color.outside : metric.tint)
                .symbolSize(pointSize(day))
        }
    }

    /// A calibrated range leaves one value in five outside, so only clear deviations get a
    /// large dot, and the longer spans drop the small ones.
    private func pointSize(_ day: DayAssessment) -> CGFloat {
        if abs(day.residual ?? 0) >= DailyForecastEngine.deviationThreshold { return 70 }
        switch span {
        case .week, .month: return day.isOutside ? 30 : 16
        case .quarter: return day.isOutside ? 14 : 0
        case .halfYear: return 0
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            Label("Expected range", systemImage: "square.fill").foregroundStyle(metric.tint.opacity(0.5))
            Label("Clearly outside", systemImage: "circle.fill").foregroundStyle(Color.outside)
            Label("Next 7 days", systemImage: "square.fill").foregroundStyle(metric.tint.opacity(0.25))
        }
        .font(.caption2)
        .labelStyle(.titleAndIcon)
    }
}

/// What an out-of-range value means and what to do about it, right below the chart.
private struct AdviceCard: View {
    var advice: Sourced<MetricAdvice>

    var body: some View {
        Card {
            CardTitle(title: "What to do", symbol: "lightbulb.fill", tint: .brand)
            Text(advice.content.action).font(.headline)
            Text(advice.content.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            InsightSourceLabel(source: advice.source)
        }
        .animation(.default, value: advice)
    }
}

/// The value, expected range and deviation of one day, above the chart.
private struct FocusedDay: View {
    var metric: Metric
    var day: DayAssessment?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(day?.observed.map(metric.formatted) ?? "–")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                Text(metric.unit).foregroundStyle(.secondary)
                Spacer()
                if let day, let status = day.rangeStatus {
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((day.isOutside ? Color.outside : metric.tint).opacity(0.18), in: .capsule)
                }
            }
            if let day {
                Text(day.day, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let expected = day.expected {
                    Text(detail(day, expected))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func detail(_ day: DayAssessment, _ expected: Band) -> String {
        var text = "Expected \(metric.formatted(expected.lower))–\(metric.formatted(expected.upper))"
        if let residual = day.residual {
            // Rounded first, and plus zero, so that -0.04 does not show as "-0.0".
            let rounded = (residual * 10).rounded() / 10 + 0
            text += " · \(rounded.formatted(.number.precision(.fractionLength(1)).sign(strategy: .always(includingZero: false))))σ"
        }
        if day.horizon > 1, day.isOutside {
            text += " · day \(day.horizon) outside the range from before"
        }
        return text
    }
}
