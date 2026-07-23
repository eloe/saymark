import Foundation

public final class DictationUpdateSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        let action = lock.withLock {
            defer { cancellation = nil }
            return cancellation
        }
        action?()
    }

    deinit { cancel() }
}

/// Thread-safe multicast for live transcript updates. Runtime HUD and onboarding
/// can observe the same session without replacing or restoring each other's state.
final class DictationUpdateHub: @unchecked Sendable {
    typealias Handler = (_ confirmed: String, _ partial: String) -> Void

    private let lock = NSLock()
    private var handlers: [UUID: Handler] = [:]

    func subscribe(_ handler: @escaping Handler) -> DictationUpdateSubscription {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return DictationUpdateSubscription { [weak self] in self?.remove(id) }
    }

    func publish(confirmed: String, partial: String) {
        let snapshot = lock.withLock { Array(handlers.values) }
        for handler in snapshot {
            handler(confirmed, partial)
        }
    }

    private func remove(_ id: UUID) {
        lock.withLock { handlers[id] = nil }
    }
}
