import XCTest

final class PumpLogLaunchTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testQuickLogCorrectionServiceRetireAndRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-ui-store"]
        app.launch()
        XCTAssertTrue(app.buttons["vehicle.add"].waitForExistence(timeout: 10))
        app.buttons["vehicle.add"].tap()
        let name = app.textFields["vehicle.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Wagon")
        app.buttons["vehicle.save"].tap()
        let vehicle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'vehicle.row.'")).firstMatch
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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'service.'")).firstMatch.label.contains("Transmission"))
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
    }
}
