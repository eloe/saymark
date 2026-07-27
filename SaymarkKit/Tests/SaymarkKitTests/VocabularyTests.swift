import XCTest
@testable import SaymarkKit
import Darwin

private final class StubCorrectionSession: UtteranceSession {
    var raw = (confirmed: "", partial: "say mark draft")
    func step(_ samples: [Float], shouldProcess: Bool) -> (confirmed: String, partial: String) { raw }
    var currentText: (confirmed: String, partial: String) { raw }
    func finishText() -> String { "say mark final" }
}

final class VocabularyTests: XCTestCase {
    private enum SyntheticFailure: Error { case failed }
    private func snapshot(_ entries: [VocabularyEntry]) throws -> VocabularySnapshot {
        try VocabularySnapshot(document: VocabularyDocument(revision: 7, entries: entries))
    }

    func test_U01_emptyRulesPreserveRawText() throws {
        let result = try snapshot([]).correct("plain raw text")
        XCTAssertEqual(result.rawText, result.renderedText)
        XCTAssertEqual(result.appliedRuleCount, 0)
    }

    func test_U02_completeAliasUsesExactWrittenOutput() throws {
        let entry = VocabularyEntry(written: "Saymark", heard: ["say mark", "sagemark"])
        XCTAssertEqual(try snapshot([entry]).correct("say mark chose sagemark").renderedText, "Saymark chose Saymark")
    }

    func test_U03_U23_nfkcAndExpansionAreAtomic() throws {
        let ligature = VocabularyEntry(written: "FI", heard: ["fi"])
        XCTAssertEqual(try snapshot([ligature]).correct("ﬁ").renderedText, "FI")
        let angstrom = VocabularyEntry(written: "Å", heard: ["å"])
        XCTAssertEqual(try snapshot([angstrom]).correct("A\u{030A}").renderedText, "Å")
        let hangul = VocabularyEntry(written: "가", heard: ["가"])
        XCTAssertEqual(try snapshot([hangul]).correct("\u{1100}\u{1161}").renderedText, "가")
        let stock = VocabularyEntry(written: "stock", heard: ["株"])
        XCTAssertEqual(try snapshot([stock]).correct("㈱").renderedText, "㈱")
        let company = VocabularyEntry(written: "company", heard: ["株式会社"])
        XCTAssertEqual(try snapshot([company]).correct("㍿").renderedText, "company")
        XCTAssertEqual(try snapshot([stock]).correct("㍿").renderedText, "㍿")
        let cafe = VocabularyEntry(written: "Café", heard: ["café"])
        XCTAssertEqual(try snapshot([cafe]).correct("cafe\u{301}").renderedText, "Café")
    }

    func test_U05_U08_boundariesLongestAndNoCascade() throws {
        let cat = VocabularyEntry(written: "Cat", heard: ["cat"])
        let short = VocabularyEntry(written: "X", heard: ["foo"])
        let long = VocabularyEntry(written: "Y", heard: ["foo bar"])
        let cascade = VocabularyEntry(written: "bar", heard: ["zip"])
        let next = VocabularyEntry(written: "baz", heard: ["bar"])
        let rules = try snapshot([cat, short, long, cascade, next])
        XCTAssertEqual(rules.correct("catalog foo bar zip").renderedText, "catalog Y bar")
    }

    func test_U11_duplicateEnabledCanonicalAliasIsRejected() throws {
        let first = VocabularyEntry(written: "One", heard: ["Foo"])
        let second = VocabularyEntry(written: "Two", heard: ["foo"])
        XCTAssertThrowsError(try snapshot([first, second]))
    }

    func test_U12_disabledConflictDoesNotApplyButCannotBeEnabled() throws {
        let enabled = VocabularyEntry(written: "One", heard: ["foo"])
        let disabled = VocabularyEntry(written: "Two", heard: ["Foo"], enabled: false)
        XCTAssertEqual(try snapshot([enabled, disabled]).correct("foo").renderedText, "One")
        var enabledAgain = disabled; enabledAgain.enabled = true
        XCTAssertThrowsError(try snapshot([enabled, enabledAgain]))
    }

    func test_U15_snapshotIsolation() throws {
        let old = try snapshot([VocabularyEntry(written: "One", heard: ["one"])])
        let newer = try snapshot([VocabularyEntry(written: "Two", heard: ["one"])])
        XCTAssertEqual(old.correct("one").renderedText, "One")
        XCTAssertEqual(newer.correct("one").renderedText, "Two")
    }

