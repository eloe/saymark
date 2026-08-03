import AppKit
import XCTest
@testable @_spi(Testing) import SaymarkKit

@MainActor
final class TextInjectorTests: XCTestCase {
    func testAtomicPasteRestoresOriginalClipboardAfterTargetReadsExactlyOnce() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        var received: [String] = []

        let restored = expectation(description: "clipboard restored")
        let result = TextInjector.pasteForTesting(
            "transcript ",
            pasteboard: pasteboard,
            restoreDelay: 0.001,
            postPaste: {
                received.append(pasteboard.string(forType: .string) ?? "")
                return true
            },
            onRestore: { outcome in
                XCTAssertEqual(outcome, .restoredOriginal)
                restored.fulfill()
            }
        )

        XCTAssertEqual(result, .pasted)
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertEqual(received, ["transcript "])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testDelayedRestorePreservesNewerUserClipboardCopy() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)

        let preserved = expectation(description: "newer clipboard preserved")
        let result = TextInjector.pasteForTesting(
            "transcript ",
            pasteboard: pasteboard,
            restoreDelay: 0.001,
            postPaste: {
                pasteboard.clearContents()
                pasteboard.setString("newer-user-copy", forType: .string)
                return true
            },
            onRestore: { outcome in
                XCTAssertEqual(outcome, .preservedNewerClipboard)
                preserved.fulfill()
            }
        )

        XCTAssertEqual(result, .pasted)
        await fulfillment(of: [preserved], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer-user-copy")
    }

    func testSecureInputCopiesTranscriptWithoutPostingPaste() {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        var postCount = 0

        let result = TextInjector.pasteForTesting(
            "transcript ",
            pasteboard: pasteboard,
            secureInputActive: true,
            postPaste: {
                postCount += 1
                return true
            }
        )

        XCTAssertEqual(result, .copiedSecureInput)
        XCTAssertEqual(postCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript ")
    }

    func testFailedPasteLeavesTranscriptAvailableForManualRecovery() {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)

        let result = TextInjector.pasteForTesting(
            "transcript ",
            pasteboard: pasteboard,
            postPaste: { false }
        )

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript ")
    }

    func testFocusChangeAfterClipboardSnapshotDoesNotPostPaste() {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        var postCount = 0

        let result = TextInjector.pasteForTesting(
            "transcript ",
            pasteboard: pasteboard,
            postPaste: {
                postCount += 1
                return true
            },
            targetIsCurrent: { false }
        )

        XCTAssertEqual(result, .copiedTargetChanged)
        XCTAssertEqual(postCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript ")
    }

    func testAcknowledgedPasteRestoresOnlyAfterExactCaretReceipt() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        var postCount = 0

        let result = await TextInjector.pasteAcknowledgedForTesting(
            "transcript ",
            pasteboard: pasteboard,
            postPaste: { postCount += 1; return true },
            targetIsCurrent: { true },
            targetStillPresent: { true },
            targetAcknowledged: { true }
        )

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testAXReceiptWorkRunsOffMainActor() async {
        let pasteboard = makePasteboard()
        let validation = expectation(description: "off-main validation")
        let acknowledgement = expectation(description: "off-main acknowledgement")

        let result = await TextInjector.pasteAcknowledgedForTesting(
            "transcript ",
            pasteboard: pasteboard,
            postPaste: { true },
            targetIsCurrent: {
                XCTAssertFalse(Thread.isMainThread)
                validation.fulfill()
                return true
            },
            targetStillPresent: { true },
            targetAcknowledged: {
                XCTAssertFalse(Thread.isMainThread)
                acknowledgement.fulfill()
                return true
            }
        )

        await fulfillment(of: [validation, acknowledgement], timeout: 1)
        XCTAssertEqual(result, .pasted)
    }

    func testTimedOutTargetValidationCanNeverPostPasteLater() async {
        let pasteboard = makePasteboard()
        let lock = NSLock()
        var postCount = 0

        let result = await TextInjector.pasteAcknowledgedForTesting(
            "transcript ",
            pasteboard: pasteboard,
            postPaste: { lock.withLock { postCount += 1 }; return true },
            targetIsCurrent: {
                Thread.sleep(forTimeInterval: 0.08)
                return true
            },
            targetStillPresent: { true },
            targetAcknowledged: { true },
            probeTimeout: 0.01
        )

        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(result, .copiedTargetChanged)
        XCTAssertEqual(lock.withLock { postCount }, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript ")
    }

    func testSecureInputTransitionDuringValidationPreventsPasteDispatch() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        let lock = NSLock()
        var deliveryAllowed = true
        var postCount = 0

        let result = await TextInjector.pasteAcknowledgedForTesting(
            "transcript ",
            pasteboard: pasteboard,
            postPaste: { lock.withLock { postCount += 1 }; return true },
            targetIsCurrent: {
                lock.withLock { deliveryAllowed = false }
                return true
            },
            targetStillPresent: { true },
            deliveryStillAllowed: { lock.withLock { deliveryAllowed } },
            targetAcknowledged: { true }
        )

        XCTAssertEqual(result, .deliveryUnconfirmed)
        XCTAssertEqual(lock.withLock { postCount }, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript ")
    }

    func testSecureInputTransitionAfterPasteNeverRestoresOrRetries() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        let lock = NSLock()
        var deliveryAllowed = true
        var postCount = 0
        var acknowledgementCount = 0

        let result = await TextInjector.pasteAcknowledgedForTesting(
            "transcript ",
            pasteboard: pasteboard,
            postPaste: {
                lock.withLock {
                    postCount += 1
                    deliveryAllowed = false
                }
                return true
            },
            targetIsCurrent: { true },
            targetStillPresent: { true },
            deliveryStillAllowed: { lock.withLock { deliveryAllowed } },
            targetAcknowledged: {
                lock.withLock { acknowledgementCount += 1 }
                return true
            }
        )

        XCTAssertEqual(result, .deliveryUnconfirmed)
        XCTAssertEqual(lock.withLock { postCount }, 1)
        XCTAssertEqual(lock.withLock { acknowledgementCount }, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript ")
    }

    func testHungAXReceiptFailsClosedAtCoordinatorDeadline() async {
        let pasteboard = makePasteboard()
        let started = ProcessInfo.processInfo.systemUptime

        let result = await TextInjector.pasteAcknowledgedForTesting(
            "transcript ",
            pasteboard: pasteboard,
            timeout: 0.5,
            postPaste: { true },
            targetIsCurrent: { true },
            targetStillPresent: { true },
            targetAcknowledged: {
                Thread.sleep(forTimeInterval: 0.4)
                return true
            },
            probeTimeout: 0.02
        )

        XCTAssertEqual(result, .deliveryUnconfirmed)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.2)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript ")
    }

    func testLongFinalCanAcknowledgeWithBoundedReceiptProbe() async {
        let pasteboard = makePasteboard()
        let lock = NSLock()
        var acknowledgementReads = 0

        let result = await TextInjector.pasteAcknowledgedForTesting(
            String(repeating: "a", count: 65),
            pasteboard: pasteboard,
            postPaste: { true },
            targetIsCurrent: { true },
            targetStillPresent: { true },
            targetAcknowledged: {
                lock.withLock { acknowledgementReads += 1 }
                return true
            }
        )

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(lock.withLock { acknowledgementReads }, 1)
    }

    func testReceiptRequiresExactInsertedContentNotOnlySameLengthCaretMovement() {
        let original = CFRange(location: 4, length: 3)
        let caret = CFRange(location: 8, length: 0)

        XCTAssertTrue(FocusedInsertionLease.receiptMatches(
            originalRange: original,
            insertedText: "word",
            currentRange: caret,
            observedText: "word"
        ))
        XCTAssertFalse(FocusedInsertionLease.receiptMatches(
            originalRange: original,
            insertedText: "word",
            currentRange: caret,
            observedText: "same"
        ))

        let longText = String(repeating: "a", count: 65)
        XCTAssertTrue(FocusedInsertionLease.receiptMatches(
            originalRange: .init(location: 0, length: 0),
            insertedText: longText,
            currentRange: .init(location: 65, length: 0),
            observedText: String(repeating: "a", count: 64)
        ))
        XCTAssertFalse(FocusedInsertionLease.receiptMatches(
            originalRange: .init(location: 0, length: 0),
            insertedText: longText,
            currentRange: .init(location: 65, length: 0),
            observedText: String(repeating: "b", count: 64)
        ))
    }

    func testUnacknowledgedPasteTimesOutWithTranscriptStillRecoverable() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)

        let result = await TextInjector.pasteAcknowledgedForTesting(
            "transcript ",
            pasteboard: pasteboard,
            timeout: 0.001,
            postPaste: { true },
            targetIsCurrent: { true },
            targetStillPresent: { true },
            targetAcknowledged: { false }
        )

        XCTAssertEqual(result, .deliveryUnconfirmed)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript ")
    }

    func testTargetLossAfterPasteEventNeverReportsSuccessOrRestores() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        let lock = NSLock()
        var postCount = 0

        let result = await TextInjector.pasteAcknowledgedForTesting(
            "transcript ",
            pasteboard: pasteboard,
            postPaste: { lock.withLock { postCount += 1 }; return true },
            targetIsCurrent: { true },
            targetStillPresent: { false },
            targetAcknowledged: { false }
        )

        XCTAssertEqual(result, .deliveryUnconfirmed)
        XCTAssertEqual(lock.withLock { postCount }, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript ")
    }

    func testNewerClipboardDuringAcknowledgementIsPreservedAndUnconfirmed() async {
        let pasteboard = makePasteboard()
        pasteboard.setString("original", forType: .string)
        let lock = NSLock()
        var postCount = 0

        let result = await TextInjector.pasteAcknowledgedForTesting(
            "transcript ",
            pasteboard: pasteboard,
            postPaste: { lock.withLock { postCount += 1 }; return true },
            targetIsCurrent: {
                pasteboard.clearContents()
                pasteboard.setString("newer-user-copy", forType: .string)
                return true
            },
            targetStillPresent: { true },
            targetAcknowledged: { true }
        )

        XCTAssertEqual(result, .deliveryUnconfirmed)
        XCTAssertEqual(lock.withLock { postCount }, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer-user-copy")
    }

    func testConcealedAndTransientItemsAreNeverRepublished() async {
        for markerName in [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
        ] {
            let pasteboard = makePasteboard()
            let markedItem = NSPasteboardItem()
            markedItem.setString("nonpersistent-fixture", forType: .string)
            markedItem.setData(Data(), forType: .init(markerName))
            let unmarkedSibling = NSPasteboardItem()
            unmarkedSibling.setString("alternate-fixture", forType: .string)
            XCTAssertTrue(pasteboard.writeObjects([markedItem, unmarkedSibling]))

            let restored = expectation(description: "\(markerName) filtered")
            let result = TextInjector.pasteForTesting(
                "transcript ",
                pasteboard: pasteboard,
                restoreDelay: 0.001,
                postPaste: { true },
                onRestore: { outcome in
                    XCTAssertEqual(outcome, .restoredOriginal)
                    restored.fulfill()
                }
            )

            XCTAssertEqual(result, .pasted)
            await fulfillment(of: [restored], timeout: 1)
            XCTAssertNil(pasteboard.string(forType: .string))
            XCTAssertFalse(pasteboard.types?.contains(.init(markerName)) ?? false)
            XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
        }
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("saymark-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}
