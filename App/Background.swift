import BackgroundTasks
import Forecasting
import Foundation
import HealthData
import UserNotifications

enum NotificationPreference: String {
    case anomalies = "notify.anomalies"
    case morningReadiness = "notify.readiness"
    case weeklyReport = "notify.report"

    var isOn: Bool { UserDefaults.standard.bool(forKey: rawValue) }
}

enum Notifier {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func announce(_ model: AppModel) async {
        guard model.baseline.isEstablished else { return }
        let snapshot = model.snapshot
        let today = String(Int(snapshot.today.timeIntervalSinceReferenceDate))

        if NotificationPreference.anomalies.isOn, let event = model.currentEvent, event.severity >= .notable {
            let state = "\(event.id)|\(Int(event.end.timeIntervalSinceReferenceDate))"
            await post(title: event.title, body: "\(snapshot.when(event).capitalizedFirst). Open Baseline to see what moved.", once: "announced.event", state)
        }
        if NotificationPreference.morningReadiness.isOn, let readiness = model.readiness {
            await post(title: "Readiness \(readiness.score)", body: "Your overnight signals are in. Open Baseline for the details.", once: "announced.readiness", today)
        }
        let isMonday = snapshot.calendar.component(.weekday, from: snapshot.today) == 2
        if NotificationPreference.weeklyReport.isOn, isMonday, let report = model.weeklyReport {
            await post(title: "Your week", body: report.content.headline, once: "announced.report", today)
        }
    }

    #if DEBUG
        static func forget() {
            ["announced.event", "announced.readiness", "announced.report"].forEach(UserDefaults.standard.removeObject)
        }
    #endif

    private static func post(title: String, body: String, once key: String, _ state: String) async {
        guard UserDefaults.standard.string(forKey: key) != state else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        UserDefaults.standard.set(state, forKey: key)
    }
}

enum BaselineBackground {
    static let nightlyTask = "app.baseline.nightly"

    /// Call from the app's `init`: the system requires handlers to be registered before
    /// launch finishes.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: nightlyTask, using: .main) { task in
            MainActor.assumeIsolated { runNightly(task) }
        }
        scheduleNightly()
        if AppModel.shared.dataSource == .health { observeHealth() }
    }

    private static var isObservingHealth = false

    /// Refreshes whenever Apple Health gets new overnight data. Called at launch, and when
    /// Apple Health is first connected: until the next launch nothing else would start it.
    static func observeHealth() {
        guard !isObservingHealth else { return }
        isObservingHealth = true
        Task {
            try? await HealthKitProvider().observeOvernightData {
                await AppModel.shared.refreshInBackground()
            }
        }
    }

    private static func runNightly(_ task: BGTask) {
        scheduleNightly()
        let work = Task {
            await AppModel.shared.refreshInBackground()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    private static func scheduleNightly() {
        let request = BGProcessingTaskRequest(identifier: nightlyTask)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 4), matchingPolicy: .nextTime)
        try? BGTaskScheduler.shared.submit(request)
    }
}