    func test_U25_unsafeUnicodeIsRejected() {
        XCTAssertThrowsError(try VocabularyValidator.validate(VocabularyEntry(written: "safe", heard: ["bad\u{202E}text"])))
        XCTAssertThrowsError(try VocabularyValidator.validate(VocabularyEntry(written: "safe", heard: ["bad\u{FE0F}text"])))
        XCTAssertTrue(Unicode15_1.isUnsafeVocabularyScalar(0xFDD0))
        XCTAssertTrue(Unicode15_1.isUnsafeVocabularyScalar(0x0378))
    }

    func test_U17_U18_storeImportIsPreviewedAndTransactional() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VocabularyStore(directoryURL: directory)
        let original = VocabularyEntry(written: "Original", heard: ["one"])
        try store.upsert(original)
        var changed = original; changed.written = "Updated"
        let importURL = directory.appendingPathComponent("import.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(VocabularyDocument(entries: [changed]))
        try data.write(to: importURL)
        let preview = try store.importDocument(from: importURL, strategy: .mergeByID)
        XCTAssertEqual(preview.updatedCount, 1)
        XCTAssertEqual(store.currentDocument().entries.first?.written, "Original")
        try store.applyImport(from: importURL, strategy: .mergeByID, acknowledgedURLs: false, previewToken: preview.sourceToken)
        XCTAssertEqual(store.currentDocument().entries.first?.written, "Updated")
    }

    func test_S09_duplicateKeysAndChangedImportAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VocabularyStore(directoryURL: directory)
        let duplicate = directory.appendingPathComponent("duplicate.json")
        try #"{"schemaVersion":1,"schemaVersion":1,"unicodeVersion":"15.1.0","revision":0,"entries":[]}"#.data(using: .utf8)!.write(to: duplicate)
        XCTAssertThrowsError(try store.importDocument(from: duplicate, strategy: .mergeByID))
        try #"{"schemaVersion":1,"schema\u0056ersion":1,"unicodeVersion":"15.1.0","revision":0,"entries":[]}"#.data(using: .utf8)!.write(to: duplicate)
        XCTAssertThrowsError(try store.importDocument(from: duplicate, strategy: .mergeByID))

        let entry = VocabularyEntry(written: "One", heard: ["one"])
        let changing = directory.appendingPathComponent("changing.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(VocabularyDocument(entries: [entry])).write(to: changing)
        let preview = try store.importDocument(from: changing, strategy: .mergeByID)
        var replacement = entry; replacement.written = "Two"
        try encoder.encode(VocabularyDocument(entries: [replacement])).write(to: changing)
        XCTAssertThrowsError(try store.applyImport(from: changing, strategy: .mergeByID, acknowledgedURLs: false, previewToken: preview.sourceToken))
    }

    func test_S10_backupRecoveryAndV1Migration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VocabularyStore(directoryURL: directory)
        try store.upsert(VocabularyEntry(written: "First", heard: ["first"]))
        try store.upsert(VocabularyEntry(written: "Second", heard: ["second"]))
        let primary = directory.appendingPathComponent(VocabularyStore.defaultFilename)
        try Data("corrupt".utf8).write(to: primary)
        let recovered = try VocabularyStore(directoryURL: directory)
        XCTAssertEqual(recovered.currentDocument().entries.map(\.written), ["First"])
        XCTAssertNotNil(recovered.recoveryMessage)

        // Simulate a crash after primary->backup but before temp->primary.
        try FileManager.default.removeItem(at: primary)
        let backupOnly = try VocabularyStore(directoryURL: directory)
        XCTAssertEqual(backupOnly.currentDocument().entries.map(\.written), ["First"])
        XCTAssertNotNil(backupOnly.recoveryMessage)
        try backupOnly.upsert(VocabularyEntry(written: "Recovered save", heard: ["recovered save"]))
        let backup = directory.appendingPathComponent(VocabularyStore.defaultFilename + ".backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        // A crash immediately after the new primary disappears must still
        // leave the prior complete backup recoverable.
        try FileManager.default.removeItem(at: primary)
        let recoveredAgain = try VocabularyStore(directoryURL: directory)
        XCTAssertEqual(recoveredAgain.currentDocument().entries.map(\.written), ["First"])

        let v1 = directory.appendingPathComponent("v1.json")
        let encoded = #"{"schemaVersion":1,"unicodeVersion":"15.1.0","revision":0,"entries":[]}"#
        try Data(encoded.utf8).write(to: v1)
        XCTAssertEqual(try recovered.importDocument(from: v1, strategy: .mergeByID).sourceToken.count, 64)
    }

