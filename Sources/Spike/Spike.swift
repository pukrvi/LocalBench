// M0 SDK spike — LocalBench
// Verifies FoundationModels API signatures, runtime availability, native token
// counting, streaming behavior, and LM Studio discovery on THIS machine.
// Everything printed here is measured at runtime; nothing is assumed.

import Foundation
import FoundationModels

@main
struct Spike {
    static func main() async {
        await run()
    }

    static func run() async {
        print("=== LocalBench M0 spike ===")
        printEnvironment()
        await appleBackendProbe()
        await lmStudioProbe()
        print("=== spike complete ===")
    }

    // MARK: Environment

    static func printEnvironment() {
        let process = ProcessInfo.processInfo
        print("[env] os=\(process.operatingSystemVersionString)")
        print("[env] hostName=\(process.hostName)")
        print("[env] cpuCores=\(process.processorCount) activeCores=\(process.activeProcessorCount)")
        print("[env] physicalMemoryGB=\(String(format: "%.1f", Double(process.physicalMemory) / 1_073_741_824))")
        if let chip = sysctlString("machdep.cpu.brand_string") {
            print("[env] chip=\(chip)")
        }
        if let bootArg = sysctlString("kern.bootargs"), !bootArg.isEmpty {
            print("[env] bootargs=\(bootArg)")
        }
        // Power / thermal signals, if readable.
        if let powerMode = sysctlString("kern.powermode") {
            print("[env] kern.powermode=\(powerMode)")
        }
        print("[env] self_footprint_MB=\(String(format: "%.1f", Double(currentFootprintBytes() ?? 0) / 1_048_576))")
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(max(0, size - 1)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func currentFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { bound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), bound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    // MARK: Apple Foundation Models

    static func appleBackendProbe() async {
        print("[apple] begin probe")
        let model = SystemLanguageModel.default
        print("[apple] availability=\(describeAvailability(model.availability))")
        print("[apple] isAvailable=\(model.isAvailable)")
        let languages = model.supportedLanguages
        print("[apple] supportedLanguages.count=\(languages.count)")
        print("[apple] supportsLocale(en-US)=\(model.supportsLocale(Locale(identifier: "en-US")))")
        print("[apple] contextSize=\(model.contextSize)")
        if #available(macOS 27.0, *) {
            print("[apple] variant.displayName=\(model.variant.displayName)")
            let caps = model.capabilities
            print("[apple] capabilities.vision=\(caps.contains(.vision))")
            print("[apple] capabilities.guidedGeneration=\(caps.contains(.guidedGeneration))")
            print("[apple] capabilities.reasoning=\(caps.contains(.reasoning))")
            print("[apple] capabilities.toolCalling=\(caps.contains(.toolCalling))")
        } else {
            print("[apple] variant/capabilities: macOS 27 API not compiled-in on this SDK path")
        }

        guard model.isAvailable else {
            print("[apple] unavailable -> skipping generation probes")
            return
        }

        // Native token counting for a known prompt.
        if #available(macOS 26.4, *) {
            do {
                let count = try await model.tokenCount(for: "Count from one to ten.")
                print("[apple] tokenCount(prompt) =\(count) provenance=native")
            } catch {
                print("[apple] tokenCount failed: \(error)")
            }
        } else {
            print("[apple] tokenCount(prompt) =n/a (macOS <26.4)")
        }

        // Streaming generation probe with real timing.
        let session = LanguageModelSession(model: model, instructions: "You are a benchmark assistant. Answer plainly and briefly.")

        let clock = ContinuousClock()
        var firstContent: ContinuousClock.Instant?
        var lastText = ""
        var charCount = 0
        var snapshotCount = 0
        var usageDescription = "unavailable"
        var errorDescription: String?

        let dispatch = clock.now
        do {
            for try await snapshot in session.streamResponse(to: "Count from one to ten.") {
                snapshotCount += 1
                if firstContent == nil { firstContent = clock.now }
                let text = snapshot.content
                if text.count > charCount {
                    charCount = text.count
                    lastText = text
                }
                if #available(macOS 27.0, *) {
                    let usage = snapshot.usage
                    usageDescription = "in=\(usage.input.totalTokenCount) cached=\(usage.input.cachedTokenCount) out=\(usage.output.totalTokenCount) reasoning=\(usage.output.reasoningTokenCount)"
                }
            }
        } catch {
            errorDescription = String(describing: error)
        }
        let end = clock.now

