import Foundation
@testable import SaymarkKit
import XCTest

final class Unicode15_1Tests: XCTestCase {
    func test_U23_pinnedUnicodeVersionIs15_1_0() {
        XCTAssertEqual(Unicode15_1.version, "15.1.0")
    }

    func test_U23_adversarialCompatibilityExpansionsRemainExplicit() {
        XCTAssertEqual(Unicode15_1.nfkc("ﬁ ß ㍿ ㈱"), "fi ß 株式会社 (株)")
        XCTAssertEqual(Unicode15_1.defaultCaseFold("Straße Σςİ"), "strasse σσi̇")
        XCTAssertEqual(Unicode15_1.nfkc("e\u{301}"), "é")
    }

    func test_U23_officialNormalizationTestNFKCConformance() throws {
        var checked = 0
        for line in try fixture("NormalizationTest.txt").components(separatedBy: .newlines) {
            guard let uncommented = line.split(separator: "#", maxSplits: 1).first else { continue }
            let body = uncommented.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, !body.hasPrefix("@") else { continue }
            let columns = body.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 5 else { continue }
            let expected = scalars(columns[3])
            for input in [columns[0], columns[1], columns[2], columns[3], columns[4]] {
                XCTAssertEqual(Unicode15_1.nfkc(string(scalars(input))), string(expected), "NFKC conformance line: \(line)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 90_000)
    }

    func test_U23_officialCaseFoldingConformance() throws {
        var expectedByScalar: [UInt32: [UInt32]] = [:]
        for line in try fixture("CaseFolding.txt").components(separatedBy: .newlines) {
            guard let uncommented = line.split(separator: "#", maxSplits: 1).first else { continue }
            let body = uncommented.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let columns = body.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 3, (columns[1] == "C" || columns[1] == "F"), let source = UInt32(columns[0], radix: 16) else { continue }
            let mapped = scalars(columns[2])
            if columns[1] == "F" || expectedByScalar[source] == nil { expectedByScalar[source] = mapped }
        }
        XCTAssertGreaterThan(expectedByScalar.count, 1_500)
        for (source, expected) in expectedByScalar {
            XCTAssertEqual(Unicode15_1.defaultCaseFold(string([source])), string(expected), "case-fold U+\(String(source, radix: 16))")
        }
    }

    func test_U23_officialWordBreakConformance() throws {
        var checked = 0
        for line in try fixture("WordBreakTest.txt").components(separatedBy: .newlines) {
            let body = String(line.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let parts = body.split(whereSeparator: \.isWhitespace)
            var scalarsUnderTest: [UInt32] = []
            var expected: [Bool] = []
            for part in parts {
                if part == "÷" { expected.append(true) }
                else if part == "×" { expected.append(false) }
                else if let value = UInt32(part, radix: 16) { scalarsUnderTest.append(value) }
            }
            guard expected.count == scalarsUnderTest.count + 1 else { XCTFail("Bad WordBreak fixture line: \(line)"); continue }
            XCTAssertEqual(Unicode15_1.wordBoundaries(in: string(scalarsUnderTest)), expected, "WordBreak conformance line: \(line)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 1_800)
    }

    func test_U23_runtimeBenchmarkIsBelowDraftBudget() {
        // Roughly 425 scalars: larger than a normal live hypothesis while still
        // measuring the latency-sensitive draft path rather than final-only
        // multi-page correction.
        let input = String(repeating: "Saymark ﬁ Straße ㍿ foo-bar ", count: 16)
        let iterations = 500
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<iterations {
                _ = Unicode15_1.nfkcCaseFold(input)
                _ = Unicode15_1.wordBoundaries(in: input)
            }
        }
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
        // Debug XCTest shares a process with AppKit/Contacts services and is not
        // an optimized p95 venue; enforce the SDD's 25 ms hard maximum here.
        // The release performance job owns the 10 ms p95 gate.
        XCTAssertLessThan(milliseconds / Double(iterations), 25, "Unicode core must remain below the draft hard maximum")
    }

    private func fixture(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("UnicodeData/15.1.0/\(name)"), encoding: .utf8)
    }

    private func scalars(_ column: String) -> [UInt32] {
        column.split(whereSeparator: \.isWhitespace).compactMap { UInt32($0, radix: 16) }
    }

    private func string(_ values: [UInt32]) -> String {
        String(String.UnicodeScalarView(values.compactMap(Unicode.Scalar.init)))
    }
}
