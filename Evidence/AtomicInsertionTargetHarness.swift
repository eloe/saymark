import AppKit
import ApplicationServices
import Darwin
import Foundation

@main
@MainActor
struct AtomicInsertionTargetHarness {
    private struct Options {
        var repetitions = 10
        var countdown = 5
        var control = "default"
        var revision = "unknown"
    }

    private struct TargetIdentity {
        let name: String
        let bundleID: String
        let version: String
        let build: String
        let role: String
        let subrole: String
    }

    @MainActor
    private struct TargetBinding {
        let element: AXUIElement
        let processID: pid_t
        let identity: TargetIdentity

        var isFocused: Bool {
            guard let current = AtomicInsertionTargetHarness.focusedElement() else { return false }
            var currentPID: pid_t = 0
            return AXUIElementGetPid(current, &currentPID) == .success
                && currentPID == processID
                && CFEqual(element, current)
        }
    }

    static func main() async {
        let options: Options
        do {
            options = try parseOptions()
        } catch {
            fputs("target-matrix: ERROR — \(error.localizedDescription)\n", stderr)
            usage()
            exit(64)
        }

        guard Accessibility.isTrusted else {
            _ = Accessibility.prompt()
            fputs(
                "target-matrix: BLOCKED — grant Accessibility to the displayed local harness, then rerun; no Apple Developer membership is required\n",
                stderr
            )
            exit(2)
        }

        print("target-matrix: PRIVACY — use only a blank document or synthetic field; the harness never prints field or clipboard contents")
        print("target-matrix: CLIPBOARD — this run replaces the current clipboard with a synthetic marker before testing")
        print("target-matrix: type YES to replace the clipboard and continue")
        guard readLine() == "YES" else {
            fputs("target-matrix: CANCELLED — clipboard was not changed\n", stderr)
            exit(1)
        }

        let pasteboard = NSPasteboard.general
        let clipboardMarker = "saymark-target-matrix-synthetic-clipboard"
        pasteboard.clearContents()
        guard pasteboard.setString(clipboardMarker, forType: .string) else {
            fputs("target-matrix: ERROR — could not establish the synthetic clipboard marker\n", stderr)
            exit(1)
        }

        print("target-matrix: ACTION — within \(options.countdown) seconds, focus the empty synthetic target field and leave the caret there")
        for remaining in stride(from: options.countdown, through: 1, by: -1) {
            print("target-matrix: countdown=\(remaining)")
            fflush(stdout)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        guard let target = focusedTargetBinding() else {
            emitEvidenceHeader(options, target: nil)
            emitEarlyResult(
                classification: "unclassified",
                reason: "target-identity-unavailable",
                clipboardMarker: clipboardMarker
            )
            exit(3)
        }
        emitEvidenceHeader(options, target: target)
        guard !TextInjector.secureInputActive else {
            emitEarlyResult(
                classification: "fallback-only",
                reason: "secure-input",
                clipboardMarker: clipboardMarker
            )
            exit(3)
        }
        guard let initialLease = FocusedInsertionLease.capture(),
              initialLease.isCurrent,
              target.isFocused
        else {
            emitEarlyResult(
                classification: "fallback-only",
                reason: "lease-unavailable",
                clipboardMarker: clipboardMarker
            )
            exit(3)
        }

        var timings: [Double] = []
        var failureReason: String?
        for repetition in 1...options.repetitions {
            guard target.isFocused,
                  let lease = FocusedInsertionLease.capture(),
                  lease.isCurrent,
                  target.isFocused
            else {
                failureReason = "target-changed"
                print("run.\(repetition).result=target-changed")
                break
            }
            let token = "saymark-matrix-\(repetition)-✓ "
            let started = ProcessInfo.processInfo.systemUptime
            let result = await TextInjector.pasteAcknowledged(token, targetLease: lease)
            let elapsedMS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            let clipboardRestored = pasteboard.string(forType: .string) == clipboardMarker
            print("run.\(repetition).result=\(resultName(result));ack_ms=\(format(elapsedMS));clipboard_restored=\(clipboardRestored)")
            guard result == .pasted, clipboardRestored else {
                failureReason = result == .pasted ? "clipboard-not-restored" : resultName(result)
                break
            }
            timings.append(elapsedMS)
        }

        if failureReason == nil, timings.count == options.repetitions {
            let ordered = timings.sorted()
            print("summary.result=certified-exact-once")
            print("summary.completed=\(timings.count)")
            print("summary.ack_median_ms=\(format(percentile(ordered, 0.50)))")
            print("summary.ack_p95_ms=\(format(percentile(ordered, 0.95)))")
            print("summary.ack_max_ms=\(format(ordered.last ?? 0))")
            print("summary.clipboard_restored=true")
            NSSound.beep()
            exit(0)
        }

        print("summary.result=fallback-only")
        print("summary.reason=\(failureReason ?? "incomplete")")
        print("summary.completed=\(timings.count)")
        print("summary.clipboard_restored=\(pasteboard.string(forType: .string) == clipboardMarker)")
        print("target-matrix: NOTE — a synthetic recovery token may remain on the clipboard after a fail-closed result")
        NSSound.beep()
        exit(3)
    }

    private static func emitEvidenceHeader(_ options: Options, target: TargetBinding?) {
        print("evidence.revision=\(options.revision)")
        print("evidence.date_utc=\(ISO8601DateFormatter().string(from: Date()))")
        print("environment.os=\(ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "\n", with: " "))")
        print("environment.hardware=\(commandOutput("/usr/sbin/sysctl", ["-n", "hw.model"]))")
        print("environment.architecture=\(commandOutput("/usr/bin/uname", ["-m"]))")
        print("target.name=\(safeMetadata(target?.identity.name ?? "unavailable"))")
        print("target.bundle_id=\(safeMetadata(target?.identity.bundleID ?? "unavailable"))")
        print("target.version=\(safeMetadata(target?.identity.version ?? "unavailable"))")
        print("target.build=\(safeMetadata(target?.identity.build ?? "unavailable"))")
        print("target.control=\(options.control)")
        print("target.ax_role=\(safeMetadata(target?.identity.role ?? "unavailable"))")
        print("target.ax_subrole=\(safeMetadata(target?.identity.subrole ?? "unavailable"))")
        print("target.repetitions_requested=\(options.repetitions)")
    }

    private static func emitEarlyResult(
        classification: String,
        reason: String,
        clipboardMarker: String
    ) {
        print("summary.result=\(classification)")
        print("summary.reason=\(reason)")
        print("summary.completed=0")
        print("summary.clipboard_restored=\(NSPasteboard.general.string(forType: .string) == clipboardMarker)")
        let label = classification == "unclassified" ? "UNCLASSIFIED" : "FALLBACK"
        fputs("target-matrix: \(label) — \(reason); no paste was attempted\n", stderr)
    }

    private static func parseOptions() throws -> Options {
        var options = Options()
        var arguments = Array(CommandLine.arguments.dropFirst())
        var seen = Set<String>()
        while !arguments.isEmpty {
            let flag = arguments.removeFirst()
            guard seen.insert(flag).inserted else { throw HarnessError.duplicateFlag(flag) }
            guard !arguments.isEmpty else { throw HarnessError.missingValue(flag) }
            let value = arguments.removeFirst()
            switch flag {
            case "--repetitions":
                guard let parsed = Int(value), (10...100).contains(parsed) else {
                    throw HarnessError.invalidValue(flag)
                }
                options.repetitions = parsed
            case "--countdown":
                guard let parsed = Int(value), (1...30).contains(parsed) else {
                    throw HarnessError.invalidValue(flag)
                }
                options.countdown = parsed
            case "--control":
                guard value.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
                    throw HarnessError.invalidValue(flag)
                }
                options.control = value
            case "--revision":
                guard value.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil else {
                    throw HarnessError.invalidValue(flag)
                }
                options.revision = value
            default:
                throw HarnessError.unknownFlag(flag)
            }
        }
        return options
    }

