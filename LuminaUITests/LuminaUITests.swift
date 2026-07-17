//
//  LuminaUITests.swift
//  LuminaUITests
//
//  Created by Amr Mafalani on 2026-07-17.
//

import XCTest

final class LuminaUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func testApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LUMINA_DISABLE_AUTOSTART"] = "1"
        return app
    }

    @MainActor
    func testEnvironmentCheckProducesRealResults() throws {
        let app = testApplication()
        app.launch()

        let setupButton = app.buttons["Set up an iPhone"]
        XCTAssertTrue(setupButton.waitForExistence(timeout: 3))
        setupButton.click()

        let checkButton = app.buttons["checkThisMacButton"]
        XCTAssertTrue(checkButton.waitForExistence(timeout: 3))
        checkButton.click()

        let report = app.descendants(matching: .any)["environmentReport"]
        XCTAssertTrue(report.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["macOS"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Xcode"].exists)
    }

    /// Manual integration test: requires a trusted physical iPhone connected by USB.
    @MainActor
    func testConnectedPhysicalIPhoneIsDiscovered() throws {
        let app = testApplication()
        app.launch()

        let setupButton = app.buttons["Set up an iPhone"]
        XCTAssertTrue(setupButton.waitForExistence(timeout: 3))
        setupButton.click()

        let checkButton = app.buttons["checkThisMacButton"]
        XCTAssertTrue(checkButton.waitForExistence(timeout: 3))
        checkButton.click()

        let deviceReport = app.descendants(matching: .any)["deviceDiscoveryReport"]
        XCTAssertTrue(deviceReport.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["physicalIPhoneCard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["USB"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            testApplication().launch()
        }
    }
}
