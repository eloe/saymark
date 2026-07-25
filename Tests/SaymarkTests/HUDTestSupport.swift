import AppKit
@testable import Saymark

@MainActor
final class ManualHUDScheduler: HUDHideScheduling {
    struct Entry {
        let delay: TimeInterval
        let action: @MainActor () -> Void
        let cancellation: HUDCancellation
    }

    private(set) var entries: [Entry] = []

    func schedule(after delay: TimeInterval,
                  action: @escaping @MainActor () -> Void) -> HUDCancellation {
        let cancellation = HUDCancellation {}
        entries.append(Entry(delay: delay, action: action, cancellation: cancellation))
        return cancellation
    }

    func fire(_ index: Int, evenIfCancelled: Bool = false) {
        let entry = entries[index]
        guard evenIfCancelled || !entry.cancellation.isCancelled else { return }
        entry.action()
    }
}

@MainActor
final class ManualHUDAnimator: HUDAnimating {
    private(set) var shownPanels: [NSPanel] = []
    private(set) var hiddenPanels: [NSPanel] = []
    private var hideCompletions: [@MainActor () -> Void] = []

    func show(_ panel: NSPanel) {
        panel.alphaValue = 1
        shownPanels.append(panel)
    }

    func hide(_ panel: NSPanel, completion: @escaping @MainActor () -> Void) {
        panel.alphaValue = 0
        hiddenPanels.append(panel)
        hideCompletions.append(completion)
    }

    func completeHide(_ index: Int = 0) {
        hideCompletions[index]()
    }
}

@MainActor
final class ManualListeningHalo: ListeningHaloControlling {
    private(set) var beginCount = 0
    private(set) var stopCount = 0
    private(set) var completeCount = 0
    private(set) var dismissCount = 0

    func begin(on screen: NSScreen?) { beginCount += 1 }
    func stopListening() { stopCount += 1 }
    func complete() { completeCount += 1 }
    func dismiss() { dismissCount += 1 }
}

@MainActor
func makeHUDController() -> (HUDController, ManualHUDScheduler, ManualHUDAnimator) {
    let scheduler = ManualHUDScheduler()
    let animator = ManualHUDAnimator()
    let halo = ManualListeningHalo()
    return (
        HUDController(scheduler: scheduler, animator: animator, halo: halo),
        scheduler,
        animator
    )
}

@MainActor
func tearDownHUD(_ controller: HUDController) {
    controller.panel?.orderOut(nil)
    controller.panel?.contentView = nil
}

@MainActor
func waitForHUDCondition(timeout: Duration = .seconds(3),
                         _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
