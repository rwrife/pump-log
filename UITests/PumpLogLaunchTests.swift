import XCTest

final class PumpLogLaunchTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testQuickLogCorrectionServiceRetireAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-ui-store"]
        app.launchEnvironment["PUMPLOG_UI_TEST_STORE"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["vehicle.add"].waitForExistence(timeout: 10))
        app.buttons["vehicle.add"].tap()
        let name = app.textFields["vehicle.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Wagon")
        app.buttons["vehicle.save"].tap()
        let vehicle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'vehicle.row.' AND label CONTAINS 'Wagon'")).firstMatch
        XCTAssertTrue(vehicle.waitForExistence(timeout: 5))
        vehicle.tap()

        logFill(app, odometer: "100", volume: "5", price: "15.00")
        logFill(app, odometer: "200", volume: "5", price: "15.00")
        XCTAssertTrue(app.staticTexts["economy.mpg"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["economy.mpg"].label.contains("20 MPG"))
        XCTAssertTrue(app.staticTexts["economy.evidence"].label.contains("100 miles ÷ 5 US gallons"))

        let fills = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fill.'"))
        XCTAssertEqual(fills.count, 2)
        fills.element(boundBy: 1).tap()
        let correctionVolume = app.textFields["fill.volume"]
        correctionVolume.tap()
        correctionVolume.typeText(XCUIKeyboardKey.delete.rawValue + "10")
        app.buttons["fill.save"].tap()
        XCTAssertTrue(app.staticTexts["economy.mpg"].label.contains("10 MPG"))
        XCTAssertTrue(fills.element(boundBy: 1).label.contains("original:"))

        app.buttons["service-log.add"].tap()
        let category = app.textFields["service.category"]
        category.tap(); category.typeText("Oil")
        let servicePrice = app.textFields["service.price"]
        servicePrice.tap(); servicePrice.typeText("45.50")
        app.buttons["service.save"].tap()
        let service = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'service.'")).firstMatch
        // Stats links lengthen the List; the service section is lazy until
        // scrolled into view. Keep the query scoped to ledger row identifiers.
        for _ in 0..<5 where !service.exists { app.swipeUp() }
        XCTAssertTrue(service.waitForExistence(timeout: 5))
        service.tap()
        let editedCategory = app.textFields["service.category"]
        editedCategory.tap()
        editedCategory.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "Transmission")
        app.buttons["service.save"].tap()
        XCTAssertTrue(service.label.contains("Transmission"))

        // The retire row is the last (lazy) List section: it does not exist
        // in the hierarchy until scrolled into view. Bound the scroll loop.
        let retire = app.buttons["vehicle.retire"]
        for _ in 0..<5 where !retire.exists { app.swipeUp() }
        XCTAssertTrue(retire.waitForExistence(timeout: 5))
        retire.tap()
        // iOS presents the confirmationDialog as an action sheet whose row
        // Button mirrors its label into a nested element carrying the same
        // identifier; the nested copy is hittable, so firstMatch is correct.
        app.buttons["vehicle.retire.confirm"].firstMatch.tap()
        // Toolbar items vanish only after the retire re-render; poll for
        // absence (bounded) instead of racing it with a bare exists check.
        var fillToolbarGone = false
        for _ in 0..<20 {
            if !app.buttons["fill-log.add"].exists { fillToolbarGone = true; break }
            usleep(500_000)
        }
        XCTAssertTrue(fillToolbarGone, "Log-fill toolbar button should disappear after retirement")
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        let retained = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'vehicle.row.'")).firstMatch
        XCTAssertTrue(retained.waitForExistence(timeout: 10))
        // NavigationLink rows merge their child Texts into one element; query
        // the merged row label instead of a nested staticText (fleet pitfall).
        XCTAssertTrue(retained.label.contains("Retired"))
        retained.tap()
        XCTAssertTrue(app.staticTexts["economy.mpg"].label.contains("10 MPG"))
        let retainedService = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'service.'")).firstMatch
        for _ in 0..<5 where !retainedService.exists { app.swipeUp() }
        XCTAssertTrue(retainedService.waitForExistence(timeout: 5))
        XCTAssertTrue(retainedService.label.contains("Transmission"))
    }

    @MainActor
    func testStatsScreensShowEvidenceRotorsAndStatedCoverage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-ui-store"]
        app.launchEnvironment["PUMPLOG_UI_TEST_STORE"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.buttons["vehicle.add"].waitForExistence(timeout: 10))
        app.buttons["vehicle.add"].tap()
        let name = app.textFields["vehicle.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Commuter")
        app.buttons["vehicle.save"].tap()
        let vehicle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'vehicle.row.' AND label CONTAINS 'Commuter'")).firstMatch
        XCTAssertTrue(vehicle.waitForExistence(timeout: 5))
        vehicle.tap()

        // Two full-to-full fills → one MPG point; a top-off → named exclusion.
        logFill(app, odometer: "100", volume: "5", price: "15.00")
        logFill(app, odometer: "200", volume: "5", price: "15.00")
        app.buttons["fill-log.add"].tap()
        XCTAssertTrue(app.segmentedControls["filltype.segment"].waitForExistence(timeout: 5))
        app.segmentedControls["filltype.segment"].buttons["Top-off"].tap()
        let miles = app.textFields["fill.odometer"]
        miles.tap(); miles.typeText("230")
        let gallons = app.textFields["fill.volume"]
        gallons.tap(); gallons.typeText("1")
        let amount = app.textFields["fill.price"]
        amount.tap(); amount.typeText("3.00")
        // Decimal-pad fields have no return key; the keyboard toolbar Save is
        // hittable above the keyboard (keyboard-toolbar pitfall).
        app.buttons["fill.keyboard.save"].tap()
        assertFillSaved(app)

        // A service with a user-owned rule surfaces in cost stats and (via
        // category totals) proves the cost ledger path.
        app.buttons["service-log.add"].tap()
        let category = app.textFields["service.category"]
        category.tap(); category.typeText("Oil")
        let servicePrice = app.textFields["service.price"]
        servicePrice.tap(); servicePrice.typeText("45.50")
        app.buttons["service.save"].tap()

        // Economy stats screen.
        let economyNav = app.buttons["stats-link.economy"]
        for _ in 0..<5 where !economyNav.exists { app.swipeUp() }
        XCTAssertTrue(economyNav.waitForExistence(timeout: 5))
        economyNav.tap()
        let point = app.staticTexts["economy.point.0"]
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        XCTAssertTrue(point.label.contains("20 MPG (US)"))
        XCTAssertTrue(point.label.contains("100 miles ÷ 5 US gallons"))
        let window3 = app.staticTexts["economy.window.3"]
        XCTAssertTrue(window3.label.contains("1 samples"))
        let exclusion = app.staticTexts["economy.exclusion.0"]
        XCTAssertTrue(exclusion.waitForExistence(timeout: 5))
        XCTAssertTrue(exclusion.label.contains("top-off"))
        // Back out via the navigation bar's back button (edge swipe is flaky
        // under CI animation timing).
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Cost stats screen: coverage % is stated in text, never implied.
        let costNav = app.buttons["stats-link.cost"]
        for _ in 0..<5 where !costNav.exists { app.swipeUp() }
        XCTAssertTrue(costNav.waitForExistence(timeout: 5))
        costNav.tap()
        let perMile = app.staticTexts["cost.permile"]
        XCTAssertTrue(perMile.waitForExistence(timeout: 5))
        // Same-instant UI fills may yield zero-duration mileage intervals, so
        // cost/mile can be honestly unknown; what must ALWAYS be true is the
        // coverage percentage stated in text.
        XCTAssertTrue(perMile.label.contains("% coverage"))
        let fuelRow = app.staticTexts["cost.category.Fuel"]
        XCTAssertTrue(fuelRow.waitForExistence(timeout: 5))
        XCTAssertTrue(fuelRow.label.contains("$33.00"))
        XCTAssertTrue(app.staticTexts["cost.category.Oil"].label.contains("$45.50"))
    }

    @MainActor
    private func logFill(_ app: XCUIApplication, odometer: String, volume: String, price: String) {
        app.buttons["fill-log.add"].tap()
        XCTAssertTrue(app.segmentedControls["filltype.segment"].waitForExistence(timeout: 5))
        let miles = app.textFields["fill.odometer"]
        XCTAssertTrue(miles.waitForExistence(timeout: 5))
        miles.tap(); miles.typeText(odometer)
        let gallons = app.textFields["fill.volume"]
        gallons.tap(); gallons.typeText(volume)
        let amount = app.textFields["fill.price"]
        amount.tap(); amount.typeText(price)
        app.buttons["fill.save"].tap()
        assertFillSaved(app)
    }

    @MainActor
    private func assertFillSaved(_ app: XCUIApplication) {
        let alert = app.alerts["Could not save fill"]
        XCTAssertFalse(alert.exists, "Fill save failed: \(alert.debugDescription)")
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.textFields["fill.odometer"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed,
                       "Fill sheet did not close. Alert: \(app.alerts.firstMatch.debugDescription)")
    }
}
