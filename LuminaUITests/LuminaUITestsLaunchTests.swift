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
        app.launch()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Lumina Welcome"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
