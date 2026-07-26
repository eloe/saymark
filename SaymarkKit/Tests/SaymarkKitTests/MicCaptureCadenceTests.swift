import XCTest
@testable import SaymarkKit

final class MicCaptureCadenceTests: XCTestCase {
    func testProductionFeedMatchesSelectedCadence() {
        XCTAssertEqual(MicCapture.feedIntervalMilliseconds, 160)
        XCTAssertEqual(
            MicCapture.feedSamples,
            MicCapture.feedIntervalMilliseconds * 16
        )
    }

    func testSpeechHangoverPreservesPriorPauseWindow() {
        XCTAssertEqual(MicCapture.speechHangoverChunks, 6)
        XCTAssertEqual(
            MicCapture.feedIntervalMilliseconds * MicCapture.speechHangoverChunks,
            960
        )
    }
}
