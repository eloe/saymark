import XCTest
@testable import SaymarkKit

final class VocabularyTests: XCTestCase {
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
        let stock = VocabularyEntry(written: "stock", heard: ["株"])
        XCTAssertEqual(try snapshot([stock]).correct("㈱").renderedText, "㈱")
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
        try store.applyImport(from: importURL, strategy: .mergeByID, acknowledgedURLs: false)
        XCTAssertEqual(store.currentDocument().entries.first?.written, "Updated")
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
}
