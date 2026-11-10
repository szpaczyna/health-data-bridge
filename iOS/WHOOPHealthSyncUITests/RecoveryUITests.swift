import XCTest

final class RecoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func app(language: String, largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", language]
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); return app
    }
    func testT27SpanishDashboardAndDisabledRecoveryOption() {
        let app = app(language: "spanish")
        XCTAssertTrue(app.staticTexts["HRV de recuperación"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Opciones"].tap()
        let button = app.buttons["recovery.importHistory"]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(app.staticTexts["Desactivada"].exists || app.staticTexts["Requiere iOS 27"].exists)
        attach("Spanish recovery options", app)
    }
    func testT27EnglishDashboardAndDisabledRecoveryOption() {
        let app = app(language: "english")
        XCTAssertTrue(app.staticTexts["Recovery HRV"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Options"].tap()
        let button = app.buttons["recovery.importHistory"]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertFalse(button.isEnabled)
        XCTAssertTrue(app.staticTexts["Disabled"].exists || app.staticTexts["Requires iOS 27"].exists)
        attach("English recovery options", app)
    }
    func testT27LargeTypeHasAccessibleStateAndActions() {
        let app = app(language: "spanish", largeType: true)
        let status = app.staticTexts["recovery.dashboard.status"]
        // Saved progress/reconnection copy can add several screens at accessibility XXXL.
        // Verify actual reachability instead of assuming a fixed four-swipe layout.
        for _ in 0..<10 {
            if status.exists && status.isHittable { break }
            app.swipeUp()
        }
        attach("XXXL scrolled recovery status", app)
        XCTAssertTrue(status.waitForExistence(timeout: 10)); XCTAssertTrue(status.isHittable)
        app.tabBars.buttons["Opciones"].tap()
        XCTAssertTrue(app.staticTexts["recovery.status"].waitForExistence(timeout: 5))
        attach("Large type", app)
    }
    func testT26ExistingSignInStillOpensAndCanBeCancelled() {
        let app = app(language: "english")
        let connect = app.buttons.matching(NSPredicate(format: "label IN %@", ["Connect WHOOP", "Reconnect"])).firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 10)); connect.tap()
        XCTAssertTrue(app.webViews["auth.webLogin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Cancel"].exists); app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Recovery HRV"].exists)
    }
    func testRecoveryReadOnlyComparisonIsAvailableAndLocalized() {
        let app = app(language: "spanish")
        XCTAssertTrue(app.staticTexts["HRV de recuperación"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Opciones"].tap()
        let importButton = app.buttons["recovery.importHistory"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5)); XCTAssertFalse(importButton.isEnabled)
        let diagnostic = app.buttons["recovery.compareValues"]
        for _ in 0..<6 {
            if diagnostic.exists && diagnostic.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(diagnostic.waitForExistence(timeout: 5))
        XCTAssertEqual(diagnostic.label, "Comparar valores de recuperación con WHOOP")
        XCTAssertTrue(diagnostic.isEnabled)
        XCTAssertTrue(diagnostic.isHittable)
        attach("Read-only recovery comparison", app)
    }

    func testRecoverySetupRequiresExplicitChecksAndRunsUnifiedSync() throws {
        guard #available(iOS 27, *) else { throw XCTSkip("Recovery setup requires iOS 27") }
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("WHOOP 0.2 QA") == true else { throw XCTSkip("Requires isolated recovery QA simulator") }
        let app = XCUIApplication(); app.launchArguments = ["-appLanguage", "spanish", "-whoopRecoveryUITest", "-whoopFixtureID", UUID().uuidString]
        app.launch()
        let configure = app.buttons["sync.primary"]
        XCTAssertTrue(configure.waitForExistence(timeout: 10)); XCTAssertTrue(configure.isEnabled); configure.tap()
        XCTAssertEqual(app.datePickers.count, 0, "Initial setup must not ask for a historical start")
        let enable = app.buttons["recovery.enable"]
        XCTAssertFalse(enable.exists && enable.isEnabled)
        let authorize = app.buttons["recovery.authorize"]
        for _ in 0..<4 { if authorize.exists && authorize.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(authorize.waitForExistence(timeout: 5)); authorize.tap()
        attach("Recovery setup after authorization", app)
        let native = app.switches["recovery.confirmNoNativeExport"]
        for _ in 0..<4 { if native.exists && native.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(native.waitForExistence(timeout: 5)); native.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(native.value as? String, "1")
        let full = app.switches["recovery.confirmFullReading"]
        for _ in 0..<4 { if full.exists && full.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(full.exists); full.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(full.value as? String, "1")
        for _ in 0..<4 { if enable.isHittable { break }; app.swipeUp() }
        attach("Recovery setup before enabling", app)
        XCTAssertTrue(enable.isEnabled)
        attach("Recovery authorization confirmations", app); enable.tap()
        XCTAssertTrue(app.staticTexts["Resumen"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["HRV de recuperación escrita"].exists)
        app.tabBars.buttons["Opciones"].tap()
        let importButton = app.buttons["recovery.importHistory"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5)); XCTAssertTrue(importButton.isEnabled); importButton.tap()
        XCTAssertTrue(app.datePickers.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["history.start"].isEnabled)
        attach("Common historical period", app)
        app.buttons["Cancelar"].tap()
        app.terminate()
    }

    func testExistingInstallationKeepsDailyFlowAcrossRelaunch() throws {
        guard #available(iOS 27, *) else { throw XCTSkip("Requires isolated iOS 27 fixture") }
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("WHOOP 0.2 QA") == true else { throw XCTSkip("Requires isolated QA simulator") }
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english", "-whoopExistingUITest", "-whoopFixtureID", UUID().uuidString]
        app.launch()
        let sync = app.buttons["sync.primary"]
        XCTAssertTrue(sync.waitForExistence(timeout: 10)); XCTAssertEqual(sync.label, "Sync now")
        XCTAssertFalse(app.buttons["recovery.authorize"].exists)
        sync.tap()
        XCTAssertTrue(app.staticTexts["Summary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Recovery HRV written"].exists)
        attach("Existing installation unified daily sync", app)
        app.terminate(); app.launch()
        XCTAssertTrue(sync.waitForExistence(timeout: 10)); XCTAssertEqual(sync.label, "Sync now")
        XCTAssertFalse(app.buttons["recovery.authorize"].exists)
        app.tabBars.buttons["Options"].tap()
        app.buttons["recovery.configure"].tap()
        XCTAssertTrue(app.buttons["recovery.authorize"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["sync.includeHRV"].value as? String, "1")
        app.buttons["Cancel"].tap()
        app.tabBars.buttons["Sync"].tap()
        XCTAssertEqual(sync.label, "Sync now")
        attach("Existing configuration cancelled without onboarding", app)
    }

    func testFreshSetupCanContinueWithoutHRVAndDoesNotRepeat() throws {
        guard #available(iOS 27, *) else { throw XCTSkip("Requires isolated iOS 27 fixture") }
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("WHOOP 0.2 QA") == true else { throw XCTSkip("Requires isolated QA simulator") }
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english", "-whoopRecoveryUITest", "-whoopFixtureID", UUID().uuidString]
        app.launch(); app.buttons["sync.primary"].tap()
        let toggle = app.switches["sync.includeHRV"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["recovery.authorize"].tap()
        let save = app.buttons["recovery.enable"]
        for _ in 0..<4 { if save.exists && save.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["Summary"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertEqual(app.buttons["sync.primary"].label, "Sync now")
        XCTAssertFalse(app.buttons["recovery.authorize"].exists)
        app.tabBars.buttons["Options"].tap(); app.buttons["recovery.configure"].tap()
        XCTAssertTrue(app.switches["sync.includeHRV"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["sync.includeHRV"].value as? String, "0", "A saved opt-out must not be replaced by the new-user default")
        app.buttons["Cancel"].tap()
        attach("Fresh setup without HRV persisted", app)
    }

    private func attach(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testFreshLoginOpensCombinedSetupAutomaticallyAndCanBeCancelled() throws {
        guard #available(iOS 27, *) else { throw XCTSkip("Requires isolated iOS 27 fixture") }
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("WHOOP 0.2 QA") == true else { throw XCTSkip("Requires isolated QA simulator") }
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english", "-whoopLoginUITest", "-whoopFixtureID", UUID().uuidString]
        app.launch(); app.buttons["sync.primary"].tap()
        let fixtureLogin = app.buttons["auth.fixtureLogin"]
        XCTAssertTrue(fixtureLogin.waitForExistence(timeout: 5))
        fixtureLogin.tap()
        XCTAssertTrue(app.buttons["recovery.authorize"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["sync.includeHRV"].exists)
        XCTAssertEqual(app.datePickers.count, 0)
        attach("Fresh login routes to combined setup", app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["sync.primary"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["sync.primary"].label, "Set up sync")
        XCTAssertFalse(app.buttons["recovery.authorize"].exists, "Cancelling does not trap the user in repeated onboarding")
    }

    func testDeniedHRVCanContinueWithBaseWithoutAnotherAuthorization() throws {
        guard #available(iOS 27, *) else { throw XCTSkip("Requires iOS 27 HRV fixture") }
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("WHOOP 0.2 QA") == true else { throw XCTSkip("Requires isolated QA simulator") }
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "spanish", "-whoopRecoveryUITest", "-whoopHRVDeniedUITest", "-whoopFixtureID", UUID().uuidString]
        app.launch(); app.buttons["sync.primary"].tap()
        let authorize = app.buttons["recovery.authorize"]
        for _ in 0..<6 { if authorize.isHittable { break }; app.swipeUp() }
        authorize.tap()
        let continueBase = app.buttons["sync.continueWithoutHRV"]
        for _ in 0..<8 { if continueBase.exists && continueBase.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(continueBase.isHittable); continueBase.tap()
        let save = app.buttons["recovery.enable"]
        for _ in 0..<6 { if save.exists && save.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(save.isEnabled, "Base authorization remains valid after dropping denied HRV")
        save.tap(); XCTAssertTrue(app.staticTexts["Resumen"].waitForExistence(timeout: 10))
        attach("HRV denied; base setup retained", app)
    }

    func testEarlierIOSCanConfigureBaseAndExplainsUnavailableRMSSD() throws {
        if #available(iOS 27, *) { throw XCTSkip("Requires earlier runtime") }
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.contains("WHOOP 0.2 QA") == true else { throw XCTSkip("Requires isolated QA simulator") }
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "english", "-whoopRecoveryUITest", "-whoopFixtureID", UUID().uuidString]
        app.launch(); app.buttons["sync.primary"].tap()
        XCTAssertFalse(app.switches["sync.includeHRV"].isEnabled)
        XCTAssertTrue(app.staticTexts["Requires iOS 27 and support for RMSSD HRV"].exists)
        let authorize = app.buttons["recovery.authorize"]
        for _ in 0..<6 { if authorize.isHittable { break }; app.swipeUp() }
        authorize.tap()
        let save = app.buttons["recovery.enable"]
        for _ in 0..<6 { if save.exists && save.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.staticTexts["Summary"].waitForExistence(timeout: 10))
        attach("Earlier iOS base configuration", app)
    }
}
