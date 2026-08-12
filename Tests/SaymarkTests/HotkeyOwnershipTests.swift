import XCTest
import SaymarkKit
import KeyboardShortcuts
@testable import Saymark

@MainActor
final class HotkeyOwnershipTests: XCTestCase {
    func testHostedUnitTestDetectionPreventsTemporaryAppPermissionPrompts() {
        XCTAssertTrue(RuntimeEnvironment.isHostedUnitTesting(environment: [
            "XCTestConfigurationFilePath": "/tmp/SaymarkTests.xctestconfiguration",
        ]))
        XCTAssertTrue(RuntimeEnvironment.isHostedUnitTesting(environment: [
            "XCInjectBundleInto": "/tmp/Saymark.app/Contents/MacOS/Saymark",
        ]))
        XCTAssertFalse(RuntimeEnvironment.isHostedUnitTesting(environment: [:]))
    }

    func testRecordingStartAdmissionRejectsDuplicateAndDefersEarlyStop() {
        var admission = RecordingStartAdmission()

        XCTAssertTrue(admission.begin())
        XCTAssertEqual(admission.phase, .starting)
        XCTAssertFalse(admission.begin(), "a duplicate hotkey must not admit a second startup")
        XCTAssertFalse(admission.requestStop(), "startup cannot be stopped until capture is active")
        XCTAssertTrue(admission.stopRequestedWhileStarting)
        XCTAssertTrue(admission.started(), "the deferred release must stop immediately after startup")
        XCTAssertEqual(admission.phase, .recording)
        XCTAssertTrue(admission.requestStop())

        admission.reset()
        XCTAssertEqual(admission.phase, .idle)
        XCTAssertTrue(admission.begin(), "rollback must allow the next gesture")
    }

    func testRecordingStartAdmissionFailureRollbackClearsDeferredStop() {
        var admission = RecordingStartAdmission()
        XCTAssertTrue(admission.begin())
        XCTAssertFalse(admission.requestStop())

        admission.reset()

        XCTAssertEqual(admission.phase, .idle)
        XCTAssertFalse(admission.stopRequestedWhileStarting)
        XCTAssertTrue(admission.begin())
        XCTAssertFalse(admission.started())
    }

    func testLegacyVoiceOverConflictMigratesOnlyOnceAndOnlyWhenUnchanged() {
        XCTAssertTrue(DictationShortcutDefaults.shouldMigrate(
            current: DictationShortcutDefaults.legacyVoiceOverConflict,
            migrationCompleted: false
        ))
        XCTAssertFalse(DictationShortcutDefaults.shouldMigrate(
            current: DictationShortcutDefaults.legacyVoiceOverConflict,
            migrationCompleted: true
        ))
        XCTAssertFalse(DictationShortcutDefaults.shouldMigrate(
            current: .init(.d, modifiers: [.command, .shift]),
            migrationCompleted: false
        ))
        XCTAssertFalse(DictationShortcutDefaults.shouldMigrate(
            current: nil,
            migrationCompleted: false
        ))
    }

    func testOnboardingHandoffIsIdempotentAndCanBeReclaimed() {
        let controller = DictationController()

        XCTAssertEqual(controller.hotkeyOwner, .runtime)

        var handoffs = 0
        controller.handOffHotkeyToOnboarding { handoffs += 1 }
        controller.handOffHotkeyToOnboarding { handoffs += 1 }
        XCTAssertEqual(controller.hotkeyOwner, .onboarding)
        XCTAssertEqual(handoffs, 2)

        controller.reclaimHotkeyFromOnboarding()
        XCTAssertEqual(controller.hotkeyOwner, .runtime)
    }

    func testOnboardingHotkeyCannotStartCaptureOutsideTryItStep() {
        let controller = DictationController()
        let onboarding = OnboardingModel(session: controller.dictationSession)
        onboarding.modelsReady = true

        for step in [
            OnboardingFlow.Step.welcome,
            .permissions,
            .shortcut,
            .download,
            .done,
        ] {
            onboarding.flow.step = step
            onboarding.tryHotkeyDown()
            XCTAssertFalse(onboarding.tryListening, "capture started on \(step)")
        }
    }
}
