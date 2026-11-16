import HealthData
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.dataSource == nil {
                OnboardingView()
            } else {
                switch model.phase {
                case .idle, .loading:
                    LoadingView()
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't read your data", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                        if model.dataSource == .health {
                            Text("Baseline needs an answer on the Health access sheet first. If the sheet did not come up, try again.")
                        }
                    } actions: {
                        Button("Try again") { Task { await model.refresh() } }
                            .buttonStyle(.borderedProminent)
                        if model.dataSource == .health {
                            Button("Use demo data instead") { model.choose(.demo) }
                        }
                    }
                case .ready:
                    tabs
                }
            }
        }
        .task(id: model.dataSource) { await model.refresh() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await model.refreshIfStale() } }
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Today", systemImage: "heart.text.square.fill") {
                NavigationStack { TodayView() }
            }
            Tab("Journal", systemImage: "list.bullet.rectangle.fill") {
                NavigationStack { JournalView() }
            }
            Tab("Insights", systemImage: "sparkles") {
                NavigationStack { InsightsView() }
            }
        }
    }
}

struct LoadingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.brand.gradient)
            Text("Learning your baseline").font(.title3.bold())
            ProgressView()
            Text("The forecasting model runs on this device. The first time takes a few seconds.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.dataSource == .health {
                // The first time, the Health access sheet can take a while to come up, and
                // it may never be answered: there has to be a way on without it.
                Text("Apple Health asks for access first. The first time, its sheet can take a minute to appear.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Use demo data instead") { model.choose(.demo) }
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.page)
    }
}

/// First launch: what the app does, what it reads and why, and where the data stays.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "waveform.path.ecg.rectangle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.brand.gradient)
                    Text("Baseline").font(.largeTitle.bold())
                    Text("Know your normal. Notice when it shifts.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                Card {
                    Promise(symbol: "chart.line.uptrend.xyaxis", title: "Learns your ranges", text: "A forecasting model on this device learns what is normal for you, from your own history.")
                    Promise(symbol: "exclamationmark.circle", title: "Flags what stands out", text: "Stress, poor recovery and several vitals shifting together, explained in plain language.")
                    Promise(symbol: "lock.shield", title: "Stays on your device", text: "No account, no server, no analytics. Your health data never leaves this device.")
                }

                Card {
                    CardTitle(title: "What Baseline reads from Apple Health, and why", symbol: "heart.text.square", tint: .brand)
                    ForEach(Metric.allCases) { metric in
                        Promise(symbol: metric.symbol, title: metric.title, text: metric.purpose, tint: metric.tint)
                    }
                    Promise(symbol: "heart", title: "Heart rate", text: "For the daytime stress estimate.", tint: .red)
                    Promise(symbol: "figure.run", title: "Workouts", text: "So training is not mistaken for stress.", tint: .green)
                    Text("You choose each type on the next screen. Baseline works with whatever you allow, and the more history you share, the sooner it knows your ranges. It writes only one thing: alcohol you log yourself.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Baseline gives wellness insights, not medical advice. It does not diagnose.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    Button {
                        model.choose(.health)
                    } label: {
                        Text("Connect Apple Health").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!HealthKitProvider.isAvailable)

                    Button {
                        model.choose(.demo)
                    } label: {
                        Text("Explore with demo data").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if !HealthKitProvider.isAvailable {
                        Text("Apple Health is not available on this device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Color.page)
    }
}

private struct Promise: View {
    var symbol: String
    var title: String
    var text: String
    var tint = Color.brand

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
