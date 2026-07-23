import Foundation
import XCTest
@testable import SaymarkKit

final class DiagnosticLoggingTests: XCTestCase {
    func testConfigurationValuesParseAliasesAndRejectUnknownValues() {
        XCTAssertEqual(SaymarkLogLevel(configurationValue: "TRACE"), .trace)
        XCTAssertEqual(SaymarkLogLevel(configurationValue: " verbose "), .debug)
        XCTAssertEqual(SaymarkLogLevel(configurationValue: "warning"), .warn)
        XCTAssertEqual(SaymarkLogLevel(configurationValue: "none"), .off)
        XCTAssertNil(SaymarkLogLevel(configurationValue: "everything"))
    }

    func testConfiguredThresholdFiltersAndWritesStructuredJSON() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saymark-diagnostics-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("test.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        SaymarkDiagnostics.configure(.init(level: .info, fileURL: file))
        SaymarkDiagnostics.log(.debug, "filtered.event", fields: ["value": 1])
        SaymarkDiagnostics.log(.info, "included.event", sessionID: "session-test", fields: [
            "duration_ms": 12.5,
            "count": 3,
            "success": true,
        ])

        let deadline = Date().addingTimeInterval(2)
        while (!FileManager.default.fileExists(atPath: file.path) ||
               (try? Data(contentsOf: file).isEmpty) != false), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "included.event")
        XCTAssertEqual(object["session_id"] as? String, "session-test")
        XCTAssertEqual(object["duration_ms"] as? Double, 12.5)
        XCTAssertEqual(object["count"] as? Int, 3)
        XCTAssertEqual(object["success"] as? Bool, true)
        XCTAssertNil(lines.first(where: { $0.contains("filtered.event") }))
    }
}
