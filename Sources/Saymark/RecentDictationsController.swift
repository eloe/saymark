import AppKit
import Foundation
import Observation
import SaymarkKit

/// Main-actor bridge for the private Recent Dictations window. Transcript text
/// stays in the store/window; it is never placed in diagnostics or telemetry.
@MainActor
@Observable
final class RecentDictationsController: NSObject, NSWindowDelegate {
    static let shared = RecentDictationsController()

    private(set) var records: [HistoryRecord] = []
    private(set) var query = ""
    private(set) var errorMessage: String?
    private(set) var pendingReinsert: HistoryRecord?
    private(set) var pendingDeletion: HistoryRecord?
    private(set) var resultSummary = "0 results"
    private var store: SQLiteHistoryStore?
    private var window: NSWindow?
    private var previousApplication: NSRunningApplication?
    private var refreshGeneration: UInt64 = 0

    private override init() {}

    /// Opens and verifies the local store away from the release-to-delivery
    /// path.  A later dictation never waits for directory/schema work merely
    /// to become recoverable.
    func prepareForDelivery() async {
        guard RecentDictationsRetention.current != .off else { return }
        do {
            if store == nil { store = try makeStore(RecentDictationsRetention.current) }
            try await store?.warmUp()
        } catch {
            // History is optional. Keep the failure local and fail open when
            // the next dictation is delivered.
            errorMessage = "Recent Dictations is temporarily unavailable."
        }
    }

    /// Expiry cleanup is deliberately excluded from the release-to-delivery
    /// path. It runs once storage is warm and may be retried from future idle
    /// opportunities after a busy checkpoint.
    func runIdleMaintenance() async {
        guard RecentDictationsRetention.current != .off else { return }
        do {
            await prepareForDelivery()
            try await store?.purgeExpired()
        } catch {
            // A busy checkpoint leaves the prior truth intact; never publish a
            // success state for a purge that SQLite could not finish.
            errorMessage = "Recent Dictations cleanup will retry when Saymark is idle."
        }
    }

    /// The store changes policy before the preferences mirror changes.  That
    /// ordering prevents the UI from claiming a destructive privacy transition
    /// succeeded when its transaction/checkpoint failed.
    func setRetention(_ retention: RecentDictationsRetention) async -> Bool {
        do {
            if retention == .off {
                    // An Off setting after relaunch still has to clear any
                    // existing database; `.off` initialization itself is
                    // intentionally side-effect free.
                    if store == nil { store = try makeStore(.days30) }
                    if let store { try await store.setRetentionPolicy(.off) }
                    store = nil
                    refreshGeneration &+= 1
                    records = []
                UserDefaults.standard.set(retention.rawValue, forKey: RecentDictationsRetention.defaultsKey)
                records = []
                query = ""
                return true
            }
            let store = try makeStore(retention)
            try await store.setRetentionPolicy(retention.historyPolicy)
            self.store = store
            UserDefaults.standard.set(retention.rawValue, forKey: RecentDictationsRetention.defaultsKey)
            await refresh()
            return true
        } catch HistoryStoreError.cleanupIncomplete {
            errorMessage = "History was removed, but Saymark could not finish cleaning its local database. Quit other Saymark windows and try again."
            return false
        } catch {
            errorMessage = "Recent Dictations is unavailable on this Mac."
            return false
        }
    }

    /// Session history is intentionally durable only for the current process.
    /// Calling this at launch clears a crash-left session before the menu or
    /// window can expose it.
    func clearPriorSessionAtLaunch() {
        guard RecentDictationsRetention.current == .session else { return }
        Task { _ = await setRetention(.session) }
    }

    func clearSessionAtTermination() {
        guard RecentDictationsRetention.current == .session else { return }
        guard let store else { return }
        // `applicationWillTerminate` does not keep ordinary Tasks alive. Give
        // the already-warm writer a bounded, synchronous termination window;
        // a crash still relies on the launch-time session purge and is never
        // represented as no-disk persistence.
        let completed = DispatchSemaphore(value: 0)
        Task.detached {
            defer { completed.signal() }
            try? await store.clear()
        }
        _ = completed.wait(timeout: .now() + .milliseconds(900))
    }

