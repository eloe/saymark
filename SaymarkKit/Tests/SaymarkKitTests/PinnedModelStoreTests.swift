import CryptoKit
import Foundation
import XCTest
@testable import SaymarkKit

final class PinnedModelStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saymark-pinned-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_catalogPinsImmutableRevisionsAndCriticalArtifacts() {
        let descriptors = [
            SaymarkModelCatalog.nemotron.artifactSet,
            SaymarkModelCatalog.parakeet.artifactSet,
            SaymarkModelCatalog.silero,
        ]

        for descriptor in descriptors {
            XCTAssertEqual(descriptor.revision.count, 40)
            XCTAssertFalse(descriptor.revision.contains("main"))
            XCTAssertTrue(descriptor.artifacts.contains { $0.path == "model.safetensors" })
            XCTAssertTrue(descriptor.artifacts.contains { $0.path == "config.json" })
            XCTAssertTrue(descriptor.artifacts.allSatisfy { $0.sha256.count == 64 })
        }
    }

    func test_verifyAndRecordAcceptsMatchingArtifactsAndWritesManifest() throws {
        let descriptor = try fixtureDescriptor(contents: ["model.safetensors": "weights", "config.json": "{}"])
        try write("weights", to: "model.safetensors")
        try write("{}", to: "config.json")

        XCTAssertEqual(
            try PinnedModelStore.verifyAndRecord(descriptor, at: directory),
            .verifiedByHash
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(PinnedModelStore.manifestName).path
        ))
        XCTAssertEqual(
            try PinnedModelStore.verifyAndRecord(descriptor, at: directory),
            .verifiedByManifest
        )
    }

    func test_verifyAndRecordRejectsChangedArtifact() throws {
        let descriptor = try fixtureDescriptor(contents: ["model.safetensors": "trusted", "config.json": "{}"])
        try write("tampered", to: "model.safetensors")
        try write("{}", to: "config.json")

        XCTAssertThrowsError(try PinnedModelStore.verifyAndRecord(descriptor, at: directory)) {
            guard case PinnedModelStore.Error.hashMismatch("model.safetensors") = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func test_manifestDoesNotAuthorizeChangedFileMetadata() throws {
        let descriptor = try fixtureDescriptor(contents: ["model.safetensors": "trusted", "config.json": "{}"])
        try write("trusted", to: "model.safetensors")
        try write("{}", to: "config.json")
        _ = try PinnedModelStore.verifyAndRecord(descriptor, at: directory)

        try write("changed", to: "model.safetensors")

        XCTAssertThrowsError(try PinnedModelStore.verifyAndRecord(descriptor, at: directory))
    }

    func test_manifestDoesNotAuthorizeSameSizeTamperWithRestoredModificationDate() throws {
        let descriptor = try fixtureDescriptor(contents: [
            "model.safetensors": "trusted",
            "config.json": "{}",
        ])
        try write("trusted", to: "model.safetensors")
        try write("{}", to: "config.json")
        _ = try PinnedModelStore.verifyAndRecord(descriptor, at: directory)

        let artifact = directory.appendingPathComponent("model.safetensors")
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: artifact.path)
        let originalModificationDate = try XCTUnwrap(originalAttributes[.modificationDate] as? Date)
        try write("changed", to: "model.safetensors")
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: artifact.path
        )

        XCTAssertThrowsError(try PinnedModelStore.verifyAndRecord(descriptor, at: directory)) {
            guard case PinnedModelStore.Error.hashMismatch("model.safetensors") = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func test_revisionChangeInvalidatesExistingManifest() throws {
        let descriptor = try fixtureDescriptor(contents: ["model.safetensors": "trusted", "config.json": "{}"])
        try write("trusted", to: "model.safetensors")
        try write("{}", to: "config.json")
        _ = try PinnedModelStore.verifyAndRecord(descriptor, at: directory)

        let changedRevision = PinnedModelArtifactSet(
            repository: descriptor.repository,
            revision: String(repeating: "b", count: 40),
            artifacts: descriptor.artifacts
        )

        XCTAssertEqual(
            try PinnedModelStore.verifyAndRecord(changedRevision, at: directory),
            .verifiedByHash
        )
    }

    private func fixtureDescriptor(contents: [String: String]) throws -> PinnedModelArtifactSet {
        PinnedModelArtifactSet(
            repository: "example/model",
            revision: String(repeating: "a", count: 40),
            artifacts: contents.map { path, contents in
                PinnedModelArtifact(path: path, sha256: sha256(contents))
            }.sorted { $0.path < $1.path }
        )
    }

    private func write(_ contents: String, to path: String) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(path))
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
