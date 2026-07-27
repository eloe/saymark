/// Pure, isolated policy for the planned live-insertion feature.
///
/// This target deliberately has no platform imports and cannot inspect or
/// mutate another application.  It models the failure-closed decisions that a
/// future, separately evidenced coordinator would have to obey.

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

/// All strings in this value are exact slices/recombinations of a hypothesis.
/// In particular, whitespace, punctuation, Unicode scalars, and UTF-16 length
/// are never normalised by policy code.
public struct StableTranscriptUpdate: Equatable, Sendable {
    /// Text explicitly acknowledged as current-generation field state.
    public let committedPrefix: String
    /// Stable, but not yet mutation-acknowledged, text. It is never considered
    /// committed merely because a recogniser repeated it.
    public let stableCandidatePrefix: String
    /// The only text a future coordinator could consider revisable.
    public let revisableTail: String
    /// Later hypothesis content after field state is frozen by throttling.
    public let hudOnlyTail: String
    public let phase: LiveInsertionPhase

    public var revisionDepthWords: Int {
        revisableTail.split(whereSeparator: \.isWhitespace).count
    }
}

public struct MutationToken: Equatable, Sendable {
    fileprivate let generation: UInt64
    fileprivate let serial: UInt64
}

/// One in-flight operation, invalidated by every ownership-relevant event.
/// Counters never wrap: exhaustion retires the gate rather than accepting a
/// theoretically stale token after a UInt64 rollover.
public struct MutationGenerationGate: Sendable {
    private var generation: UInt64 = 0
    private var nextSerial: UInt64 = 0
    private var inFlight: MutationToken?
    private var retired = false

    public init() {}

    /// Test-only construction for exhaustion schedules. This is intentionally
    /// internal: production callers cannot select counter values.
    init(nextSerialForTesting nextSerial: UInt64) {
        self.nextSerial = nextSerial
    }

    public mutating func beginMutation() -> MutationToken? {
        guard !retired, inFlight == nil, nextSerial < UInt64.max else { return nil }
        nextSerial += 1
        let token = MutationToken(generation: generation, serial: nextSerial)
        inFlight = token
        return token
    }

    public mutating func invalidate() {
        inFlight = nil
        guard generation < UInt64.max else {
            retired = true
            return
        }
        generation += 1
    }

    public mutating func complete(_ token: MutationToken) -> Bool {
        guard !retired, token.generation == generation, inFlight == token else { return false }
        inFlight = nil
        return true
    }

    fileprivate var hasInFlight: Bool { inFlight != nil }
}

public struct StableMutationRequest: Sendable, Equatable {
    /// The exact field prefix a future coordinator must acknowledge after a
    /// current-generation operation. It is not an authority to mutate.
    public let candidatePrefix: String
    /// The exact bounded UTF-16 tail expected to be present when the future
    /// coordinator acknowledges this operation.  It is deliberately captured
    /// with the request so a caller cannot later substitute arbitrary field
    /// content into the throttling snapshot.
    public let expectedTail: String
    fileprivate let token: MutationToken

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.token == rhs.token &&
            exactUTF16Equal(lhs.candidatePrefix, rhs.candidatePrefix) &&
            exactUTF16Equal(lhs.expectedTail, rhs.expectedTail)
    }

    /// This receipt is opaque outside the policy module.  A future coordinator
    /// may only acknowledge the exact candidate and tail it was issued; it
    /// cannot construct an acknowledgement for arbitrary observed text.
    public var receipt: MutationReceipt {
        receipt(observedTail: expectedTail)
    }

    /// Models the exact tail read back by a future coordinator. The policy
    /// accepts it only when it is byte-for-byte the expected bounded tail.
    public func receipt(observedTail: String) -> MutationReceipt {
        MutationReceipt(candidatePrefix: candidatePrefix, expectedTail: observedTail, token: token)
    }
}

/// Opaque proof that a particular bounded mutation request was acknowledged.
/// It carries no authority to mutate another application.
public struct MutationReceipt: Sendable, Equatable {
    public let candidatePrefix: String
    public let expectedTail: String
    fileprivate let token: MutationToken