        let ttft = firstContent.map { dispatch.duration(to: $0) }
        let wall = dispatch.duration(to: end)
        func ms(_ d: Duration?) -> String {
            guard let d else { return "n/a" }
            let nanos = Double(d.components.attoseconds) * 1e-9 + Double(d.components.seconds) * 1e9
            return String(format: "%.1f", nanos / 1_000_000)
        }
        print("[apple] stream snapshots=\(snapshotCount) chars=\(charCount)")
        print("[apple] ttft_ms=\(ms(ttft)) wall_ms=\(ms(wall))")
        print("[apple] usage(\(usageDescription))")
        if let errorDescription { print("[apple] stream error=\(errorDescription)") }
        print("[apple] final text: \(lastText.prefix(300))")
        print("[apple] self_footprint_after_MB=\(String(format: "%.1f", Double(currentFootprintBytes() ?? 0) / 1_048_576))")
    }

    static func describeAvailability(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available: return "available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "unavailable(deviceNotEligible)"
            case .appleIntelligenceNotEnabled: return "unavailable(appleIntelligenceNotEnabled)"
            case .modelNotReady: return "unavailable(modelNotReady)"
            @unknown default: return "unavailable(unknown)"
            }
        @unknown default: return "unknown"
        }
    }

    // MARK: LM Studio

    static func lmStudioProbe() async {
        print("[lmstudio] begin probe")
        let base = URL(string: "http://127.0.0.1:1234")!
        var request = URLRequest(url: base.appendingPathComponent("v1/models"))
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[lmstudio] /v1/models status=\(status) bytes=\(data.count)")
            guard status == 200 else {
                print("[lmstudio] unexpected status; LM Studio may not be running or server not started")
                return
            }
            if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = parsed["data"] as? [[String: Any]] {
                let ids = models.compactMap { $0["id"] as? String }
                print("[lmstudio] models=\(ids.isEmpty ? "(none)" : ids.joined(separator: ", "))")
                if let first = ids.first, CommandLine.arguments.contains("--lm-stream") {
                    await lmStudioStreamProbe(base: base, model: first)
                }
            }
        } catch {
            print("[lmstudio] not reachable on 127.0.0.1:1234 (\(error.localizedDescription))")
        }
    }

    static func lmStudioStreamProbe(base: URL, model: String) async {
        var request = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Count from one to ten."]],
            "stream": true,
            "stream_options": ["include_usage": true],
            "max_tokens": 64,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let clock = ContinuousClock()
        let dispatch = clock.now
        var firstChunk: ContinuousClock.Instant?
        var chunks = 0
        var chars = 0
        var usageLine = "no usage chunk"
        var finishReason = "n/a"
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[lmstudio] stream status=\(status)")
            var pendingUsage: String?
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard payload != "[DONE]" else { break }
                chunks += 1
                if firstChunk == nil { firstChunk = clock.now }
                guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                if let usage = json["usage"] as? [String: Any] {
                    pendingUsage = "prompt=\(usage["prompt_tokens"] ?? "-") completion=\(usage["completion_tokens"] ?? "-") total=\(usage["total_tokens"] ?? "-")"
                }
                if let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
                    if let reason = choice["finish_reason"] as? String { finishReason = reason }
                    if let delta = choice["delta"] as? [String: Any],
                       let content = delta["content"] as? String {
                        chars += content.count
                    }
                }
            }
            if let pendingUsage { usageLine = pendingUsage }
        } catch {
            print("[lmstudio] stream error: \(error)")
        }
        let end = clock.now
        func ms(_ d: Duration?) -> String {
            guard let d else { return "n/a" }
            let nanos = Double(d.components.attoseconds) * 1e-9 + Double(d.components.seconds) * 1e9
            return String(format: "%.1f", nanos / 1_000_000)
        }
        print("[lmstudio] chunks=\(chunks) chars=\(chars) finish=\(finishReason)")
        print("[lmstudio] ttft_ms=\(ms(firstChunk.map { dispatch.duration(to: $0) })) wall_ms=\(ms(dispatch.duration(to: end)))")
        print("[lmstudio] usage: \(usageLine)")
    }
}