    func test_S04_mailtoAndCustomSchemesRequireImportAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VocabularyStore(directoryURL: directory)
        let file = directory.appendingPathComponent("url.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let entry = VocabularyEntry(written: "mailto:security@example.com", heard: ["security mail"])
        try encoder.encode(VocabularyDocument(entries: [entry])).write(to: file)
        let preview = try store.importDocument(from: file, strategy: .mergeByID)
        XCTAssertTrue(preview.containsURL)
        XCTAssertTrue(try XCTUnwrap(preview.diffs.first).containsURL)
        XCTAssertThrowsError(try store.applyImport(from: file, strategy: .mergeByID, acknowledgedURLs: false, previewToken: preview.sourceToken))
    }

    func test_U18_mergeConflictIsPreviewedBeforeApplyIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VocabularyStore(directoryURL: directory)
        try store.upsert(VocabularyEntry(written: "Local", heard: ["say mark"]))

        let imported = VocabularyEntry(written: "Imported", heard: ["Say Mark"])
        let file = directory.appendingPathComponent("conflict.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(VocabularyDocument(entries: [imported])).write(to: file)

        let preview = try store.importDocument(from: file, strategy: .mergeByID)
        XCTAssertEqual(preview.conflictCount, 1)
        XCTAssertEqual(preview.conflicts.first?.canonicalTrigger, "say mark")
        XCTAssertEqual(
            Set(try XCTUnwrap(preview.conflicts.first).entryIDs),
            Set([store.currentDocument().entries[0].id, imported.id])
        )
        XCTAssertEqual(preview.newCount, 1)
        XCTAssertThrowsError(
            try store.applyImport(
                from: file,
                strategy: .mergeByID,
                acknowledgedURLs: false,
                previewToken: preview.sourceToken
            )
        )
    }

