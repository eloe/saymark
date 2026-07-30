import XCTest
@testable import SaymarkKit

final class VocabularyLearningTests: XCTestCase {
    private func pairs(_ h: String, _ c: String) -> [String] {
        VocabularyLearning.corrections(heard: h, corrected: c).map { "\($0.heard)=>\($0.term)" }
    }

    func testSingleWordReplacement() {
        XCTAssertEqual(pairs("Seymour now has a model", "Saymark now has a model"),
                       ["Seymour=>Saymark"])
    }

    func testMultiWordSpanCollapsesToOneTerm() {
        XCTAssertEqual(pairs("has Quinn the remodel", "has Qwen3"),
                       ["Quinn the remodel=>Qwen3"])
    }

    func testTwoSeparateReplacements() {
        XCTAssertEqual(pairs("Saymour and Quinn three", "Saymark and Qwen3"),
                       ["Saymour=>Saymark", "Quinn three=>Qwen3"])
    }

    func testIdenticalYieldsNoCorrections() {
        XCTAssertTrue(pairs("the quick brown fox", "the quick brown fox").isEmpty)
    }

    func testPureInsertionYieldsNoPair() {
        XCTAssertTrue(pairs("hello world", "hello there world").isEmpty)
    }

    func testEmptyInputsAreSafe() {
        XCTAssertTrue(pairs("", "anything").isEmpty)
        XCTAssertTrue(pairs("anything", "").isEmpty)
    }
}
