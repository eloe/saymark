import AppKit
import Foundation
import Observation
import SaymarkKit
import SwiftUI

/// Main-actor bridge for the private Recent Dictations window. Transcript text
/// stays in the store/window; it is never placed in diagnostics or telemetry.
@MainActor
@Observable
final class RecentDictationsController: NSObject, NSWindowDelegate {
    private static let recordLimitMessage =
        "Recent Dictations is full. Delete a saved dictation or clear history before new text can be saved."
    enum CommittedCleanupPath: CaseIterable {
        case singleDelete, clear, retention, off, session, expiry, recovery
    }
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
    private var capacityGeneration: UInt64 = 0
    private var resultLimit = 20
    private var hasMoreResults = false
    private(set) var activeRetention: RecentDictationsRetention = .off
    private(set) var isStartupComplete = false
    private(set) var isHistoryAvailable = false
    private(set) var isAtRecordLimit = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchCancellation: HistoryWriteCancellation?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var isRecordingForMaintenance: @MainActor () -> Bool = { false }
    @ObservationIgnored var reinsertAccessibilityTrusted: () -> Bool = { Accessibility.isTrusted }
    @ObservationIgnored var reinsertSecureInputActive: () -> Bool = { TextInjector.secureInputActive }
    @ObservationIgnored var reinsertActivate: (NSRunningApplication) -> Void = {
        $0.activate(options: [.activateIgnoringOtherApps])
    }
    @ObservationIgnored var reinsertFrontmostPID: () -> pid_t? = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    @ObservationIgnored var reinsertPaste: (String) -> TextInjector.Result = { TextInjector.paste($0) }
    @ObservationIgnored var reinsertDelay: TimeInterval = 0.5
    @ObservationIgnored var allowSelfReinsertTargetForTesting = false
    @ObservationIgnored var announcementSink: (String) -> Void = { message in
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    private override init() {}

    /// Opens and verifies the local store away from the release-to-delivery
    /// path.  A later dictation never waits for directory/schema work merely
    /// to become recoverable.
    func prepareForDelivery() async {
        guard isStartupComplete, activeRetention != .off else { return }
        do {
            if store == nil { store = try makeStore(.off) }
            try await store?.warmUp()
        } catch is HistoryCommittedCleanupFailure {
            invalidatePresentationAfterCommittedCleanupFailure(.recovery)
            errorMessage = "Recent Dictations recovery committed, but Saymark could not finish cleaning its local database."
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
        guard isStartupComplete, activeRetention != .off, isTrulyIdleForMaintenance else { return }
        await prepareForDelivery()
        await performExpiryCleanup()
    }

    private func performExpiryCleanup() async {
        do {
            try await store?.purgeExpired()
            await refreshRecordLimitState()
        } catch is HistoryCommittedCleanupFailure {
            invalidatePresentationAfterCommittedCleanupFailure(.expiry)
            errorMessage = "Expired dictations were removed, but Saymark could not finish cleaning its local database."
        } catch {
            // A busy checkpoint leaves the prior truth intact; never publish a
            // success state for a purge that SQLite could not finish.
            errorMessage = "Recent Dictations cleanup will retry when Saymark is idle."
        }
    }

    /// Retention cannot rely on a window opening.  Run a small, cancellable
    /// maintenance pass while Saymark is idle and retry later after a busy WAL
    /// checkpoint without ever putting that work on the delivery path.
    func startRecurringIdleMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = Task(priority: .background) { [weak self] in
            while !Task.isCancelled {
                await self?.runIdleMaintenance()
                do { try await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000) }
                catch { return }
            }
        }
    }

    func configureIdleMaintenance(isRecording: @escaping @MainActor () -> Bool) {
        isRecordingForMaintenance = isRecording
    }

