import XCTest

final class OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["SAYMARK_UI_TESTING"] = "1"
        app.launchArguments += [
            "-saymark.didOnboard", "NO",
            "-saymark.triggerMode", "toggle",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testFirstRunCompletesWithoutExternalServices() throws {
        XCTAssertTrue(
            app.descendants(matching: .any)["onboarding.root"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Speak naturally. Write anywhere."].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["onboarding.welcome-mark"].exists
        )
        XCTAssertFalse(app.switches["Share anonymous usage & crash reports"].exists)
        XCTAssertFalse(app.staticTexts["Setup steps"].exists)
        XCTAssertFalse(app.buttons["Replay the setup tour"].exists)

        clickContinue("Set Up Saymark")
        XCTAssertTrue(app.staticTexts["Allow Saymark to listen and type"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: "onboarding.permission.allowed").count,
            2
        )

        clickContinue("Continue")
        XCTAssertTrue(app.staticTexts["Choose how to start dictation"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["onboarding.trigger-mode"].exists
        )
        XCTAssertTrue(app.descendants(matching: .any)["Hold to Dictate"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Press to Start/Stop"].exists)
        app.links["Use Recommended Shortcut"].click()

        clickContinue("Continue")
        XCTAssertTrue(app.staticTexts["Preparing on-device dictation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Stored on this Mac. Audio isn’t uploaded."].exists)

        clickContinue("Continue")
        XCTAssertTrue(app.staticTexts["Try your shortcut"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["onboarding.shortcut-instruction"].exists
        )
        XCTAssertFalse(app.buttons["Try with Button"].exists)

        app.typeKey(.space, modifierFlags: [.control, .shift])
        XCTAssertTrue(
            app.descendants(matching: .any)["onboarding.try-listening"]
                .waitForExistence(timeout: 2)
        )
        app.typeKey(.space, modifierFlags: [.control, .shift])
        XCTAssertTrue(app.staticTexts["Shortcut works."].waitForExistence(timeout: 5))

        clickContinue("Finish")
        XCTAssertFalse(
            app.descendants(matching: .any)["onboarding.root"]
                .waitForExistence(timeout: 1)
        )
    }

    func testWelcomeIdleResourceMetrics() throws {
        XCTAssertTrue(
            app.descendants(matching: .any)["onboarding.root"]
                .waitForExistence(timeout: 5)
        )
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(
            metrics: [
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app),
                XCTClockMetric(),
            ],
            options: options
        ) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        }
    }

    func testShortcutRecorderReverseTabReachesContinue() throws {
        clickContinue("Set Up Saymark")
        clickContinue("Continue")
        XCTAssertTrue(app.staticTexts["Choose how to start dictation"].waitForExistence(timeout: 5))

        let recorder = app.descendants(matching: .any)["onboarding.shortcut-recorder"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 2))
        recorder.click()
        app.typeKey(.tab, modifierFlags: [.shift])

        let focusedContinue = app.buttons
            .matching(identifier: "onboarding.continue")
            .matching(NSPredicate(format: "hasFocus == true"))
            .firstMatch
        XCTAssertTrue(focusedContinue.waitForExistence(timeout: 2))
        app.typeKey(.space, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["Preparing on-device dictation"].waitForExistence(timeout: 5))
    }

    private func continueButton(_ label: String) -> XCUIElement {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 2))
        XCTAssertTrue(button.isEnabled)
        return button
    }

    private func clickContinue(_ label: String) {
        let button = continueButton(label)
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}
