import XCTest

final class PumpLogLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBootstrapHomeLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Pump Log"].exists)
        XCTAssertTrue(app.staticTexts["Quick-log fills, unknown-safe odometer-gap exclusions, and cost-per-mile derivations land in the next milestones."].exists)
    }
}