    fileprivate init(candidatePrefix: String, expectedTail: String, token: MutationToken) {
        self.candidatePrefix = candidatePrefix
        self.expectedTail = expectedTail
        self.token = token
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.token == rhs.token &&
            exactUTF16Equal(lhs.candidatePrefix, rhs.candidatePrefix) &&
            exactUTF16Equal(lhs.expectedTail, rhs.expectedTail)
    }
}

/// Keeps exact hypothesis fragments. Whitespace and non-whitespace runs are
/// separate fragments, so separator migration can extend an acknowledged prefix
/// without turning it into a canonicalized replacement. The representation
/// preserves the original text at the Swift String / UTF-16 boundary while
/// keeping word limits clear.
public struct StableTranscriptTracker: Sendable {
    private struct Fragment: Equatable, Sendable {
        let text: String
        let firstSeenMilliseconds: Int
        let confirmations: Int
    }

    private enum State: Sendable {
        case live
        case throttled(committed: String, tail: String)
        case frozen(committed: String, tail: String)
    }

    private let policy: HypothesisStabilityPolicy
    private var committed: [String] = []
    private var stableCandidates: [String] = []
    private var candidates: [Fragment] = []
    private var gate = MutationGenerationGate()
    private var fieldResidentTail = ""
    private var state: State = .live
    private var lastMonotonicMilliseconds = 0

    public init(policy: HypothesisStabilityPolicy = .liveInsertion) {
        self.policy = policy
    }

    /// Ingests a recogniser hypothesis. A decreasing clock reading is clamped
    /// to the most recent value, so time rollback cannot prematurely stabilise
    /// content or make age arithmetic overflow.
    public mutating func ingest(_ hypothesis: String, at milliseconds: Int) -> StableTranscriptUpdate {
        let now = monotonic(milliseconds)
        // Any newer recogniser observation retires a not-yet-acknowledged
        // request, even if the text happens to be equal. The receipt is a
        // proof for one generation, not a reusable permission.
        if gate.hasInFlight { gate.invalidate() }
        switch state {
        case let .throttled(fieldCommitted, fieldTail):
            return update(
                committed: fieldCommitted,
                stable: fieldCommitted,
                tail: fieldTail,
                hud: hypothesis,
                phase: .tailThrottled
            )
        case let .frozen(fieldCommitted, fieldTail):
            return update(
                committed: fieldCommitted,
                stable: fieldCommitted,
                tail: fieldTail,
                hud: "",
                phase: .frozenFinal
            )
        case .live:
            break
        }

        let committedText = committed.joined()
        guard let uncommittedText = Self.exactUTF16Suffix(of: hypothesis, after: committedText) else {
            freeze()
            return frozenUpdate()
        }

        // Do not expand an arbitrarily long recogniser hypothesis into policy
        // fragments just to learn that it is over the 64 UTF-16 tail cap.
        // The original hypothesis remains HUD-only, while retained policy
        // state stays bounded by the cap.
        if uncommittedText.utf16.count > policy.maximumTailUTF16Length {
            let fieldCommitted = committedText
            let fieldTail = fieldResidentTail
            state = .throttled(committed: fieldCommitted, tail: fieldTail)
            gate.invalidate()
            return update(
                committed: fieldCommitted,
                stable: fieldCommitted,
                tail: fieldTail,
                hud: hypothesis,
                phase: .tailThrottled
            )
        }

        let uncommitted = Self.fragments(from: uncommittedText)
        if !Self.hasPrefix(uncommitted, stableCandidates) {
            // A stable-but-unacknowledged proposal changed. It was never field
            // state, so it may be withdrawn, but any pending acknowledgement is
            // made stale before calculating the new proposal.
            stableCandidates = []
            candidates = []
            gate.invalidate()
        }

        let remaining = Array(uncommitted.dropFirst(stableCandidates.count))
        candidates = Self.merge(previous: candidates, incoming: remaining, at: now)
        while let first = candidates.first,
              first.confirmations >= policy.matchingHypotheses,
              now - first.firstSeenMilliseconds >= policy.minimumTailAgeMilliseconds {
            stableCandidates.append(first.text)
            candidates.removeFirst()
        }

        let proposedTail = stableCandidates.joined() + candidates.map(\.text).joined()
        if proposedTail.utf16.count > policy.maximumTailUTF16Length ||
            proposedTail.split(whereSeparator: \.isWhitespace).count > policy.maximumRevisionDepthWords {
            // The field-resident committed/tail state is sealed here. Further
            // recogniser work is HUD-only and cannot create a new live write.
            let fieldCommitted = committed.joined()
            let fieldTail = fieldResidentTail
            state = .throttled(committed: fieldCommitted, tail: fieldTail)
            gate.invalidate()
            return update(
                committed: fieldCommitted,
                stable: fieldCommitted,
                tail: fieldTail,
                hud: hypothesis,
                phase: .tailThrottled
            )
        }

        return update(
            committed: committedText,
            stable: committedText + stableCandidates.joined(),
            tail: proposedTail,
            hud: "",
            phase: .live
        )
    }

