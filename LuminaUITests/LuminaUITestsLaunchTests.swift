//
//  LuminaUITestsLaunchTests.swift
//  LuminaUITests
//
//  Created by Amr Mafalani on 2026-07-17.
//

import XCTest

final class LuminaUITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LUMINA_DISABLE_AUTOSTART"] = "1"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["videoMethodPicker"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Connect with AirPlay"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Lumina Setup Assistant"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
