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

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("saymark-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }
}