    private var isTrulyIdleForMaintenance: Bool {
        guard !isRecordingForMaintenance(),
              window?.isVisible != true,
              pendingReinsert == nil,
              pendingDeletion == nil
        else { return false }
        let inputTypes: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel,
        ]
        let idleSeconds = inputTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
        return idleSeconds >= 5
    }

    /// The store changes policy before the preferences mirror changes.  That
    /// ordering prevents the UI from claiming a destructive privacy transition
    /// succeeded when its transaction/checkpoint failed.
    func setRetention(_ retention: RecentDictationsRetention) async -> Bool {
        guard isStartupComplete else { return false }
        do {
            if retention == .off {
                    // An Off setting after relaunch still has to clear any
                    // existing database; `.off` initialization itself is
                    // intentionally side-effect free.
                    if store == nil { store = try makeStore(.off) }
                    if let store { try await store.setRetentionPolicy(.off) }
                    store = nil
                    refreshGeneration &+= 1
                    records = []
                UserDefaults.standard.set(retention.rawValue, forKey: RecentDictationsRetention.defaultsKey)
                activeRetention = .off
                isHistoryAvailable = false
                clearRecordLimitState()
                records = []
                query = ""
                return true
            }
            // Policy transitions deliberately reuse the already-warm writer.
            // Opening a second connection would make retention changes contend
            // with a dictation and could leave an old connection alive.
            let activeStore: SQLiteHistoryStore
            if let store {
                activeStore = store
            } else {
                activeStore = try makeStore(.off)
                self.store = activeStore
            }
            try await activeStore.setRetentionPolicy(retention.historyPolicy)
            let durable = try await activeStore.durableRetentionPolicy()
            guard durable == retention.historyPolicy else { throw HistoryStoreError.corrupt }
            UserDefaults.standard.set(retention.rawValue, forKey: RecentDictationsRetention.defaultsKey)
            activeRetention = retention
            isHistoryAvailable = true
            await refresh()
            await refreshRecordLimitState()
            return true
        } catch is HistoryCommittedCleanupFailure {
            await reconcileToDurablePolicy(mirrorDefaults: false, publishAvailability: false)
            invalidatePresentationAfterCommittedCleanupFailure(
                retention == .off ? .off : (retention == .session ? .session : .retention)
            )
            errorMessage = "History was removed, but Saymark could not finish cleaning its local database. Quit other Saymark windows and try again."
            return false
        } catch {
            await reconcileToDurablePolicy(mirrorDefaults: false, publishAvailability: false)
            errorMessage = "Recent Dictations is unavailable on this Mac."
            return false
        }
    }

    /// Session history is intentionally durable only for the current process.
    /// Calling this at launch clears a crash-left session before the menu or
    /// window can expose it.
    func initializeAtLaunch() async {
        isHistoryAvailable = false
        clearRecordLimitState()
        isStartupComplete = false
        activeRetention = .off
        do {
            let startupStore = try makeStore(.off)
            store = startupStore
            var durable = try await startupStore.durableRetentionPolicy()
            if durable == .off {
                // Resume any interrupted Off cleanup before publishing startup.
                try await startupStore.setRetentionPolicy(.off)
                store = nil
            } else if durable == .session {
                // A previous process's session is never exposed in this one.
                try await startupStore.setRetentionPolicy(.session)
                durable = .session
            } else if durable.isEnabled {
                try await startupStore.purgeExpired()
            }
            activeRetention = RecentDictationsRetention(durable)
            UserDefaults.standard.set(activeRetention.rawValue, forKey: RecentDictationsRetention.defaultsKey)
            isHistoryAvailable = activeRetention != .off
            await refreshRecordLimitState()
            isStartupComplete = true
        } catch is HistoryCommittedCleanupFailure {
            store = nil
            activeRetention = .off
            isStartupComplete = true
            invalidatePresentationAfterCommittedCleanupFailure(.recovery)
            errorMessage = "Recent Dictations is unavailable on this Mac."
        } catch {
            // No menu, record eligibility, or settings claim is published
            // until the durable store has opened and launch cleanup completed.
            store = nil
            activeRetention = .off
            isHistoryAvailable = false
            isStartupComplete = true
            errorMessage = "Recent Dictations is unavailable on this Mac."
        }
    }

    func clearSessionAtTermination() {
        guard activeRetention == .session else { return }
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
        guard isStartupComplete, activeRetention != .off, isHistoryAvailable else { return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { await refresh() }
    }

    func clearHistory() {
        Task { await performClearHistory() }
    }

    private func performClearHistory() async {
        do {
            if store == nil { store = try makeStore(.off) }
            try await store?.clear()
            refreshGeneration &+= 1
            records = []
            resultSummary = "0 results"
            clearRecordLimitState()
            SaymarkDiagnostics.logHistoryOperation(.clear, outcome: .success)
        } catch is HistoryCommittedCleanupFailure {
            SaymarkDiagnostics.logHistoryOperation(.clear, outcome: .unavailable)
            invalidatePresentationAfterCommittedCleanupFailure(.clear)
            errorMessage = "History is removed from the active list, but Saymark could not finish cleaning every local database artifact. Try again when no other Saymark window is using history."
        } catch {
            SaymarkDiagnostics.logHistoryOperation(.clear, outcome: .unavailable)
            errorMessage = "Couldn’t clear Recent Dictations."
        }
    }

    func refresh(query: String? = nil, cancellation: HistoryWriteCancellation? = nil) async {
        if let query { self.query = query }
        refreshGeneration &+= 1
        let requestedGeneration = refreshGeneration
        let requestedQuery = self.query
        do {
            if store == nil, activeRetention != .off {
                store = try makeStore(.off)
            }
            let requestedLimit = resultLimit == 20 ? 21 : resultLimit
            let snapshot = try await store?.records(
                query: requestedQuery,
                limit: requestedLimit,
                cancellation: cancellation
            ) ?? []
            // Search and closing the private window can race slow I/O. A stale
            // response must never repopulate a cleared/closed presentation.
            guard requestedGeneration == refreshGeneration, self.query == requestedQuery else { return }
            hasMoreResults = snapshot.count > resultLimit
            records = Array(snapshot.prefix(resultLimit))
            resultSummary = "\(records.count) \(records.count == 1 ? "result" : "results")"
            announce(resultSummary)
        } catch {
            guard requestedGeneration == refreshGeneration else { return }
            errorMessage = "Recent Dictations is unavailable on this Mac."
        }
    }

    /// At most one delayed search is outstanding.  Each replacement cancels
    /// the previous task and carries a generation check through the async store
    /// call, so closing the window can never repopulate it with a late result.
    func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        searchCancellation?.interrupt()
        query = value
        resultLimit = 20
        hasMoreResults = false
        refreshGeneration &+= 1
        let requestedGeneration = refreshGeneration
        let cancellation = HistoryWriteCancellation()
        searchCancellation = cancellation
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            guard let self, self.refreshGeneration == requestedGeneration else { return }
            await self.refresh(query: value, cancellation: cancellation)
        }
    }

    var canLoadMore: Bool {
        resultLimit < SQLiteHistoryStore.maximumResultLimit && hasMoreResults
    }

    func loadMore() {
        guard canLoadMore else { return }
        resultLimit = SQLiteHistoryStore.maximumResultLimit
        Task { await refresh() }
    }

    /// The controller samples policy at both dictation start and finalization;
    /// secure input and HUD-only sessions never reach the database boundary.
    func recordFinal(
        _ text: String,
        enabledAtStart: Bool,
        secureInputActive: Bool,
        isHUDOnly: Bool
    ) async -> HistoryRecord? {
        await recordFinalWithOutcome(
            text,
            enabledAtStart: enabledAtStart,
            secureInputActive: secureInputActive,
            isHUDOnly: isHUDOnly
        ).record
    }

    func recordFinalWithOutcome(
        _ text: String,
        enabledAtStart: Bool,
        secureInputActive: Bool,
        isHUDOnly: Bool
    ) async -> HistoryPersistenceOutcome {
        guard enabledAtStart,
              isStartupComplete,
              activeRetention != .off,
              !secureInputActive,
              !isHUDOnly
        else { return .record(nil) }
        guard let store else {
            // This must normally already be warm. Never turn late startup
            // into a release-to-delivery dependency; warm for the next
            // eligible final instead.
            Task { await prepareForDelivery() }
            errorMessage = "Recent Dictations was skipped to keep dictation instant."
            return .record(nil)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
        let attempt = await recordBeforeDelivery(
            store: store,
            finalization: .init(text: text, secureInputActive: secureInputActive, isHUDOnly: isHUDOnly),
            deadline: deadline
        )
        guard self.store === store, activeRetention != .off else { return .record(nil) }
        switch attempt {
        case .record(let record): return .record(record)
        case .failure(.recordLimitReached): return .recordLimitReached
        case .deadline, .failure: return .record(nil)
        }
    }

    func markDelivery(_ record: HistoryRecord?, state: HistoryDeliveryState) {
        guard let record else { return }
        Task { try? await store?.updateDeliveryState(id: record.id, to: state) }
    }

    @discardableResult
    func copy(_ record: HistoryRecord) -> Bool {
        NSPasteboard.general.clearContents()
        let didCopy = NSPasteboard.general.setString(record.text, forType: .string)
        if didCopy {
            announce("Dictation copied to the clipboard.")
        } else {
            errorMessage = "Couldn’t copy this dictation."
            announce("Couldn’t copy this dictation.")
        }
        return didCopy
    }

    func delete(_ record: HistoryRecord) {
        Task { await performDelete(record) }
    }

    private func performDelete(_ record: HistoryRecord) async {
        do {
            _ = try await store?.delete(id: record.id)
            await refresh()
            await refreshRecordLimitState()
        } catch is HistoryCommittedCleanupFailure {
            invalidatePresentationAfterCommittedCleanupFailure(.singleDelete)
            errorMessage = "This dictation was removed, but Saymark could not finish cleaning its local database."
        } catch {
            errorMessage = "Couldn’t delete this dictation."
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
              (allowSelfReinsertTargetForTesting ||
               target.processIdentifier != ProcessInfo.processInfo.processIdentifier)
        else { showReinsertFallback(record, message: "That app is no longer available. The text was copied instead."); return }
        guard reinsertAccessibilityTrusted() else {
            showReinsertFallback(record, message: "Accessibility is needed to reinsert. The text was copied.")
            return
        }
        guard !reinsertSecureInputActive() else {
            showReinsertFallback(record, message: "The current field is protected. The text was copied.")
            return
        }
        let expectedPID = target.processIdentifier
        window?.orderOut(nil)
        reinsertActivate(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + reinsertDelay) { [weak self, weak target] in
            guard let self, let target,
                  !target.isTerminated,
                  target.processIdentifier == expectedPID,
                  self.reinsertFrontmostPID() == expectedPID
            else {
                self?.showReinsertFallback(record, message: "That app is no longer active. The text was copied instead.")
                return
            }
            guard !self.reinsertSecureInputActive() else {
                self.showReinsertFallback(record, message: "The current field is protected. The text was copied.")
                return
            }
            switch self.reinsertPaste(record.text) {
            case .pasted:
                errorMessage = "Reinserted into \(target.localizedName ?? "the selected app")."
                self.announce("Dictation reinserted.")
            case .copiedSecureInput:
                self.showReinsertFallback(record, message: "Field is protected. The text was copied.")
            case .copiedTargetChanged, .deliveryUnconfirmed, .failed:
                self.showReinsertFallback(record, message: "Couldn’t paste text. The text was copied.")
            }
        }
    }

    private func showReinsertFallback(_ record: HistoryRecord, message: String) {
        let didCopy = copy(record)
        errorMessage = didCopy ? message : "Couldn’t paste or copy this dictation."
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        announce(errorMessage ?? message)
    }

    private func announce(_ message: String) {
        if let window {
            NSAccessibility.post(
                element: window,
                notification: .announcementRequested,
                userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        } else {
            announcementSink(message)
        }
    }

    private func makeStore(_ retention: RecentDictationsRetention) throws -> SQLiteHistoryStore {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.eloe.saymark"
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("RecentDictations", isDirectory: true)
        return try SQLiteHistoryStore(directoryURL: root, policy: retention.historyPolicy)
    }

    private func reconcileToDurablePolicy(
        mirrorDefaults: Bool = true,
        publishAvailability: Bool = true
    ) async {
        guard let store else {
            activeRetention = .off
            isHistoryAvailable = false
            clearRecordLimitState()
            return
        }
        do {
            let durable = try await store.durableRetentionPolicy()
            activeRetention = RecentDictationsRetention(durable)
            if mirrorDefaults {
                UserDefaults.standard.set(activeRetention.rawValue, forKey: RecentDictationsRetention.defaultsKey)
            }
            isHistoryAvailable = publishAvailability && activeRetention != .off
            await refreshRecordLimitState()
        } catch {
            activeRetention = .off
            isHistoryAvailable = false
            clearRecordLimitState()
        }
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

    // These remain internal: Release tests built with ENABLE_TESTABILITY can
    // reach them through @testable import, while distributable builds do not
    // expose them outside the Saymark module.
    func makeWindowForTesting() -> NSWindow { makeWindow() }
    func setPreviousApplicationForTesting(_ application: NSRunningApplication?) {
        previousApplication = application
    }

    func setRecordsForTesting(_ records: [HistoryRecord]) {
        resultLimit = 20
        hasMoreResults = records.count > resultLimit
        self.records = Array(records.prefix(resultLimit))
    }

    func setHistoryAvailableForTesting(_ available: Bool) {
        isHistoryAvailable = available
    }

    func configureStoreForTesting(
        _ store: SQLiteHistoryStore?,
        retention: RecentDictationsRetention,
        startupComplete: Bool = true
    ) {
        self.store = store
        activeRetention = retention
        isStartupComplete = startupComplete
        isHistoryAvailable = retention != .off
        clearRecordLimitState()
    }

    func clearHistoryForTesting() async {
        await performClearHistory()
    }

    func deleteForTesting(_ record: HistoryRecord) async {
        await performDelete(record)
    }

    func purgeExpiredForTesting() async {
        await performExpiryCleanup()
    }

    func resetReinsertSeamsForTesting() {
        reinsertAccessibilityTrusted = { Accessibility.isTrusted }
        reinsertSecureInputActive = { TextInjector.secureInputActive }
        reinsertActivate = { $0.activate(options: [.activateIgnoringOtherApps]) }
        reinsertFrontmostPID = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        reinsertPaste = { TextInjector.paste($0) }
        reinsertDelay = 0.5
        allowSelfReinsertTargetForTesting = false
        announcementSink = { message in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
    }
    func windowWillClose(_ notification: Notification) {
        // Do not keep search terms, selected text, records, or the destination
        // PID alive after the private history window is dismissed.
        refreshGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        searchCancellation?.interrupt()
        searchCancellation = nil
        records = []
        resultSummary = "0 results"
        query = ""
        resultLimit = 20
        hasMoreResults = false
        previousApplication = nil
        pendingReinsert = nil
        pendingDeletion = nil
        errorMessage = nil
        window = nil
    }

    func invalidatePresentationAfterCommittedCleanupFailure(_: CommittedCleanupPath) {
        refreshGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        searchCancellation?.interrupt()
        searchCancellation = nil
        records = []
        query = ""
        resultSummary = "0 results"
        resultLimit = 20
        hasMoreResults = false
        pendingReinsert = nil
        pendingDeletion = nil
        previousApplication = nil
        isHistoryAvailable = false
        clearRecordLimitState()
        window?.orderOut(nil)
        window = nil
    }

    private func recordBeforeDelivery(
        store: SQLiteHistoryStore,
        finalization: HistoryFinalization,
        deadline: UInt64
    ) async -> RecordAttempt {
        // Do not use a task group here: structured concurrency waits for every
        // child at scope exit, which would turn a late SQLite actor turn into a
        // delivery-path stall. The store's deadline is the commit authority;
        // this race merely returns control to final delivery on time.
        await withCheckedContinuation { continuation in
            let gate = RecordDeadlineGate()
            // This token belongs to this one request, even while its actor
            // turn is queued. Its deadline can therefore never interrupt an
            // unrelated active history write.
            let cancellation = HistoryWriteCancellation()
            Task.detached(priority: .userInitiated) { [weak self] in
                let result: RecordAttempt
                do {
                    result = .record(try await store.recordFinal(
                        finalization,
                        deadlineUptimeNanoseconds: deadline,
                        cancellation: cancellation
                    ))
                } catch {
                    result = .failure(error as? HistoryStoreError)
                }
                guard gate.resolve(continuation, with: result) else { return }
                await self?.applyRecordAttempt(result, sourceStore: store)
            }
            Task.detached(priority: .userInitiated) { [weak self] in
                let remaining = deadline > DispatchTime.now().uptimeNanoseconds
                    ? deadline - DispatchTime.now().uptimeNanoseconds : 0
                try? await Task.sleep(nanoseconds: remaining)
                let result: RecordAttempt = .deadline
                guard gate.resolve(continuation, with: result, beforeResume: {
                    // This is deliberately nonisolated: a synchronous SQLite
                    // call occupies the history actor. The per-operation
                    // token interrupts only this write if it is already active.
                    cancellation.interrupt()
                }) else { return }
                await self?.applyRecordAttempt(result, sourceStore: store)
            }
        }
    }

    private func applyRecordAttempt(_ result: RecordAttempt, sourceStore: SQLiteHistoryStore) {
        guard store === sourceStore, activeRetention != .off else { return }
        switch result {
        case .record(let record):
            if record != nil {
                SaymarkDiagnostics.logHistoryOperation(.insert, outcome: .success)
                Task { await refreshRecordLimitState() }
            }
        case .deadline:
            SaymarkDiagnostics.logHistoryOperation(.insert, outcome: .deadlineExceeded)
            errorMessage = "Recent Dictations was skipped to keep dictation instant."
        case .failure(let error):
            switch error {
            case .some(.recordLimitReached):
                SaymarkDiagnostics.logHistoryOperation(.insert, outcome: .recordLimitReached)
                capacityGeneration &+= 1
                isAtRecordLimit = true
                errorMessage = Self.recordLimitMessage
            case .some(.recordTooLarge):
                SaymarkDiagnostics.logHistoryOperation(.insert, outcome: .recordTooLarge)
                errorMessage = "This dictation is too large to save in Recent Dictations."
            case .some(.deadlineExceeded):
                SaymarkDiagnostics.logHistoryOperation(.insert, outcome: .deadlineExceeded)
                errorMessage = "Recent Dictations was skipped to keep dictation instant."
            default:
                SaymarkDiagnostics.logHistoryOperation(.insert, outcome: .unavailable)
                errorMessage = "Recent Dictations is temporarily unavailable."
            }
        }
    }

    private func refreshRecordLimitState() async {
        capacityGeneration &+= 1
        let requestedGeneration = capacityGeneration
        guard let requestedStore = store, activeRetention != .off else {
            clearRecordLimitState()
            return
        }
        do {
            let isFull = try await requestedStore.isAtRecordLimit()
            guard requestedGeneration == capacityGeneration,
                  store === requestedStore,
                  activeRetention != .off
            else { return }
            isAtRecordLimit = isFull
            if !isFull, errorMessage == Self.recordLimitMessage { errorMessage = nil }
        } catch {
            guard requestedGeneration == capacityGeneration,
                  store === requestedStore
            else { return }
            // Unavailable storage is not proof that 10,000 rows exist. Its
            // separate availability/error state remains authoritative.
            clearRecordLimitState()
        }
    }

    private func clearRecordLimitState() {
        capacityGeneration &+= 1
        isAtRecordLimit = false
        if errorMessage == Self.recordLimitMessage { errorMessage = nil }
    }
}

private enum RecordAttempt: Sendable {
    case record(HistoryRecord?)
    case deadline
    case failure(HistoryStoreError?)
}

enum HistoryPersistenceOutcome: Sendable {
    case record(HistoryRecord?)
    case recordLimitReached

    var record: HistoryRecord? {
        guard case .record(let record) = self else { return nil }
        return record
    }
}

/// A one-shot lock keeps the 100 ms caller result independent of a queued
/// writer task. It does not cancel SQLite; `recordFinal` owns rollback and the
/// no-late-commit deadline check before resuming the late worker.
private final class RecordDeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func resolve(
        _ continuation: CheckedContinuation<RecordAttempt, Never>,
        with result: RecordAttempt,
        beforeResume: () -> Void = {}
    ) -> Bool {
        let didWin = lock.withLock {
            guard !resolved else { return false }
            resolved = true
            return true
        }
        guard didWin else { return false }
        beforeResume()
        continuation.resume(returning: result)
        return true
    }
}

private extension RecentDictationsRetention {
    init(_ policy: HistoryRetentionPolicy) {
        switch policy {
        case .off: self = .off
        case .session: self = .session
        case .days7: self = .days7
        case .days30: self = .days30
        case .days90: self = .days90
        case .untilDeleted: self = .untilDeleted
        }
    }

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
