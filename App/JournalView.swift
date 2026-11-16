import Forecasting
import HealthData
import Insights
import Persistence
import SwiftUI

extension ManualLog.Kind {
    var symbol: String {
        switch self {
        case .alcohol: "wineglass.fill"
        case .caffeine: "cup.and.saucer.fill"
        case .illness: "facemask.fill"
        case .stress: "brain.head.profile"
        case .hardTraining: "figure.strengthtraining.traditional"
        case .travel: "airplane"
        }
    }
}

struct JournalView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Flagged") {
                if model.events.isEmpty {
                    Text(model.baseline.isEstablished
                        ? "Nothing has been flagged. Values outside your expected range will show up here."
                        : "Nothing is flagged while your baseline is still learning.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.events) { event in
                    NavigationLink(value: event) {
                        EventRow(event: event, when: model.snapshot.when(event))
                    }
                }
            }
            Section {
                let logs = model.store.logs.sorted { $0.date > $1.date }
                if logs.isEmpty {
                    Text("Log things like alcohol or a hard session with the + button. They help explain what gets flagged.")
                        .foregroundStyle(.secondary)
                }
                ForEach(logs) { log in
                    Label {
                        HStack {
                            Text(log.kind.title)
                            Spacer()
                            Text(log.date, format: .dateTime.weekday().day().month().hour().minute())
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: log.kind.symbol).foregroundStyle(Color.brand)
                    }
                }
                .onDelete { offsets in
                    offsets.map { logs[$0] }.forEach(model.store.remove)
                }
            } header: {
                Text("Your logs")
            } footer: {
                Text("Alcohol logs are also saved to Apple Health. Everything else stays in this app.")
            }
        }
        .navigationTitle("Journal")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Log", systemImage: "plus") {
                    ForEach(ManualLog.Kind.allCases) { kind in
                        Button(kind.title, systemImage: kind.symbol) { model.log(kind) }
                    }
                }
            }
        }
        .navigationDestination(for: AnomalyEvent.self) { EventDetailView(event: $0) }
        .navigationDestination(for: Metric.self) { MetricDetailView(metric: $0) }
    }
}

private struct EventRow: View {
    var event: AnomalyEvent
    var when: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.body.weight(.medium))
                Text(when.capitalizedFirst)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: event.symbol).foregroundStyle(event.tint)
        }
    }
}

struct EventDetailView: View {
    @Environment(AppModel.self) private var model
    var event: AnomalyEvent
    @State private var insight: Sourced<AnomalyInsight>?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card {
                    CardTitle(title: Self.severity(event.severity), symbol: event.symbol, tint: event.tint)
                    Text(event.title).font(.title2.bold())
                    Text(model.snapshot.when(event).capitalizedFirst)
                        .foregroundStyle(.secondary)
                    if event.suggestsClinician {
                        ClinicianNote()
                    }
                }
                Card {
                    CardTitle(title: "What moved", symbol: "chart.xyaxis.line", tint: .brand)
                    ForEach(event.signals, id: \.self) { signal in
                        SignalRow(signal: signal)
                    }
                }
                Card {
                    CardTitle(title: "What may be behind it", symbol: "sparkles", tint: .brand)
                    if let insight {
                        Text(insight.content.summary)
                        ForEach(insight.content.likelyContributors, id: \.self) { contributor in
                            Label(contributor.capitalizedFirst, systemImage: "circle.fill")
                                .font(.subheadline)
                                .labelStyle(BulletLabelStyle())
                        }
                        Label(insight.content.suggestion.capitalizedFirst, systemImage: "lightbulb.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        InsightSourceLabel(source: insight.source)
                    } else {
                        ProgressView()
                    }
                }
                FeedbackCard(event: event)
                Text("Wellness insights, not medical advice. Ranges and flags are estimates from your own history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color.page)
        .navigationTitle("Flagged")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: event) { insight = await model.explanation(of: event) }
    }

    private static func severity(_ severity: AnomalyEvent.Severity) -> String {
        switch severity {
        case .mild: "Mild"
        case .notable: "Notable"
        case .strong: "Strong"
        }
    }
}

private struct SignalRow: View {
    var signal: AnomalyEvent.Signal

    var body: some View {
        let tint = signal.metric?.tint ?? .red
        let row = HStack(spacing: 12) {
            Image(systemName: signal.metric?.symbol ?? "heart.fill")
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.title).font(.subheadline.weight(.medium))
                Text(signal.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            RangeBar(observed: signal.observed, expected: signal.expected, tint: tint)
                .frame(width: 64)
        }
        .contentShape(.rect)
        if let metric = signal.metric {
            NavigationLink(value: metric) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}

private struct FeedbackCard: View {
    @Environment(AppModel.self) private var model
    var event: AnomalyEvent

    var body: some View {
        let feedback = model.store.feedback(for: event)
        Card {
            CardTitle(title: "Does this make sense?", symbol: "hand.thumbsup.fill", tint: .brand)
            HStack {
                verdictButton("Makes sense", .makesSense, feedback)
                verdictButton("False alarm", .falseAlarm, feedback)
            }
            Text("What was going on?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(ManualLog.Kind.allCases) { kind in
                    let isOn = feedback.tags.contains(kind)
                    Button {
                        var changed = feedback
                        if isOn { changed.tags.remove(kind) } else { changed.tags.insert(kind) }
                        model.store.setFeedback(changed, for: event)
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                            .font(.footnote)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(isOn ? Color.brand : .secondary)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: feedback)
    }

    private func verdictButton(_ title: String, _ verdict: Feedback.Verdict, _ feedback: Feedback) -> some View {
        Button {
            var changed = feedback
            changed.verdict = feedback.verdict == verdict ? nil : verdict
            model.store.setFeedback(changed, for: event)
        } label: {
            Label(title, systemImage: verdict == .makesSense ? "hand.thumbsup" : "hand.thumbsdown")
                .symbolVariant(feedback.verdict == verdict ? .fill : .none)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(feedback.verdict == verdict ? Color.brand : .secondary)
    }
}
