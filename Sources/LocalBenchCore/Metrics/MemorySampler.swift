import Foundation
import Darwin

/// Memory sampling with a documented resolution (default 250 ms) and explicit
/// scope labels (spec §6): process footprint vs system pressure are distinct,
/// and for the system-hosted Apple backend the footprint is NOT model RAM.
public actor MemorySampler {
    public struct Summary: Sendable {
        public var samples: [MemorySample]
        public var peakFootprintMB: Double?
        public var peakPressureLevel: Int?
        public var scopeNote: String
    }

    private var intervalNS: UInt64 = 250_000_000
    private var samples: [MemorySample] = []
    private var running = false
    private var task: Task<Void, Never>?
    private let processNote: String

    public init(processNote: String = "process self phys_footprint (NOT model RAM for system-hosted Apple inference)") {
        self.processNote = processNote
    }

    public func start() {
        guard !running else { return }
        running = true
        samples.removeAll()
        task = Task {
            var tick = 0
            while !Task.isCancelled && running {
                let sample = Self.takeSample(offsetTick: tick, processNote: processNote)
                samples.append(sample)
                tick += 1
                try? await Task.sleep(nanoseconds: intervalNS)
            }
        }
    }

    public func stop() {
        running = false
        task?.cancel()
        task = nil
    }

    public func summary() -> Summary {
        let peakFootprint = samples.compactMap { $0.processFootprintMB }.max()
        let peakPressure = samples.compactMap { $0.systemPressureLevel }.max()
        return Summary(samples: samples, peakFootprintMB: peakFootprint, peakPressureLevel: peakPressure, scopeNote: processNote)
    }

    nonisolated static func takeSample(offsetTick: Int, processNote: String) -> MemorySample {
        MemorySample(
            offsetMS: Double(offsetTick) * 250,
            processFootprintMB: currentFootprintMB(),
            systemFreePagesMB: systemFreeMB(),
            systemPressureLevel: systemPressureLevel(),
            scopeNote: processNote
        )
    }

    static func currentFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { bound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), bound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    static func systemFreeMB() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { bound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, bound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let freePages = UInt64(stats.free_count) + UInt64(stats.inactive_count)
        let pageSize = UInt64(sysconf(Int32(_SC_PAGESIZE)))
        return Double(freePages * pageSize) / 1_048_576
    }

    static func systemPressureLevel() -> Int? {
        // Kernel memory-pressure state (XNU): 1 normal, 2 warning, 4 critical.
        // Free-page ratios are not a pressure signal on macOS, where the system
        // deliberately fills otherwise-idle RAM with file cache.
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        return pressureLevel(fromKernelValue: level)
    }

    /// Pure mapping from the XNU pressure level to the recorded 0/1/2 scale.
    static func pressureLevel(fromKernelValue value: Int32) -> Int? {
        switch value {
        case 1: return 0 // normal
        case 2: return 1 // warning
        case 4: return 2 // critical
        default: return nil
        }
    }
}
