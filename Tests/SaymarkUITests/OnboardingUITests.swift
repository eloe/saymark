import XCTest

final class OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["SAYMARK_UI_TESTING"] = "1"
        app.launchArguments += ["-saymark.didOnboard", "NO"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testFirstRunCompletesWithoutExternalServices() throws {
        XCTAssertTrue(app.otherElements["onboarding.root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Just talk. I’ll type it."].exists)
        let modelNote = app.staticTexts["onboarding.model-note"]
        XCTAssertTrue(modelNote.exists)
        XCTAssertFalse(app.staticTexts["Two voice models installed"].exists)
        XCTAssertTrue(app.otherElements["onboarding.local-diagnostics"].exists)
        XCTAssertFalse(app.switches["Share anonymous usage & crash reports"].exists)

        continueButton("Get started").click()
        XCTAssertTrue(app.staticTexts["Two quick permissions"].waitForExistence(timeout: 2))

        continueButton("Continue").click()
        XCTAssertTrue(app.staticTexts["Choose your push-to-talk"].waitForExistence(timeout: 2))

        continueButton("Continue").click()
        XCTAssertTrue(app.staticTexts["Getting my voice ready"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Your model is on your Mac — you’re ready to roll."].waitForExistence(timeout: 2))

        continueButton("Continue").click()
        XCTAssertTrue(app.staticTexts["Give me a sentence"].waitForExistence(timeout: 2))

        let tryButton = app.buttons["Hold to talk"]
        XCTAssertTrue(tryButton.waitForExistence(timeout: 2))
        tryButton.click()
        XCTAssertTrue(app.staticTexts["Got it — that’s exactly what I said."].waitForExistence(timeout: 2))

        continueButton("I’ve got it").click()
        XCTAssertTrue(app.staticTexts["You’re ready to talk"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Voice model installed"].exists)
    }

    func testWelcomeIdleResourceMetrics() throws {
        XCTAssertTrue(app.otherElements["onboarding.root"].waitForExistence(timeout: 5))
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

    private func continueButton(_ label: String) -> XCUIElement {
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 2))
        XCTAssertTrue(button.isEnabled)
        return button
    }
}