    /// Starts an acknowledgement handshake for the currently stable candidate.
    /// The caller must later call `acknowledge` after an explicit, current-
    /// generation acknowledgement. This core cannot issue the operation itself.
    public mutating func beginStableMutation() -> StableMutationRequest? {
        let expectedTail = stableCandidates.joined()
        guard case .live = state, !stableCandidates.isEmpty,
              expectedTail.utf16.count <= policy.maximumTailUTF16Length,
              let token = gate.beginMutation() else { return nil }
        return StableMutationRequest(
            candidatePrefix: committed.joined() + expectedTail,
            expectedTail: expectedTail,
            token: token
        )
    }

    /// Commits only a request that is still the gate's current in-flight
    /// generation and still names the exact candidate. Stale acknowledgements
    /// have no effect.
    @discardableResult
    public mutating func acknowledge(_ receipt: MutationReceipt) -> Bool {
        guard case .live = state,
              receipt.expectedTail.utf16.count <= policy.maximumTailUTF16Length,
              exactUTF16Equal(receipt.expectedTail, stableCandidates.joined()),
              exactUTF16Equal(receipt.candidatePrefix, committed.joined() + stableCandidates.joined()),
              gate.complete(receipt.token) else { return false }
        committed += stableCandidates
        stableCandidates = []
        // Retain only the exact, request-bound tail after all identity and
        // cap checks have passed. This snapshot is what throttling freezes.
        fieldResidentTail = receipt.expectedTail
        return true
    }

    /// Ownership loss is terminal. Calling `ingest` again cannot revive the
    /// tracker; callers must use `resetForNewSession` explicitly.
    public mutating func invalidateOwnership() {
        freeze()
    }

    public mutating func resetForNewSession() {
        committed = []
        stableCandidates = []
        candidates = []
        gate = MutationGenerationGate()
        fieldResidentTail = ""
        state = .live
        lastMonotonicMilliseconds = 0
    }

    private mutating func freeze() {
        let currentCommitted = committed.joined()
        state = .frozen(committed: currentCommitted, tail: fieldResidentTail)
        gate.invalidate()
    }

    private func frozenUpdate() -> StableTranscriptUpdate {
        guard case let .frozen(fieldCommitted, fieldTail) = state else { fatalError("expected frozen state") }
        return update(committed: fieldCommitted, stable: fieldCommitted, tail: fieldTail, hud: "", phase: .frozenFinal)
    }

    private func update(committed: String, stable: String, tail: String, hud: String, phase: LiveInsertionPhase) -> StableTranscriptUpdate {
        StableTranscriptUpdate(
            committedPrefix: committed,
            stableCandidatePrefix: stable,
            revisableTail: tail,
            hudOnlyTail: hud,
            phase: phase
        )
    }

    private mutating func monotonic(_ observed: Int) -> Int {
        let clamped = max(lastMonotonicMilliseconds, max(0, observed))
        lastMonotonicMilliseconds = clamped
        return clamped
    }

    /// State retained by the policy core. It excludes the caller-owned current
    /// hypothesis and HUD-only content. A future coordinator must keep its own
    /// larger transcript outside this bounded live-tail policy.
    public var retainedUTF16Length: Int {
        committed.joined().utf16.count + stableCandidates.joined().utf16.count +
            candidates.reduce(0) { $0 + $1.text.utf16.count } + fieldResidentTail.utf16.count
    }

