import CryptoKit
import Foundation
import HuggingFace

/// Owns the trust boundary between mutable Hugging Face repositories and model
/// bytes loaded into the process. Every production model is fetched by immutable
/// commit and its critical files are hashed before MLX can load them.
public actor PinnedModelStore {
    public static let shared = PinnedModelStore()
    static let manifestName = ".saymark-verified-model.json"
    private var processVerifiedDirectories: Set<String> = []

    enum VerificationResult: Equatable {
        case verifiedByManifest
        case verifiedByHash
    }

    public enum Error: Swift.Error, Equatable {
        case badRepository(String)
        case missingArtifact(String)
        case hashMismatch(String)
        case unreadableArtifact(String)
    }

    private struct VerifiedFile: Codable, Equatable {
        let path: String
        let size: UInt64
        let modifiedAt: TimeInterval
    }

    private struct Manifest: Codable, Equatable {
        let repository: String
        let revision: String
        let artifacts: [PinnedModelArtifact]
        let verifiedFiles: [VerifiedFile]
    }

    public func ensure(
        _ descriptor: PinnedModelArtifactSet,
        cache: HubCache = .default,
        progressHandler: (@MainActor @Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        guard let repository = Repo.ID(rawValue: descriptor.repository) else {
            throw Error.badRepository(descriptor.repository)
        }
        let destination = Self.modelDirectory(for: descriptor.repository, cache: cache)
        let processVerificationKey = [
            destination.standardizedFileURL.path,
            descriptor.repository,
            descriptor.revision,
        ].joined(separator: "\u{0}")

        // A production model is loaded at most once per process. Onboarding may
        // ask for the same verified snapshot again while handing off from
        // download to model preparation; reuse this actor-owned attestation
        // instead of rereading multi-gigabyte weights in the same process.
        if processVerifiedDirectories.contains(processVerificationKey) {
            return destination
        }

        if FileManager.default.fileExists(atPath: destination.path),
           let verification = try? Self.verifyAndRecord(descriptor, at: destination) {
            processVerifiedDirectories.insert(processVerificationKey)
            Self.logVerification(verification, descriptor: descriptor, source: "cache")
            return destination
        }

        try? FileManager.default.removeItem(at: destination)
        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(
            at: staging.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let client = HubClient(cache: cache)
        _ = try await client.downloadSnapshot(
            of: repository,
            kind: .model,
            to: staging,
            revision: descriptor.revision,
            matching: ["*.safetensors", "*.json", "*.txt"],
            progressHandler: progressHandler
        )
        let verification = try Self.verifyAndRecord(descriptor, at: staging)
        Self.logVerification(verification, descriptor: descriptor, source: "download")
        try FileManager.default.moveItem(at: staging, to: destination)
        processVerifiedDirectories.insert(processVerificationKey)
        return destination
    }

    static func modelDirectory(for repository: String, cache: HubCache = .default) -> URL {
        cache.cacheDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(repository.replacingOccurrences(of: "/", with: "_"))
    }

    @discardableResult
    static func verifyAndRecord(
        _ descriptor: PinnedModelArtifactSet,
        at directory: URL
    ) throws -> VerificationResult {
        let manifestURL = directory.appendingPathComponent(manifestName)
        let currentFiles = try descriptor.artifacts.map {
            try metadata(for: $0.path, in: directory)
        }

        for artifact in descriptor.artifacts {
            let url = directory.appendingPathComponent(artifact.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Error.missingArtifact(artifact.path)
            }
            guard let actual = try? sha256(of: url) else {
                throw Error.unreadableArtifact(artifact.path)
            }
            guard actual == artifact.sha256.lowercased() else {
                throw Error.hashMismatch(artifact.path)
            }
        }

        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
           manifest.repository == descriptor.repository,
           manifest.revision == descriptor.revision,
           manifest.artifacts == descriptor.artifacts,
           manifest.verifiedFiles == currentFiles {
            return .verifiedByManifest
        }

        let manifest = Manifest(
            repository: descriptor.repository,
            revision: descriptor.revision,
            artifacts: descriptor.artifacts,
            verifiedFiles: currentFiles
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        return .verifiedByHash
    }

    private static func metadata(for path: String, in directory: URL) throws -> VerifiedFile {
        let url = directory.appendingPathComponent(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw Error.missingArtifact(path)
        }
        return VerifiedFile(
            path: path,
            size: size.uint64Value,
            modifiedAt: modified.timeIntervalSince1970
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 4 * 1024 * 1024),
                  !data.isEmpty else {
                break
            }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func logVerification(
        _ result: VerificationResult,
        descriptor: PinnedModelArtifactSet,
        source: String
    ) {
        SaymarkDiagnostics.log(.info, "model.artifact_verified", fields: [
            "repository": descriptor.repository,
            "revision": descriptor.revision,
            "source": source,
            "verification": result == .verifiedByHash ? "sha256" : "manifest",
        ])
    }
}
