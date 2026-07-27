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
    private var store: SQLiteHistoryStore?
    private var window: NSWindow?
    private var previousApplication: NSRunningApplication?

    private override init() {}

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
        Task {
            guard let store else { return }
            try? await store.clear()
        }
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
                records = []
                SaymarkDiagnostics.logHistoryOperation(.clear, outcome: .committed)
            } catch {
                SaymarkDiagnostics.logHistoryOperation(.clear, outcome: .unavailable)
                errorMessage = "Couldn’t clear Recent Dictations."
            }
        }
    }

    func refresh(query: String? = nil) async {
        if let query { self.query = query }
        do {
            if store == nil, RecentDictationsRetention.current != .off {
                store = try makeStore(RecentDictationsRetention.current)
            }
            records = try await store?.records(query: self.query, limit: 20) ?? []
        } catch {
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
            if store == nil { store = try makeStore(RecentDictationsRetention.current) }
            guard let store else { return nil }
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

    /// Reinsert deliberately targets the app that was frontmost before the
    /// history window was opened, never Saymark's own search field.
    func requestReinsert(_ record: HistoryRecord) {
        pendingReinsert = record
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
        else { errorMessage = "That app is no longer available. Copy the text instead."; return }
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
            case .pasted: break
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
        records = []
        query = ""
        previousApplication = nil
        pendingReinsert = nil
        errorMessage = nil
        window = nil
    }

    private func recordBeforeDelivery(
        store: SQLiteHistoryStore,
        finalization: HistoryFinalization,
        deadline: UInt64
    ) async -> HistoryRecord? {
        await withTaskGroup(of: RecordAttempt.self, returning: HistoryRecord?.self) { group in
            group.addTask {
                do { return .record(try await store.recordFinal(finalization, deadlineUptimeNanoseconds: deadline)) }
                catch { return .failure(error as? HistoryStoreError) }
            }
            group.addTask {
                let remaining = deadline > DispatchTime.now().uptimeNanoseconds
                    ? deadline - DispatchTime.now().uptimeNanoseconds : 0
                try? await Task.sleep(nanoseconds: remaining)
                return .deadline
            }
            guard let first = await group.next() else { return nil }
            group.cancelAll()
            switch first {
            case .record(let record): return record
            case .deadline:
                SaymarkDiagnostics.logHistoryOperation(.record, outcome: .deadlineExceeded)
                errorMessage = "Recent Dictations was skipped to keep dictation instant."
                return nil
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
                return nil
            }
        }
    }
}

private enum RecordAttempt: Sendable {
    case record(HistoryRecord?)
    case deadline
    case failure(HistoryStoreError?)
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