    private static func fragments(from hypothesis: String) -> [String] {
        guard !hypothesis.isEmpty else { return [] }
        var runs: [(isWhitespace: Bool, text: String)] = []
        for character in hypothesis {
            let whitespace = character.isWhitespace
            if let last = runs.indices.last, runs[last].isWhitespace == whitespace {
                runs[last].text.append(character)
            } else {
                runs.append((whitespace, String(character)))
            }
        }

        // Whitespace is intentionally its own fragment. A recogniser adding a
        // separator after an acknowledged word then retains the exact old
        // prefix instead of falsely presenting ("word ") as a replacement for
        // ("word").
        return runs.map(\.text)
    }

    private static func hasPrefix(_ incoming: [String], _ prefix: [String]) -> Bool {
        guard incoming.count >= prefix.count else { return false }
        return zip(incoming, prefix).allSatisfy { exactUTF16Equal($0, $1) }
    }

    private static func merge(previous: [Fragment], incoming: [String], at milliseconds: Int) -> [Fragment] {
        incoming.enumerated().map { index, text in
            guard index < previous.count, exactUTF16Equal(previous[index].text, text) else {
                return Fragment(text: text, firstSeenMilliseconds: milliseconds, confirmations: 1)
            }
            let previous = previous[index]
            return Fragment(text: text, firstSeenMilliseconds: previous.firstSeenMilliseconds, confirmations: previous.confirmations + 1)
        }
    }

    private static func exactUTF16Suffix(of whole: String, after prefix: String) -> String? {
        guard whole.utf16.count >= prefix.utf16.count,
              whole.utf16.prefix(prefix.utf16.count).elementsEqual(prefix.utf16) else { return nil }
        let suffixStart = whole.utf16.index(whole.utf16.startIndex, offsetBy: prefix.utf16.count)
        guard let stringIndex = String.Index(suffixStart, within: whole) else { return nil }
        return String(whole[stringIndex...])
    }
}

@inline(__always)
private func exactUTF16Equal(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.elementsEqual(rhs.utf16)
}

public enum LiveInsertionStopRoute: Equatable, Sendable {
    case settleOwnedTail
    case frozenFinal
    case fallbackFinal
    /// The caller may not deliver again after a terminal route has been issued.
    case copyOnly
    case noOp
}

public enum SealedLiveInsertionSessionState: Equatable, Sendable {
    case activeNoTail
    case activeOwnedTail
    case tailThrottledNoTail
    case tailThrottledOwnedTail
    case frozenFinal
    case frozenFinalDelivered
    case secureFinal
    case secureFinalDelivered
    case fallbackFinalDelivered
    case settled
}

/// The authoritative stop router. It owns the "a tail was written" fact and
/// deliberately has no boolean input that a caller can accidentally falsify.
/// Once frozen, it remains frozen until explicit reset/new session.
public struct SealedLiveInsertionSession: Sendable {
    public private(set) var state: SealedLiveInsertionSessionState = .activeNoTail

    public init() {}

    /// Internal coordinator hand-off only. Keeping this non-public prevents a
    /// compatibility caller from forging "a tail was written" at stop time.
    mutating func recordAcknowledgedTailWrite() {
        guard state == .activeNoTail else { return }
        state = .activeOwnedTail
    }

    public mutating func throttle() {
        switch state {
        case .activeNoTail: state = .tailThrottledNoTail
        case .activeOwnedTail: state = .tailThrottledOwnedTail
        default: break
        }
    }

    public mutating func invalidateOwnership() {
        switch state {
        case .fallbackFinalDelivered, .frozenFinalDelivered, .secureFinal, .secureFinalDelivered, .settled: break
        default: state = .frozenFinal
        }
    }

    /// Secure transition is terminal, including before a tail exists. It never
    /// routes through atomic fallback: Slice 1's only permitted recovery is
    /// copy/HUD and it grants no mutation capability.
    public mutating func secureInputActivated() {
        switch state {
        case .activeOwnedTail, .tailThrottledOwnedTail, .activeNoTail,
             .tailThrottledNoTail, .frozenFinal:
            state = .secureFinal
        default:
            break
        }
    }