    func present() {
        guard RecentDictationsRetention.current != .off else { return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { await refresh() }
    }

    func clearHistory() {
        Task {
            do {
                if store == nil { store = try makeStore(RecentDictationsRetention.current) }
                try await store?.clear()
                refreshGeneration &+= 1
                records = []
                resultSummary = "0 results"
                SaymarkDiagnostics.logHistoryOperation(.clear, outcome: .committed)
            } catch {
                SaymarkDiagnostics.logHistoryOperation(.clear, outcome: .unavailable)
                errorMessage = "Couldn’t clear Recent Dictations."
            }
        }
    }

    func refresh(query: String? = nil) async {
        if let query { self.query = query }
        refreshGeneration &+= 1
        let requestedGeneration = refreshGeneration
        let requestedQuery = self.query
        do {
            if store == nil, RecentDictationsRetention.current != .off {
                store = try makeStore(RecentDictationsRetention.current)
            }
            let snapshot = try await store?.records(query: requestedQuery, limit: 20) ?? []
            // Search and closing the private window can race slow I/O. A stale
            // response must never repopulate a cleared/closed presentation.
            guard requestedGeneration == refreshGeneration, self.query == requestedQuery else { return }
            records = snapshot
            resultSummary = "\(snapshot.count) \(snapshot.count == 1 ? "result" : "results")"
        } catch {
            guard requestedGeneration == refreshGeneration else { return }
            errorMessage = "Recent Dictations is unavailable on this Mac."
        }
    }

    /// The controller samples policy at both dictation start and finalization;
    /// secure input and HUD-only sessions never reach the database boundary.
    func recordFinal(
        _ text: String,
        enabledAtStart: Bool,
        secureInputActive: Bool,
        isHUDOnly: Bool
    ) async -> HistoryRecord? {
        guard enabledAtStart,
              RecentDictationsRetention.current != .off,
              !secureInputActive,
              !isHUDOnly
        else { return nil }
        do {
            guard let store else {
                // This must normally already be warm. Never turn late startup
                // into a release-to-delivery dependency; warm for the next
                // eligible final instead.
                Task { await prepareForDelivery() }
                errorMessage = "Recent Dictations was skipped to keep dictation instant."
                return nil
            }
            let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
            return await recordBeforeDelivery(
                store: store,
                finalization: .init(text: text, secureInputActive: secureInputActive, isHUDOnly: isHUDOnly),
                deadline: deadline
            )
        } catch {
            // History is deliberately fail-open: no persistence error is allowed
            // to suppress the user's final delivery.
            errorMessage = "Recent Dictations was skipped to keep dictation instant."
            return nil
        }
    }

    func markDelivery(_ record: HistoryRecord?, state: HistoryDeliveryState) {
        guard let record else { return }
        Task { try? await store?.updateDeliveryState(id: record.id, to: state) }
    }

    func copy(_ record: HistoryRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
    }

    func delete(_ record: HistoryRecord) {
        Task {
            do {
                _ = try await store?.delete(id: record.id)
                await refresh()
            } catch {
                errorMessage = "Couldn’t delete this dictation."
            }
        }
    }

    func requestDelete(_ record: HistoryRecord) { pendingDeletion = record }
    func cancelDelete() { pendingDeletion = nil }
    func confirmDelete() {
        guard let record = pendingDeletion else { return }
        pendingDeletion = nil
        delete(record)
    }

    /// Reinsert deliberately targets the app that was frontmost before the
    /// history window was opened, never Saymark's own search field.
    func requestReinsert(_ record: HistoryRecord) {
        pendingReinsert = record
    }

    var reinsertTargetName: String {
        previousApplication?.localizedName ?? "the previously active app"
    }

    func cancelReinsert() { pendingReinsert = nil }

    /// Called only from the explicit confirmation dialog.  The former target is
    /// held in memory, never persisted; Saymark is rejected as a destination.
    func confirmReinsert() {
        guard let record = pendingReinsert else { return }
        pendingReinsert = nil
        guard let target = previousApplication,
              !target.isTerminated,
              target.processIdentifier > 0,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { copy(record); errorMessage = "That app is no longer available. The text was copied instead."; return }
        guard Accessibility.isTrusted else {
            copy(record)
            errorMessage = "Accessibility is needed to reinsert. The text was copied."
            return
        }
        guard !TextInjector.secureInputActive else {
            copy(record)
            errorMessage = "The current field is protected. The text was copied."
            return
        }
        let expectedPID = target.processIdentifier
        window?.orderOut(nil)
        target.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak target] in
            guard let self, let target,
                  !target.isTerminated,
                  target.processIdentifier == expectedPID,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID
            else { self?.errorMessage = "That app is no longer active. Copy the text instead."; return }
            guard !TextInjector.secureInputActive else {
                self.copy(record)
                self.errorMessage = "The current field is protected. The text was copied."
                return
            }
            switch TextInjector.paste(record.text) {
            case .pasted: errorMessage = "Reinserted into \(target.localizedName ?? "the selected app")."
            case .copiedSecureInput: self.errorMessage = "Field is protected. The text was copied."
            case .failed: self.errorMessage = "Couldn’t paste text. The text was copied."
            }
        }
    }

    private func makeStore(_ retention: RecentDictationsRetention) throws -> SQLiteHistoryStore {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.eloe.saymark"
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("RecentDictations", isDirectory: true)
        return try SQLiteHistoryStore(directoryURL: root, policy: retention.historyPolicy)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: RecentDictationsView(controller: self))
        let window = NSWindow(contentViewController: host)
        window.title = "Recent Dictations"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isRestorable = false
        window.sharingType = .none
        window.delegate = self
        window.setContentSize(NSSize(width: 720, height: 480))
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Do not keep search terms, selected text, records, or the destination
        // PID alive after the private history window is dismissed.
        refreshGeneration &+= 1
        records = []
        resultSummary = "0 results"
        query = ""
        previousApplication = nil
        pendingReinsert = nil
        pendingDeletion = nil
        errorMessage = nil
        window = nil
    }

    private func recordBeforeDelivery(
        store: SQLiteHistoryStore,
        finalization: HistoryFinalization,
        deadline: UInt64
    ) async -> HistoryRecord? {
        // Do not use a task group here: structured concurrency waits for every
        // child at scope exit, which would turn a late SQLite actor turn into a
        // delivery-path stall. The store's deadline is the commit authority;
        // this race merely returns control to final delivery on time.
        await withCheckedContinuation { continuation in
            let gate = RecordDeadlineGate()
            Task.detached(priority: .userInitiated) { [weak self] in
                let result: RecordAttempt
                do {
                    result = .record(try await store.recordFinal(finalization, deadlineUptimeNanoseconds: deadline))
                } catch {
                    result = .failure(error as? HistoryStoreError)
                }
                guard gate.resolve(continuation, with: result) else { return }
                await self?.applyRecordAttempt(result)
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                let remaining = deadline > DispatchTime.now().uptimeNanoseconds
                    ? deadline - DispatchTime.now().uptimeNanoseconds : 0
                try? await Task.sleep(nanoseconds: remaining)
                let result: RecordAttempt = .deadline
                guard gate.resolve(continuation, with: result) else { return }
                await self?.applyRecordAttempt(result)
            }
        }
    }

    private func applyRecordAttempt(_ result: RecordAttempt) {
        switch result {
        case .record:
            break
        case .deadline:
            SaymarkDiagnostics.logHistoryOperation(.record, outcome: .deadlineExceeded)
            errorMessage = "Recent Dictations was skipped to keep dictation instant."
        case .failure(let error):
            switch error {
            case .recordTooLarge:
                SaymarkDiagnostics.logHistoryOperation(.record, outcome: .skipped)
                errorMessage = "This dictation is too large to save in Recent Dictations."
            case HistoryStoreError.deadlineExceeded:
                SaymarkDiagnostics.logHistoryOperation(.record, outcome: .deadlineExceeded)
                errorMessage = "Recent Dictations was skipped to keep dictation instant."
            default:
                SaymarkDiagnostics.logHistoryOperation(.record, outcome: .unavailable)
                errorMessage = "Recent Dictations is temporarily unavailable."
            }
        }
    }
}

private enum RecordAttempt: Sendable {
    case record(HistoryRecord?)
    case deadline
    case failure(HistoryStoreError?)
}

/// A one-shot lock keeps the 100 ms caller result independent of a queued
/// writer task. It does not cancel SQLite; `recordFinal` owns rollback and the
/// no-late-commit deadline check before resuming the late worker.
private final class RecordDeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func resolve(
        _ continuation: CheckedContinuation<HistoryRecord?, Never>,
        with result: RecordAttempt
    ) -> Bool {
        let didWin = lock.withLock {
            guard !resolved else { return false }
            resolved = true
            return true
        }
        guard didWin else { return false }
        switch result {
        case .record(let record): continuation.resume(returning: record)
        case .deadline, .failure: continuation.resume(returning: nil)
        }
        return true
    }
}

private extension RecentDictationsRetention {
    var historyPolicy: HistoryRetentionPolicy {
        switch self {
        case .off: return .off
        case .session: return .session
        case .days7: return .days7
        case .days30: return .days30
        case .days90: return .days90
        case .untilDeleted: return .untilDeleted
        }
    }
}
