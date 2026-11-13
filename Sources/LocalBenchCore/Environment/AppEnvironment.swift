import Foundation
import IOKit.ps

/// A snapshot of the machine + OS environment captured with each benchmark
/// (spec §5, §9: reproducibility).
public struct AppEnvironmentSnapshot: Codable, Sendable, Hashable {
    public var osVersion: String
    public var osBuild: String
    public var chip: String
    public var cpuCores: Int
    public var physicalMemoryGB: Double
    public var thermalState: String
    public var isLowPowerMode: Bool
    public var battery: String
    public var capturedAt: Date
}

public enum AppEnvironment {
    /// Collect once per run; cheap enough to call per export too.
    public static func current() -> AppEnvironmentSnapshot {
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let build = sysctlString("kern.osversion") ?? "unknown"
        let chip = sysctlString("machdep.cpu.brand_string") ?? "unknown"
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return AppEnvironmentSnapshot(
            osVersion: osVersion,
            osBuild: build,
            chip: chip,
            cpuCores: process.processorCount,
            physicalMemoryGB: (Double(process.physicalMemory) / 1_073_741_824).rounded(),
            thermalState: thermal,
            isLowPowerMode: process.isLowPowerModeEnabled,
            battery: powerSourceSummary(),
            capturedAt: Date()
        )
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(max(0, size - 1)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Plugged-in/battery state via IOKit power sources; graceful fallback.
    /// Key/value strings match IOPSKeys.h (the kIOPS* C macros are not imported).
    static func powerSourceSummary() -> String {
        guard let source = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(source)?.takeRetainedValue() as? [CFTypeRef] else {
            return "unknown"
        }
        for entry in list {
            guard let description = IOPSGetPowerSourceDescription(source, entry)?.takeUnretainedValue() as? [String: Any] else { continue }
            let type = description["Power Source"] as? String ?? ""
            let state = description["Power Source State"] as? String ?? ""
            if type == "InternalBattery" {
                let charging = (description["Is Charging"] as? Bool) ?? false
                let percent = (description["Current Capacity"] as? Int) ?? -1
                let connected = state == "AC Power"
                return connected
                    ? "AC (battery \(percent)%, \(charging ? "charging" : "plugged in"))"
                    : "battery(discharging, \(percent)%)"
            }
            if type == "UPS" { return "UPS" }
        }
        return "unknown"
    }
}
