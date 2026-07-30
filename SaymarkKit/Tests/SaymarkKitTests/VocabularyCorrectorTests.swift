import XCTest
@testable import SaymarkKit

final class VocabularyCorrectorTests: XCTestCase {
    private let saymark = VocabularyCorrector(entries: [
        VocabularyEntry(term: "Saymark",
                        aliases: ["cmarc", "c mark", "say mark", "see mark", "seymark"]),
    ])

    func testRewritesSingleWordAlias() {
        XCTAssertEqual(saymark.correct("I love cmarc"), "I love Saymark")
    }

    func testIsCaseInsensitive() {
        XCTAssertEqual(saymark.correct("CMARC is great"), "Saymark is great")
        XCTAssertEqual(saymark.correct("Cmarc is great"), "Saymark is great")
    }

    func testRewritesMultiWordAlias() {
        XCTAssertEqual(saymark.correct("open say mark now"), "open Saymark now")
    }

    func testCollapsesExtraWhitespaceInMultiWordAlias() {
        XCTAssertEqual(saymark.correct("open say   mark now"), "open Saymark now")
    }

    func testPreservesAdjacentPunctuation() {
        XCTAssertEqual(saymark.correct("Try cmarc."), "Try Saymark.")
        XCTAssertEqual(saymark.correct("(cmarc)"), "(Saymark)")
    }

    func testDoesNotMatchInsideLargerWord() {
        XCTAssertEqual(saymark.correct("cmarcs"), "cmarcs")
        XCTAssertEqual(saymark.correct("scmarc"), "scmarc")
    }

    func testLeavesUnrelatedTextUnchanged() {
        XCTAssertEqual(saymark.correct("the quick brown fox"), "the quick brown fox")
    }

    func testEmptyVocabularyIsIdentity() {
        let empty = VocabularyCorrector(entries: [])
        XCTAssertEqual(empty.correct("cmarc"), "cmarc")
    }

    func testIgnoresBlankTermsAndAliases() {
        let corrector = VocabularyCorrector(entries: [
            VocabularyEntry(term: "  ", aliases: ["foo"]),
            VocabularyEntry(term: "Bar", aliases: ["", "  "]),
        ])
        XCTAssertEqual(corrector.correct("foo and bar"), "foo and bar")
    }

    func testMultipleOccurrencesAllRewritten() {
        XCTAssertEqual(saymark.correct("cmarc and cmarc"), "Saymark and Saymark")
    }
}