    private static func usage() {
        fputs("usage: run-atomic-insertion-target-evidence.sh [--control LABEL] [--repetitions 10] [--countdown 5]\n", stderr)
    }

    private static func focusedTargetBinding() -> TargetBinding? {
        guard let element = focusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              let bundleID = app.bundleIdentifier,
              !bundleID.isEmpty,
              let bundleURL = app.bundleURL,
              let bundle = Bundle(url: bundleURL),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty,
              let role = attribute(kAXRoleAttribute, of: element),
              !role.isEmpty
        else { return nil }
        return TargetBinding(
            element: element,
            processID: pid,
            identity: TargetIdentity(
                name: app.localizedName ?? "unknown",
                bundleID: bundleID,
                version: version,
                build: build,
                role: role,
                subrole: attribute(kAXSubroleAttribute, of: element) ?? "none"
            )
        )
    }

    private static func focusedElement() -> AXUIElement? {
        if let systemElement = focusedElement(in: AXUIElementCreateSystemWide()) {
            return systemElement
        }
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        guard let element = focusedElement(in: AXUIElementCreateApplication(processID)) else {
            return nil
        }
        var elementProcessID: pid_t = 0
        guard AXUIElementGetPid(element, &elementProcessID) == .success,
              elementProcessID == processID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
        else { return nil }
        return element
    }

    private static func focusedElement(in container: AXUIElement) -> AXUIElement? {
        guard AXUIElementSetMessagingTimeout(container, 0.05) == .success else { return nil }
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            container,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)
        guard AXUIElementSetMessagingTimeout(element, 0.05) == .success else { return nil }
        return element
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        return value as? String
    }

    private static func commandOutput(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        } catch {
            return "unknown"
        }
    }

    private static func safeMetadata(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- ()")).contains(scalar)
                ? Character(String(scalar)) : "_"
        })
    }

    private static func resultName(_ result: TextInjector.Result) -> String {
        switch result {
        case .pasted: "pasted"
        case .copiedSecureInput: "secure-input"
        case .copiedTargetChanged: "target-changed"
        case .deliveryUnconfirmed: "delivery-unconfirmed"
        case .failed: "event-post-failed"
        }
    }

    private static func percentile(_ ordered: [Double], _ fraction: Double) -> Double {
        guard !ordered.isEmpty else { return 0 }
        let index = max(0, min(ordered.count - 1, Int(ceil(Double(ordered.count) * fraction)) - 1))
        return ordered[index]
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private enum HarnessError: LocalizedError {
        case missingValue(String)
        case invalidValue(String)
        case unknownFlag(String)
        case duplicateFlag(String)

        var errorDescription: String? {
            switch self {
            case let .missingValue(flag): "missing value for \(flag)"
            case let .invalidValue(flag): "invalid value for \(flag)"
            case let .unknownFlag(flag): "unknown option \(flag)"
            case let .duplicateFlag(flag): "duplicate option \(flag)"
            }
        }
    }
}
