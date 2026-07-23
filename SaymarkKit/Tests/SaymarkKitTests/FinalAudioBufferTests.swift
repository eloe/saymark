import XCTest
@testable import SaymarkKit

final class FinalAudioBufferTests: XCTestCase {
    func testLeadingAudioIsPreservedWhenSpeechIsDetectedLater() {
        var buffer = FinalAudioBuffer()
        buffer.append([1, 2, 3], speechDetected: false)
        buffer.append([4, 5], speechDetected: true)

        XCTAssertEqual(buffer.takeIfSpeechDetected(), [1, 2, 3, 4, 5])
    }

    func testAllSilenceSkipsFinalInferenceAndClearsAudio() {
        var buffer = FinalAudioBuffer()
        buffer.append([1, 2, 3], speechDetected: false)

        XCTAssertNil(buffer.takeIfSpeechDetected())
        XCTAssertEqual(buffer.sampleCount, 0)
    }

    func testTakeResetsSpeechStateForTheNextUtterance() {
        var buffer = FinalAudioBuffer()
        buffer.append([1], speechDetected: true)
        XCTAssertEqual(buffer.takeIfSpeechDetected(), [1])

        buffer.append([2], speechDetected: false)
        XCTAssertNil(buffer.takeIfSpeechDetected())
    }
}
