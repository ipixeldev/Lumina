//
//  LuminaUITests.swift
//  LuminaUITests
//
//  Created by Amr Mafalani on 2026-07-17.
//

import XCTest

final class LuminaUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testEnvironmentCheckProducesRealResults() throws {
        let app = XCUIApplication()
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

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