    func test_S09_importReaderRejectsMoreThanFiveMiB() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VocabularyStore(directoryURL: directory)
        let oversized = directory.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: 5 * 1024 * 1024 + 1).write(to: oversized)
        XCTAssertThrowsError(try store.importDocument(from: oversized, strategy: .mergeByID))
    }

    func test_P04_maximumRulesHaveBoundedDraftCorrection() throws {
        let entries = (0..<VocabularyValidator.maxEntries).map { number in
            VocabularyEntry(written: "written\(number)", heard: ["phrase \(number)"])
        }
        let rules = try snapshot(entries)
        let text = (0..<100).map { "phrase \($0)" }.joined(separator: " ")
        let started = ProcessInfo.processInfo.systemUptime
        _ = rules.correct(text)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.025)
    }

    func test_S07_correctionDiagnosticsAreLocalConsentOnlyAndAggregate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("correction.jsonl")
        let diagnostics = CorrectionDiagnostics(fileURL: file, consent: CorrectionDiagnosticsConsent(allowsLocalAggregation: true))
        for _ in 0..<100 { diagnostics.record(CorrectedTranscript(rawText: "secret", renderedText: "secret", snapshotRevision: 1, appliedRuleCount: 1)) }
        let line = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(line, "{\"schema\":1,\"correction_bucket\":\"10+\"}\n")
        XCTAssertFalse(line.contains("secret"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o600)
    }

    func test_I12_latestWinsBacklogAndFinalPriority() throws {
        let snapshot = try snapshot([VocabularyEntry(written: "Saymark", heard: ["say mark"])])
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let pipeline = TranscriptCorrectionPipeline(snapshot: snapshot) { raw in
            if raw == "draft one" { started.signal(); release.wait() }
            return snapshot.correct(raw)
        }
        let noOldDraft = expectation(description: "superseded drafts"); noOldDraft.isInverted = true
        pipeline.submitDraft("draft one") { _ in noOldDraft.fulfill() }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        pipeline.submitDraft("draft two") { _ in noOldDraft.fulfill() }
        let latest = expectation(description: "latest")
        pipeline.submitDraft("say mark three") { XCTAssertEqual($0.renderedText, "Saymark three"); latest.fulfill() }
        release.signal()
        wait(for: [latest, noOldDraft], timeout: 1)

        let cancelledByFinal = expectation(description: "draft cancelled by final"); cancelledByFinal.isInverted = true
        pipeline.submitDraft("draft one") { _ in cancelledByFinal.fulfill() }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        let final = pipeline.correctFinal("say mark final")
        XCTAssertEqual(final.renderedText, "Saymark final")
        release.signal()
        wait(for: [cancelledByFinal], timeout: 0.1)
    }

    func test_I13_correctionFailureFallsBackToRawWithStatusAndRevision() throws {
        let snapshot = try snapshot([VocabularyEntry(written: "Saymark", heard: ["say mark"])])
        let pipeline = TranscriptCorrectionPipeline(snapshot: snapshot) { _ in throw SyntheticFailure.failed }
        let result = pipeline.correctFinal("raw final")
        XCTAssertEqual(result.rawText, "raw final")
        XCTAssertEqual(result.renderedText, "raw final")
        XCTAssertEqual(result.snapshotRevision, 7)
        XCTAssertEqual(result.correctionStatus, .failedRawFallback)
    }

    func test_I01_actualUtteranceRuntimeUsesAsyncWholeHypothesisPipeline() throws {
        let base = StubCorrectionSession()
        let delivered = expectation(description: "completion-driven correction")
        let session = CorrectingUtteranceSession(
            base: base,
            snapshot: try snapshot([VocabularyEntry(written: "Saymark", heard: ["say mark"])]),
            onDraftCorrection: { _, partial in
                XCTAssertEqual(partial.renderedText, "Saymark draft")
                delivered.fulfill()
            }
        )
        let immediate = session.step([], shouldProcess: true)
        XCTAssertEqual(immediate.partial, "say mark draft") // STT queue returns without correcting.
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(session.latestUpdate.partial.renderedText, "Saymark draft")
        XCTAssertEqual(session.latestUpdate.partial.rawText, "say mark draft")
        XCTAssertEqual(session.finishText(), "Saymark final")
        XCTAssertEqual(session.latestUpdate.confirmed.snapshotRevision, 7)
    }

    func test_S08_storeAndExportAre0600() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try VocabularyStore(directoryURL: directory)
        try store.upsert(VocabularyEntry(written: "Saymark", heard: ["say mark"]))
        let primary = directory.appendingPathComponent(VocabularyStore.defaultFilename)
        let export = directory.appendingPathComponent("export.json")
        try store.export(to: export)
        let primaryMode = try FileManager.default.attributesOfItem(atPath: primary.path)[.posixPermissions] as? NSNumber
        let exportMode = try FileManager.default.attributesOfItem(atPath: export.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((primaryMode?.intValue ?? 0) & 0o777, 0o600)
        XCTAssertEqual((exportMode?.intValue ?? 0) & 0o777, 0o600)
    }

    func test_S10_futureSchemaNeverFallsBackOrPermitsMutationAndExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try VocabularyStore(directoryURL: directory)
        try original.upsert(VocabularyEntry(written: "Backup", heard: ["backup"]))
        try original.upsert(VocabularyEntry(written: "Primary", heard: ["primary"]))

        let primary = directory.appendingPathComponent(VocabularyStore.defaultFilename)
        let future = #"{"schemaVersion":999,"future":{"records":[{"opaque":true}]},"unknownBytes":"preserve-me"}"#
        let futureData = Data(future.utf8)
        try futureData.write(to: primary)

        let opened = try VocabularyStore(directoryURL: directory)
        XCTAssertNotNil(opened.readOnlyReason)
        XCTAssertTrue(opened.currentDocument().entries.isEmpty)
        XCTAssertThrowsError(try opened.upsert(VocabularyEntry(written: "No", heard: ["no"])))
        let export = directory.appendingPathComponent("future-export.json")
        try opened.export(to: export)
        XCTAssertEqual(try Data(contentsOf: export), futureData)
        XCTAssertEqual(try Data(contentsOf: primary), futureData)
    }

    func test_S10_recoverySaveNeverRotatesKnownGoodBackupAcrossInjectedCrashes() throws {
        for checkpoint in [
            VocabularyStore.PersistenceCheckpoint.temporaryDurable,
            .beforePrimaryInstall,
            .primaryInstalled,
        ] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let seeded = try VocabularyStore(directoryURL: directory)
            try seeded.upsert(VocabularyEntry(written: "First", heard: ["first"]))
            try seeded.upsert(VocabularyEntry(written: "Second", heard: ["second"]))

            let primary = directory.appendingPathComponent(VocabularyStore.defaultFilename)
            let backup = directory.appendingPathComponent(VocabularyStore.defaultFilename + ".backup")
            let knownGoodBackup = try Data(contentsOf: backup)
            try Data("corrupt-primary".utf8).write(to: primary)

            let recovered = try VocabularyStore(
                directoryURL: directory,
                persistenceFaultInjector: { reached in
                    if reached == checkpoint { throw SyntheticFailure.failed }
                }
            )
            XCTAssertEqual(recovered.currentDocument().entries.map(\.written), ["First"])
            XCTAssertThrowsError(
                try recovered.upsert(VocabularyEntry(written: "Third", heard: ["third"]))
            )
            XCTAssertEqual(
                try Data(contentsOf: backup),
                knownGoodBackup,
                "Recovery save rotated the known-good backup at \(checkpoint)"
            )

            let reopened = try VocabularyStore(directoryURL: directory)
            let expected = checkpoint == .primaryInstalled
                ? ["First", "Third"]
                : ["First"]
            XCTAssertEqual(reopened.currentDocument().entries.map(\.written), expected)
        }
    }
}
