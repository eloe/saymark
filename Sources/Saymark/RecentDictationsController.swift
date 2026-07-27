import AppKit
import Foundation
import Observation
import SaymarkKit

/// Main-actor bridge for the private Recent Dictations window. Transcript text
/// stays in the store/window; it is never placed in diagnostics or telemetry.
@MainActor
@Observable
final class RecentDictationsController {
    static let shared = RecentDictationsController()

    private(set) var records: [HistoryRecord] = []
    private(set) var query = ""
    private(set) var errorMessage: String?
    private var store: SQLiteHistoryStore?
    private var window: NSWindow?
    private var previousApplication: NSRunningApplication?

    private init() {}

    func setRetention(_ retention: RecentDictationsRetention) {
        UserDefaults.standard.set(retention.rawValue, forKey: RecentDictationsRetention.defaultsKey)
        Task {
            do {
                if retention == .off {
                    if let store { try await store.setRetentionPolicy(.off) }
                    store = nil
                    records = []
                    return
                }
                let store = try makeStore(retention)
                self.store = store
                try await store.setRetentionPolicy(retention.historyPolicy)
                await refresh()
            } catch {
                errorMessage = "Recent Dictations is unavailable on this Mac."
            }
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
            } catch {
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
            return try await store?.recordFinal(.init(
                text: text,
                secureInputActive: secureInputActive,
                isHUDOnly: isHUDOnly
            ))
        } catch {
            // History is deliberately fail-open: no persistence error is allowed
            // to suppress the user's final delivery.
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
    func reinsert(_ record: HistoryRecord) {
        guard let target = previousApplication,
              !target.isTerminated,
              target.processIdentifier > 0
        else { errorMessage = "That app is no longer available. Copy the text instead."; return }
        let expectedPID = target.processIdentifier
        window?.orderOut(nil)
        target.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak target] in
            guard let self, let target,
                  !target.isTerminated,
                  target.processIdentifier == expectedPID,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID
            else { self?.errorMessage = "That app is no longer active. Copy the text instead."; return }
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
        window.setContentSize(NSSize(width: 720, height: 480))
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.center()
        return window
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
