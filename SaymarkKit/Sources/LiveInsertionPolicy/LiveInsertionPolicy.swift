/// Pure, isolated policy for the planned live-insertion feature.
///
/// This target intentionally has no platform imports and no dependency on the
/// existing injection adapters. It can decide transcript stability, tail limits,
/// stop routing, mutation generations, and privacy-safe metric buckets, but it
/// cannot inspect or modify another application.

public struct HypothesisStabilityPolicy: Equatable, Sendable {
    public static let liveInsertion = Self(
        matchingHypotheses: 2,
        minimumTailAgeMilliseconds: 160,
        maximumTailUTF16Length: 64,
        maximumRevisionDepthWords: 4
    )

    public let matchingHypotheses: Int
    public let minimumTailAgeMilliseconds: Int
    public let maximumTailUTF16Length: Int
    public let maximumRevisionDepthWords: Int

    public init(
        matchingHypotheses: Int,
        minimumTailAgeMilliseconds: Int,
        maximumTailUTF16Length: Int,
        maximumRevisionDepthWords: Int
    ) {
        self.matchingHypotheses = max(1, matchingHypotheses)
        self.minimumTailAgeMilliseconds = max(0, minimumTailAgeMilliseconds)
        self.maximumTailUTF16Length = max(1, maximumTailUTF16Length)
        self.maximumRevisionDepthWords = max(1, maximumRevisionDepthWords)
    }
}

public enum LiveInsertionPhase: Equatable, Sendable {
    case live
    case tailThrottled
    case frozenFinal
}

public struct StableTranscriptUpdate: Equatable, Sendable {
    public let committedPrefix: String
    public let revisableTail: String
    public let hudOnlyTail: String
    public let phase: LiveInsertionPhase

    public var revisionDepthWords: Int {
        revisableTail.split(whereSeparator: \.isWhitespace).count
    }
}

/// Keeps only Saymark-authored hypothesis tokens. If a hypothesis would revise
/// released text, it freezes instead of trying to repair the external field.
public struct StableTranscriptTracker: Sendable {
    private struct Candidate: Equatable, Sendable {
        let token: String
        let firstSeenMilliseconds: Int
        let confirmations: Int
    }

    private let policy: HypothesisStabilityPolicy
    private var committed: [String] = []
    private var candidates: [Candidate] = []
    private var throttled = false

    public init(policy: HypothesisStabilityPolicy = .liveInsertion) {
        self.policy = policy
    }

    public mutating func ingest(_ hypothesis: String, at milliseconds: Int) -> StableTranscriptUpdate {
        let incoming = Self.tokens(from: hypothesis)

        guard Self.starts(with: incoming, prefix: committed) else {
            return StableTranscriptUpdate(
                committedPrefix: committed.joined(separator: " "),
                revisableTail: "",
                hudOnlyTail: "",
                phase: .frozenFinal
            )
        }

        let tailTokens = Array(incoming.dropFirst(committed.count))
        candidates = Self.merge(
            previous: candidates,
            incoming: tailTokens,
            at: milliseconds
        )

        while let first = candidates.first,
              first.confirmations >= policy.matchingHypotheses,
              milliseconds - first.firstSeenMilliseconds >= policy.minimumTailAgeMilliseconds {
            committed.append(first.token)
            candidates.removeFirst()
        }

        let tail = candidates.map(\.token).joined(separator: " ")
        if throttled || tail.utf16.count > policy.maximumTailUTF16Length ||
            candidates.count > policy.maximumRevisionDepthWords {
            throttled = true
            return StableTranscriptUpdate(
                committedPrefix: committed.joined(separator: " "),
                revisableTail: "",
                hudOnlyTail: tail,
                phase: .tailThrottled
            )
        }

        return StableTranscriptUpdate(
            committedPrefix: committed.joined(separator: " "),
            revisableTail: tail,
            hudOnlyTail: "",
            phase: .live
        )
    }

