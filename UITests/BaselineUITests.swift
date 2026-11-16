import XCTest

/// The main screens on the demo data. Launch arguments land in UserDefaults' argument
/// domain, which is where the app keeps its data source and scenario, so no test hook is
/// needed in the app.
@MainActor
final class BaselineUITests: XCTestCase {
    /// The first launch compiles the Core ML model and forecasts six months of history.
    private let firstLoad: TimeInterval = 90

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-dataSource", "demo", "-scenario", scenario]
        app.launch()
        return app
    }

    /// Keeps a picture of the screen with the test results; `scripts/uitest.sh` collects them.
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Any element whose label contains `text`: cards are links, so their texts are not
    /// always exposed as static texts of their own.
    private func element(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    func testSickWeekShowsReadinessAndTheWarningOnToday() {
        let app = launch(scenario: "sickWeek")

        XCTAssertTrue(element("Readiness", in: app).waitForExistence(timeout: firstLoad))
        XCTAssertTrue(element("Several vitals elevated", in: app).waitForExistence(timeout: 30))
        XCTAssertTrue(element("consider talking to a clinician", in: app).exists)
        XCTAssertTrue(element("Stress", in: app).exists)
        // The explanation arrives a moment after the event.
        _ = element("Explained on this device", in: app).waitForExistence(timeout: 20)
        screenshot("today")

        // A value outside its range says what to do about it, on the metric's own screen.
        // The metric's tile, not the readiness text that also names it.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Resting heart rate'")).firstMatch.tap()
        XCTAssertTrue(element("What to do", in: app).waitForExistence(timeout: 10))
        _ = element("Explained on this device", in: app).waitForExistence(timeout: 20)
        screenshot("metric-advice")
    }

    func testMetricDetailShowsTheChartAndItsSpans() {
        let app = launch(scenario: "healthy")
        XCTAssertTrue(element("Readiness", in: app).waitForExistence(timeout: firstLoad))

        element("Resting heart rate", in: app).tap()

        XCTAssertTrue(app.buttons["6M"].waitForExistence(timeout: 10))
        screenshot("metric")
        app.buttons["6M"].tap()
        XCTAssertTrue(element("Compare with a simple average", in: app).exists)
        screenshot("metric-6-months")
    }

    func testJournalListsFlaggedEventsAndOpensOne() {
        let app = launch(scenario: "healthy")
        XCTAssertTrue(element("Readiness", in: app).waitForExistence(timeout: firstLoad))

        app.tabBars.buttons["Journal"].tap()
        let strain = element("Signs of sustained strain", in: app)
        XCTAssertTrue(strain.waitForExistence(timeout: 60))
        screenshot("journal")
        strain.tap()

        XCTAssertTrue(element("What moved", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("Does this make sense?", in: app).exists)
        _ = element("Explained on this device", in: app).waitForExistence(timeout: 20)
        screenshot("event")
    }

    func testInsightsShowsTheWeeklyReportAndAsk() {
        let app = launch(scenario: "healthy")
        XCTAssertTrue(element("Readiness", in: app).waitForExistence(timeout: firstLoad))

        app.tabBars.buttons["Insights"].tap()
        XCTAssertTrue(element("This week", in: app).waitForExistence(timeout: 10))
        _ = element("Explained on this device", in: app).waitForExistence(timeout: 30)
        screenshot("insights")
        element("Ask about your data", in: app).tap()
        let question = app.buttons["How did I sleep last night?"]
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        question.tap()

        // With Apple Intelligence the answer is worded by the model and carries its facts;
        // without it, or when the wording is rejected, the facts are the answer.
        let answer = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'From your data' OR label CONTAINS 'overnight signals were outside'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 60))
        screenshot("ask")
    }

    func testOnboardingLeadsIntoTheDemo() {
        // Not a data source the app knows, so it starts as on a first launch.
        let app = XCUIApplication()
        app.launchArguments = ["-dataSource", "none", "-scenario", "healthy"]
        app.launch()

        XCTAssertTrue(element("Know your normal", in: app).waitForExistence(timeout: 30))
        screenshot("onboarding")
        XCTAssertTrue(app.buttons["Connect Apple Health"].exists)
        let demo = app.buttons["Explore with demo data"]
        for _ in 0..<6 where !demo.isHittable { app.swipeUp() }
        demo.tap()
        XCTAssertTrue(element("Readiness", in: app).waitForExistence(timeout: firstLoad))
    }

    /// The thesis's question on the device: both ways of forecasting against the simple average.
    func testModelCheckScoresBothForecasters() {
        let app = launch(scenario: "healthy")
        XCTAssertTrue(element("Readiness", in: app).waitForExistence(timeout: firstLoad))
        app.buttons["Settings"].firstMatch.tap()
        app.buttons["Model check"].firstMatch.tap()

        XCTAssertTrue(element("Simple average: error", in: app).waitForExistence(timeout: 120))
        screenshot("model-check")
        // The cost per call comes last, below both lists, once the second backtest is done:
        // keep scrolling to the end of a list that is still growing.
        let perCall = element("Per call", in: app)
        for _ in 0..<60 where !perCall.exists { app.swipeUp() }
        XCTAssertTrue(perCall.exists)
        screenshot("model-check-cost")
    }

    /// Permission, then the same update the nightly task runs, then the banner. The task
    /// itself cannot be started in a simulator; the debug button stands in for it.
    func testABackgroundUpdateNotifiesAboutReadiness() {
        let app = launch(scenario: "healthy")
        XCTAssertTrue(element("Readiness", in: app).waitForExistence(timeout: firstLoad))
        app.buttons["Settings"].firstMatch.tap()
        // The row is the switch as far as accessibility goes; a tap on its middle does nothing.
        let toggle = app.switches["Morning readiness"].firstMatch
        if toggle.value as? String == "0" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        // The system asks once per install; afterwards the switch just turns on.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) { allow.tap() }
        XCTAssertEqual(toggle.value as? String, "1")
        screenshot("settings")

        let update = app.buttons["Run the background update in 5 seconds"]
        for _ in 0..<8 where !update.exists { app.swipeUp() }
        update.tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(element("Your overnight signals are in", in: springboard).waitForExistence(timeout: 40))
        screenshot("notification")
    }

    /// The Apple Health path end to end: the debug writer fills the simulator's Health store
    /// with the healthy demo history, and the app reads it back through HealthKit.
    func testAppleHealthRoundTrip() {
        let app = launch(scenario: "healthy")
        XCTAssertTrue(element("Readiness", in: app).waitForExistence(timeout: firstLoad))
        app.buttons["Settings"].firstMatch.tap()

        let write = app.buttons["Write demo data to Apple Health"]
        for _ in 0..<8 where !write.exists { app.swipeUp() }
        write.tap()
        allowHealthAccess(in: app)
        XCTAssertTrue(element("Written.", in: app).waitForExistence(timeout: 60))

        let source = element("Source, Demo data", in: app)
        for _ in 0..<8 where !source.exists { app.swipeDown() }
        source.tap()
        app.buttons["Apple Health"].tap()
        // Settings closes, and the new source reloads the app from its first screen.
        allowHealthAccess(in: app)

        // The score says last night's signals came back. Wrist temperature cannot be written
        // to Health, so its readiness row, the only one in °C, tells the two sources apart.
        XCTAssertTrue(element("of 100", in: app).waitForExistence(timeout: firstLoad))
        XCTAssertTrue(element("Heart rate variability", in: app).exists)
        XCTAssertFalse(element("°C · expected", in: app).exists)
        screenshot("apple-health")
    }

    /// The first screen's own way into Apple Health. What Today shows then depends on what
    /// the simulator's Health store holds; the tabs are what counts here.
    func testOnboardingConnectsAppleHealth() {
        let app = XCUIApplication()
        app.launchArguments = ["-dataSource", "none"]
        app.launch()

        let connect = app.buttons["Connect Apple Health"]
        XCTAssertTrue(connect.waitForExistence(timeout: 30))
        for _ in 0..<6 where !connect.isHittable { app.swipeUp() }
        connect.tap()
        allowHealthAccess(in: app)
        XCTAssertTrue(app.tabBars.buttons["Insights"].waitForExistence(timeout: firstLoad))
    }

    /// Grants what the Health access sheet asks for. It comes up once per kind of access and
    /// simulator, so it may not be there; on a simulator that has never used Health it can
    /// take a minute, and these tests then fail the first time.
    private func allowHealthAccess(in app: XCUIApplication) {
        let everything = app.cells["UIA.Health.AuthSheet.AllCategoryButton"]
        guard everything.waitForExistence(timeout: 10) else { return }
        everything.tap()
        // Allow sits below the list of data types.
        // Allow sits below the list of data types. The sheet runs in another process, so the
        // test does not know when its scrolling has settled: tap until the page is gone.
        let allow = app.buttons["UIA.Health.Allow.Button"]
        for _ in 0..<6 where !allow.isHittable { app.swipeUp() }
        for _ in 0..<3 where everything.exists {
            allow.tap()
            _ = everything.waitForNonExistence(timeout: 3)
        }
        // For read access, iOS 27 then asks how far back the app may read.
        let allHistory = element("All Recorded Data and Future Data", in: app)
        if allHistory.waitForExistence(timeout: 5) {
            allHistory.tap()
            app.buttons["Allow"].firstMatch.tap()
        }
    }

    func testFirstDaysShowTheLearningBannerAndFlagNothing() {
        let app = launch(scenario: "coldStart")

        // The loading screen has a similar title; the banner is the one that counts nights.
        XCTAssertTrue(element("of 14 nights", in: app).waitForExistence(timeout: firstLoad))
        screenshot("first-days")
        app.tabBars.buttons["Journal"].tap()
        XCTAssertTrue(element("Nothing is flagged while your baseline is still learning", in: app).waitForExistence(timeout: 10))
    }
}