    public mutating func stop(ownershipVerified: Bool) -> LiveInsertionStopRoute {
        switch state {
        case .activeOwnedTail, .tailThrottledOwnedTail:
            guard ownershipVerified else {
                state = .frozenFinalDelivered
                return .frozenFinal
            }
            state = .settled
            return .settleOwnedTail
        case .activeNoTail, .tailThrottledNoTail:
            state = .fallbackFinalDelivered
            return .fallbackFinal
        case .frozenFinal:
            state = .frozenFinalDelivered
            return .frozenFinal
        case .secureFinal:
            state = .secureFinalDelivered
            return .copyOnly
        case .fallbackFinalDelivered, .frozenFinalDelivered, .secureFinalDelivered, .settled:
            return .noOp
        }
    }

    public mutating func resetForNewSession() {
        state = .activeNoTail
    }
}

public enum DeliveryPolicy: Sendable {
    case efficient
    case hudOnly
    case atomicFinal
    case protected
    case evidenceOnlyLiveCandidate

    /// Slice 1 cannot grant mutation authority. B-01 through B-05 must be
    /// closed by separately reviewed evidence before any adapter exists.
    public var mayIssueExternalMutation: Bool { false }
}

public struct LeaseCapabilityInput: Equatable, Sendable {
    public var accessibilityTrusted: Bool
    public var focusedEditableTarget: Bool
    public var collapsedSelection: Bool
    public var safeRole: Bool
    public var rangedReadAvailable: Bool
    public var secureRole: Bool
    public var secureInputEnabled: Bool
    public var terminalOrUncertified: Bool

    public init(
        accessibilityTrusted: Bool,
        focusedEditableTarget: Bool,
        collapsedSelection: Bool,
        safeRole: Bool,
        rangedReadAvailable: Bool,
        secureRole: Bool,
        secureInputEnabled: Bool,
        terminalOrUncertified: Bool
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.focusedEditableTarget = focusedEditableTarget
        self.collapsedSelection = collapsedSelection
        self.safeRole = safeRole
        self.rangedReadAvailable = rangedReadAvailable
        self.secureRole = secureRole
        self.secureInputEnabled = secureInputEnabled
        self.terminalOrUncertified = terminalOrUncertified
    }
}

public enum SliceOneLeaseClassification: Equatable, Sendable {
    case protected
    case atomicFinalOnly
    case evidenceOnlyCandidate

    public var deliveryPolicy: DeliveryPolicy {
        switch self {
        case .protected: return .protected
        case .atomicFinalOnly: return .atomicFinal
        case .evidenceOnlyCandidate: return .evidenceOnlyLiveCandidate
        }
    }
}

public enum SliceOneLeaseClassifier {
    /// Classification is deliberately conservative. Even a structurally good
    /// target is an evidence-only candidate, never a permission to mutate.
    public static func classify(_ input: LeaseCapabilityInput) -> SliceOneLeaseClassification {
        if input.secureRole || input.secureInputEnabled { return .protected }
        guard input.accessibilityTrusted, input.focusedEditableTarget,
              input.collapsedSelection, input.safeRole, input.rangedReadAvailable else {
            return .atomicFinalOnly
        }
        return input.terminalOrUncertified ? .atomicFinalOnly : .evidenceOnlyCandidate
    }
}

/// A capacity-one, latest-wins buffer used by a future coordinator to bound
/// recogniser work. It contains no timers, threads, or external side effects.
public struct LatestWinsBuffer<Element: Sendable>: Sendable {
    private var latest: Element?
    public init() {}
    public var isEmpty: Bool { latest == nil }
    public mutating func replace(with value: Element) { latest = value }
    public mutating func takeLatest() -> Element? {
        defer { latest = nil }
        return latest
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

    public init(outcome: LiveInsertionTelemetryOutcome, tailLength: CountBucket, revisionDepth: CountBucket) {
        self.outcome = outcome
        self.tailLength = tailLength
        self.revisionDepth = revisionDepth
    }
}
