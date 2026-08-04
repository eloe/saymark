import AppKit
import Testing
@testable import KeyboardShortcuts

@MainActor
@Suite struct RecorderTraversalTests {
	@Test
	func testTabAndShiftTabTraverseExplicitKeyViewNeighbors() {
		let previous = TestKeyView()
		let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("traversal-test"))
		let next = TestKeyView()
		let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
		content.addSubview(previous)
		content.addSubview(recorder)
		content.addSubview(next)
		previous.nextKeyView = recorder
		recorder.nextKeyView = next
		next.nextKeyView = previous
		let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
		window.contentView = content
		defer { window.orderOut(nil) }

		#expect(window.makeFirstResponder(recorder))
		#expect(recorder.traverseForTab(event(modifiers: [], window: window)))
		#expect(window.firstResponder === next)

		#expect(window.makeFirstResponder(recorder))
		#expect(recorder.traverseForTab(event(modifiers: [.shift], window: window)))
		#expect(window.firstResponder === previous)

		#expect(window.makeFirstResponder(recorder))
		#expect(!recorder.traverseForTab(event(modifiers: [.control], window: window)))
		#expect(window.firstResponder === recorder.currentEditor())
	}

	@Test
	func testTraversalTabWithoutAValidNeighborIsConsumedAndEndsRecording() {
		let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("traversal-fallback-test"))
		let content = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 100))
		content.addSubview(recorder)
		let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
		window.contentView = content
		defer { window.orderOut(nil) }

		#expect(window.makeFirstResponder(recorder))
		#expect(recorder.traverseForTab(event(modifiers: [], window: window)))
		#expect(recorder.currentEditor() == nil)
		#expect(window.firstResponder !== recorder)

		#expect(window.makeFirstResponder(recorder))
		#expect(recorder.traverseForTab(event(modifiers: [.shift], window: window)))
		#expect(recorder.currentEditor() == nil)
		#expect(window.firstResponder !== recorder)
	}

	@Test
	func testIdleFieldEditorRoutesBacktabToBoundaryHandler() {
		let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("idle-traversal-test"))
		var handoffCount = 0
		recorder.onReverseTabTraversal = { handoffCount += 1 }

		let handled = recorder.control(
			recorder,
			textView: NSTextView(),
			doCommandBy: #selector(NSResponder.insertBacktab(_:))
		)

		#expect(handled)
		#expect(handoffCount == 1)
	}

	private func event(modifiers: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent {
		let characters = modifiers.contains(.shift) ? "\u{19}" : "\t"
		return NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: modifiers,
			timestamp: 0,
			windowNumber: window.windowNumber,
			context: nil,
			characters: characters,
			charactersIgnoringModifiers: characters,
			isARepeat: false,
			keyCode: 48
		)!
	}

	private final class TestKeyView: NSView {
		override var acceptsFirstResponder: Bool { true }
		override var canBecomeKeyView: Bool { true }
	}
}
