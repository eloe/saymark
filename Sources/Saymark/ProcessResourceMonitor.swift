import Darwin
import Foundation
import SaymarkKit

/// Low-frequency process telemetry for finding idle CPU and retained-memory
/// regressions during normal use. Sampling twice per minute is intentionally
/// boring: enough for trends without becoming the workload being measured.
final class ProcessResourceMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "saymark.resource-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var previousWall = ProcessInfo.processInfo.systemUptime
    private var previousCPU = 0.0

    func start(intervalSeconds: TimeInterval = 30) {
        queue.sync {
            guard timer == nil else { return }
            previousWall = ProcessInfo.processInfo.systemUptime
            previousCPU = Self.cpuSeconds().total
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func sample() {
        guard SaymarkDiagnostics.isEnabled(.debug) else { return }
        let wall = ProcessInfo.processInfo.systemUptime
        let cpu = Self.cpuSeconds()
        let wallDelta = max(0.001, wall - previousWall)
        let cpuDelta = max(0, cpu.total - previousCPU)
        previousWall = wall
        previousCPU = cpu.total
        let memory = Self.memoryBytes()

        SaymarkDiagnostics.log(.debug, "process.resource_sample", fields: [
            "interval_seconds": wallDelta,
            "cpu_percent": cpuDelta / wallDelta * 100,
            "user_cpu_seconds": cpu.user,
            "system_cpu_seconds": cpu.system,
            "resident_bytes": memory.resident,
            "physical_footprint_bytes": memory.footprint,
        ])
    }

    private static func cpuSeconds() -> (user: Double, system: Double, total: Double) {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0, 0) }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return (user, system, user + system)
    }

    private static func memoryBytes() -> (resident: UInt64, footprint: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, 0) }
        return (UInt64(info.resident_size), UInt64(info.phys_footprint))
    }
}
