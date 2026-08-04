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
        let sessionID = UUID().uuidString
        SaymarkDiagnostics.log(.info, "included.event", sessionID: sessionID, fields: [
            "capture_start_ms": 42.25,
            "duration_ms": 12.5,
            "count": 3,
            "hud_latency_ms": 9.75,
            "insert_mode": "inField",
            "outcome": "pasted",
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
        XCTAssertEqual(object["session_id"] as? String, sessionID)
        XCTAssertEqual(object["duration_ms"] as? Double, 12.5)
        XCTAssertEqual(object["capture_start_ms"] as? Double, 42.25)
        XCTAssertEqual(object["count"] as? Int, 3)
        XCTAssertEqual(object["hud_latency_ms"] as? Double, 9.75)
        XCTAssertEqual(object["insert_mode"] as? String, "inField")
        XCTAssertEqual(object["outcome"] as? String, "pasted")
        XCTAssertEqual(object["success"] as? Bool, true)
        XCTAssertNil(lines.first(where: { $0.contains("filtered.event") }))
    }

    func testLoggerBoundaryDropsContentBearingAndUnknownFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saymark-diagnostics-privacy-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("test.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        SaymarkDiagnostics.configure(.init(level: .info, fileURL: file))
        SaymarkDiagnostics.log(.info, "privacy.boundary", fields: [
            "duration_ms": 8.5,
            "transcript": "private words",
            "audio_data": "private samples",
            "clipboard_contents": "private clipboard",
            "focused_text": "private application content",
            "customer_payload": "arbitrary private content",
            "error_description": "/Users/private/secret-model-path",
        ])

        let deadline = Date().addingTimeInterval(2)
        while (!FileManager.default.fileExists(atPath: file.path) ||
               (try? Data(contentsOf: file).isEmpty) != false), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        let line = try XCTUnwrap(
            try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                .last
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["duration_ms"] as? Double, 8.5)
        for key in [
            "transcript",
            "audio_data",
            "clipboard_contents",
            "focused_text",
            "customer_payload",
            "error_description",
        ] {
            XCTAssertNil(object[key], "\(key) crossed the diagnostic privacy boundary")
        }
    }

    func testLoggerRejectsArbitraryStringsUnderPermittedDiagnosticKeys() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saymark-diagnostics-closed-values-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("test.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        SaymarkDiagnostics.configure(.init(level: .info, fileURL: file))
        SaymarkDiagnostics.log(.info, "privacy.closed-values", fields: [
            "reason": "my private dictated sentence",
            "destination": "/Applications/Private.app",
            "state": "search: private words",
            "duration_ms": 1,
        ])
        let deadline = Date().addingTimeInterval(2)
        while (!FileManager.default.fileExists(atPath: file.path) ||
               (try? Data(contentsOf: file).isEmpty) != false), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let line = try XCTUnwrap(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["duration_ms"] as? Int, 1)
        XCTAssertNil(object["reason"])
        XCTAssertNil(object["destination"])
        XCTAssertNil(object["state"])
    }

    func testHistoryDiagnosticsAcceptOnlyLiteralEventAndClosedBoundedValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saymark-history-diagnostics-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("test.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }

        SaymarkDiagnostics.configure(.init(level: .info, fileURL: file))
        SaymarkDiagnostics.logHistoryOperation(
            .query,
            outcome: .success,
            retention: .days30,
            resultCount: 999,
            durationMilliseconds: 80_000
        )
        SaymarkDiagnostics.logHistoryOperation(.insert, outcome: .recordLimitReached)
        SaymarkDiagnostics.log(.info, "history.query.private words", fields: [
            "history_operation": "query",
            "history_outcome": "success",
        ])
        SaymarkDiagnostics.log(.info, "history.operation", fields: [
            "history_operation": "query",
            "history_outcome": "private transcript",
            "history_retention": "/Users/private",
        ])

        let deadline = Date().addingTimeInterval(2)
        while (!FileManager.default.fileExists(atPath: file.path) ||
               (try? Data(contentsOf: file).isEmpty) != false), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "history.operation")
        XCTAssertEqual(object["history_operation"] as? String, "query")
        XCTAssertEqual(object["history_outcome"] as? String, "success")
        XCTAssertEqual(object["history_retention"] as? String, "days_30")
        XCTAssertEqual(object["history_result_count"] as? Int, 25)
        XCTAssertEqual(object["history_duration_ms"] as? Int, 60_000)
        XCTAssertFalse(lines[0].contains("private"))
        let capObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        )
        XCTAssertEqual(capObject["event"] as? String, "history.operation")
        XCTAssertEqual(capObject["history_operation"] as? String, "insert")
        XCTAssertEqual(capObject["history_outcome"] as? String, "record_limit_reached")
        for forbidden in ["transcript", "record_id", "path", "search", "destination", "error"] {
            XCTAssertNil(capObject[forbidden])
        }
    }
}