    private static func tokens(from hypothesis: String) -> [String] {
        hypothesis.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func starts(with incoming: [String], prefix: [String]) -> Bool {
        guard incoming.count >= prefix.count else { return false }
        return zip(incoming, prefix).allSatisfy { $0 == $1 }
    }

    private static func merge(
        previous: [Candidate],
        incoming: [String],
        at milliseconds: Int
    ) -> [Candidate] {
        incoming.enumerated().map { index, token in
            guard index < previous.count, previous[index].token == token else {
                return Candidate(token: token, firstSeenMilliseconds: milliseconds, confirmations: 1)
            }
            let candidate = previous[index]
            return Candidate(
                token: token,
                firstSeenMilliseconds: candidate.firstSeenMilliseconds,
                confirmations: candidate.confirmations + 1
            )
        }
    }
}

public enum LiveInsertionStopRoute: Equatable, Sendable {
    case settleOwnedTail
    case frozenFinal
    case fallbackFinal
}

public enum LiveInsertionStopRouter {
    /// A written tail can settle only with a current ownership proof. Without a
    /// tail, fallback final is safe because no provisional field text exists.
    public static func route(
        hasWrittenTail: Bool,
        ownershipVerified: Bool
    ) -> LiveInsertionStopRoute {
        if hasWrittenTail {
            return ownershipVerified ? .settleOwnedTail : .frozenFinal
        }
        return .fallbackFinal
    }
}

public struct MutationToken: Equatable, Sendable {
    fileprivate let generation: UInt64
    fileprivate let serial: UInt64
}

/// Enforces one operation in flight and makes completion invalid after a stop,
/// focus loss, secure transition, restart, or other generation invalidation.
public struct MutationGenerationGate: Sendable {
    private var generation: UInt64 = 0
    private var nextSerial: UInt64 = 0
    private var inFlight: MutationToken?

    public init() {}

    public mutating func beginMutation() -> MutationToken? {
        guard inFlight == nil else { return nil }
        nextSerial &+= 1
        let token = MutationToken(generation: generation, serial: nextSerial)
        inFlight = token
        return token
    }

    public mutating func invalidate() {
        generation &+= 1
        inFlight = nil
    }

    public mutating func complete(_ token: MutationToken) -> Bool {
        guard token.generation == generation, inFlight == token else { return false }
        inFlight = nil
        return true
    }
}

public enum DeliveryPolicy: Sendable {
    case efficient
    case hudOnly
    case atomicFinal
    case protected
    case verifiedLive

    public var mayIssueExternalMutation: Bool {
        self == .verifiedLive
    }
}

public enum CountBucket: String, Equatable, Sendable {
    case zero
    case oneToFour
    case fiveToSixteen
    case seventeenToSixtyFour
    case sixtyFiveToOneTwentyEight
    case overOneTwentyEight

    public static func bucket(for count: Int) -> Self {
        switch max(0, count) {
        case 0: return .zero
        case 1 ... 4: return .oneToFour
        case 5 ... 16: return .fiveToSixteen
        case 17 ... 64: return .seventeenToSixtyFour
        case 65 ... 128: return .sixtyFiveToOneTwentyEight
        default: return .overOneTwentyEight
        }
    }
}

public enum LiveInsertionTelemetryOutcome: String, Equatable, Sendable {
    case published
    case tailThrottled
    case frozen
    case fallback
}

/// A closed telemetry payload. It deliberately has no target name, bundle ID,
/// free-form reason, exact count, or text-bearing field.
public struct LiveInsertionTelemetry: Equatable, Sendable {
    public let outcome: LiveInsertionTelemetryOutcome
    public let tailLength: CountBucket
    public let revisionDepth: CountBucket

    public init(
        outcome: LiveInsertionTelemetryOutcome,
        tailLength: CountBucket,
        revisionDepth: CountBucket
    ) {
        self.outcome = outcome
        self.tailLength = tailLength
        self.revisionDepth = revisionDepth
    }
}
