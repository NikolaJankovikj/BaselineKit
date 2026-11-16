import Forecasting
import FoundationModels
import HealthData
import Insights
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NotificationPreference.anomalies.rawValue) private var notifiesAnomalies = false
    @AppStorage(NotificationPreference.morningReadiness.rawValue) private var notifiesReadiness = false
    @AppStorage(NotificationPreference.weeklyReport.rawValue) private var notifiesReport = false
    @State private var confirmsErase = false
    @State private var pickedSource: AppModel.DataSource?
    @State private var debugStatus: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Source", selection: sourceBinding) {
                    Text("Apple Health").tag(AppModel.DataSource.health)
                    Text("Demo data").tag(AppModel.DataSource.demo)
                }
                if model.dataSource == .demo {
                    Picker("Scenario", selection: $model.scenario) {
                        Text("Sick week").tag(SyntheticProvider.Scenario.sickWeek)
                        Text("Healthy").tag(SyntheticProvider.Scenario.healthy)
                        Text("First days").tag(SyntheticProvider.Scenario.coldStart)
                    }
                }
                LabeledContent("Baseline", value: baselineText)
            } header: {
                Text("Data")
            } footer: {
                Text("Alerts start after \(BaselineState.nightsNeeded) nights of data. Until then ranges are provisional and nothing is flagged.")
            }

            Section {
                Toggle("Anomaly alerts", isOn: $notifiesAnomalies)
                Toggle("Morning readiness", isOn: $notifiesReadiness)
                Toggle("Weekly report", isOn: $notifiesReport)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Sent from this device after the nightly update. Nothing is sent before your baseline is established.")
            }

            Section {
                Picker("Forecasting", selection: $model.forecastMode) {
                    Text("Per metric").tag(ForecastMode.univariate)
                    Text("Joint").tag(ForecastMode.joint)
                }
                LabeledContent("Apple Intelligence", value: intelligenceText)
                NavigationLink("Model check") { EvaluationView() }
            } header: {
                Text("Model")
            } footer: {
                Text("Joint forecasting gives Chronos-2 all metrics as one group, with weekends and your logs as context. Whether that helps on your data is what the model check measures.")
            }

            Section {
                ShareLink("Export daily values (CSV)", item: model.csvExport, preview: SharePreview("Baseline daily values"))
                Button("Erase all Baseline data", role: .destructive) { confirmsErase = true }
            } header: {
                Text("Your data")
            } footer: {
                Text("Baseline reads Apple Health on this device and stores its journal and forecasts only here. It has no account, no server and no analytics.")
            }

            #if DEBUG
                Section {
                    Button("Write demo data to Apple Health") {
                        Task {
                            do {
                                try await model.writeDemoDataToHealth()
                                debugStatus = "Written. Switch the source to Apple Health to read it back."
                            } catch {
                                debugStatus = error.localizedDescription
                            }
                        }
                    }
                    if let debugStatus {
                        Text(debugStatus).font(.footnote)
                    }
                    Button("Run the background update in 5 seconds") {
                        Notifier.forget()
                        Task {
                            try? await Task.sleep(for: .seconds(5))
                            await model.refreshInBackground()
                        }
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("The first copies four months of the healthy demo history into Apple Health, so the Apple Health path has data in the simulator. The second does what the nightly task does, including the notifications that are switched on; leave the app before it runs, since iOS shows no banner over the app itself. Debug builds only.")
                }
            #endif

            Section("About") {
                Text("Baseline gives wellness insights, not medical advice. It does not diagnose, and its ranges and flags are estimates from your own history. If you are worried about your health, talk to a clinician.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onDisappear { pickedSource.map(model.choose) }
        .onChange(of: model.scenario) { Task { await model.refresh() } }
        .onChange(of: model.forecastMode) { Task { await model.refresh() } }
        .onChange(of: [notifiesAnomalies, notifiesReadiness, notifiesReport]) { _, enabled in
            if enabled.contains(true) { Task { await Notifier.requestPermission() } }
        }
        .confirmationDialog("Erase the journal, feedback and forecasts stored by Baseline? Apple Health is not touched.", isPresented: $confirmsErase, titleVisibility: .visible) {
            Button("Erase", role: .destructive) {
                model.eraseEverything()
                dismiss()
            }
        }
    }

    /// A new source closes Settings and takes effect once it has closed (`onDisappear`).
    /// It reloads the app, and Apple Health does not get its access sheet up while another
    /// sheet is still on its way out: the request then hangs until it times out.
    private var sourceBinding: Binding<AppModel.DataSource> {
        Binding(
            get: { pickedSource ?? model.dataSource ?? .demo },
            set: { source in
                guard source != model.dataSource else { return }
                pickedSource = source
                dismiss()
            })
    }

    private var baselineText: String {
        switch model.baseline {
        case .established: "Established"
        case .learning(let nights): "Learning, \(nights) of \(BaselineState.nightsNeeded) nights"
        }
    }

    private var intelligenceText: String {
        switch InsightGenerator.availability {
        case .available: "On"
        case .unavailable(.deviceNotEligible): "Not supported on this device"
        case .unavailable(.appleIntelligenceNotEnabled): "Turned off in Settings"
        case .unavailable(.modelNotReady): "Still downloading"
        case .unavailable: "Unavailable"
        }
    }
}

struct EvaluationView: View {
    @Environment(AppModel.self) private var model
    @State private var scores: [ForecastMode: [BacktestScore]] = [:]
    @State private var usage = (seconds: 0.0, calls: 0)
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                Text("One day ahead over the last 90 days. Error is the mean miss of the median forecast; lower is better. Coverage is how often the value fell inside the expected range; a calibrated range holds 80%.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(ForecastMode.allCases) { mode in
                Section(mode == .univariate ? "Chronos-2, each metric alone" : "Chronos-2, all metrics jointly") {
                    if let scores = scores[mode] {
                        ForEach(scores) { ScoreRow(score: $0) }
                    } else if failure == nil {
                        ProgressView()
                    }
                }
            }
            Section("On-device cost") {
                LabeledContent("Model calls since launch", value: usage.calls.formatted())
                LabeledContent("Model time since launch", value: "\(usage.seconds.formatted(.number.precision(.fractionLength(2)))) s")
                if usage.calls > 0 {
                    LabeledContent("Per call", value: "\((1000 * usage.seconds / Double(usage.calls)).formatted(.number.precision(.fractionLength(0)))) ms")
                }
            }
            if let failure {
                Section { Text(failure).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Model check")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                for mode in ForecastMode.allCases {
                    scores[mode] = try await model.backtest(mode: mode)
                }
                usage = await Chronos2Forecaster.shared.usage
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private struct ScoreRow: View {
    var score: BacktestScore

    /// Errors get three significant digits: the two forecasters are often close.
    private func line(_ name: String, error: Double, coverage: Double) -> String {
        "\(name): error \(error.formatted(.number.precision(.significantDigits(3)))) \(score.metric.unit) · coverage \(coverage.formatted(.percent.precision(.fractionLength(0))))"
    }

    var body: some View {
        let metric = score.metric
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(metric.title, systemImage: metric.symbol).foregroundStyle(metric.tint)
                Spacer()
                Text("\(score.days) days").foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.medium))
            Text(line("Chronos-2", error: score.modelError, coverage: score.modelCoverage))
            Text(line("Simple average", error: score.simpleError, coverage: score.simpleCoverage))
                .foregroundStyle(.secondary)
        }
        .font(.footnote.monospacedDigit())
    }
}
