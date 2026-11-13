import SwiftUI
import LocalBenchCore

/// Settings screen (spec §8): network policy display, LM endpoint, data
/// directory, retention, telemetry off note, tool permissions, SDK report.
struct SettingsScreen: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var appleReport: AvailabilityReport?
    @State private var lmReport: AvailabilityReport?

    var body: some View {
        TabView {
            networkTab.tabItem { Label("Network", systemImage: "network") }
            dataTab.tabItem { Label("Data", systemImage: "externaldrive") }
            sdkTab.tabItem { Label("SDK report", systemImage: "cpu") }
        }
        .frame(width: 620, height: 460)
        .padding()
        .onAppear {
            Task {
                appleReport = await AppleBackend().availabilityReport()
            }
            Task {
                let backend = viewModel.makeLMBackend()
                lmReport = await backend.availabilityReport()
            }
        }
    }

    private var networkTab: some View {
        Form {
            Section("Local-only policy") {
                Text("LocalBench performs no cloud inference. The Apple backend uses the on-device Foundation Models configuration only; LM Studio requests are restricted to loopback addresses (127.0.0.0/8, ::1, localhost). Remote model endpoints are rejected.")
                    .font(.callout)
                HStack {
                    Text("LM Studio endpoint")
                    TextField("http://127.0.0.1:1234", text: $viewModel.lmBaseURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Discover models") { viewModel.refreshLMModels() }
                }
                if let error = viewModel.lmDiscoveryError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Toggle("Telemetry", isOn: .constant(false))
                    .disabled(true)
                    .help("There is no telemetry. The app performs no outbound requests from application code.")
            }
        }
        .padding()
    }

    private var dataTab: some View {
        Form {
            Section("Storage") {
                Text("Conversations, runs, and samples are stored in a local SQLite database at:")
                Text(localDBPath()).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Attachments stay on local disk at their original paths; nothing is synced.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Delete all local data…", role: .destructive) {
                    try? viewModel.wipeStore()
                }
            }
        }
        .padding()
    }

    private var sdkTab: some View {
        Form {
            Section("Apple Foundation Models (runtime-detected)") {
                if let appleReport {
                    row("Available", appleReport.isAvailable ? "yes" : "no — \(appleReport.reason)")
                    if let identity = appleReport.identity {
                        row("Model", identity.modelID)
                        row("Context size", identity.contextSize.map(String.init) ?? "unavailable")
                        row("Vision", identity.capabilities.images ? "yes" : "no")
                        row("Guided generation", identity.capabilities.guidedGeneration ? "yes" : "no")
                        row("Tool calling", identity.capabilities.toolCalling ? "yes" : "no")
                        row("Reasoning", identity.capabilities.reasoning ? "yes" : "no")
                    } else {
                        Text(appleReport.actionableAdvice).foregroundStyle(.orange)
                    }
                } else {
                    ProgressView()
                }
            }
            Section("LM Studio (runtime-detected)") {
                if let lmReport {
                    row("Reachable", lmReport.isAvailable ? "yes" : "no — \(lmReport.reason)")
                    if let identity = lmReport.identity {
                        row("Selected model", identity.modelID)
                        row("Vision (model)", identity.capabilities.images ? "yes" : "no")
                        row("Streaming usage", identity.capabilities.streamUsage.map { $0 ? "yes" : "no" } ?? "unknown until first stream")
                    }
                } else {
                    ProgressView()
                }
            }
            Section("Local tools") {
                Text("Tool allowlist (calculator, document search, selected file read) is P1; every sensitive call will require explicit permission. No shell execution.")
                    .font(.footnote)
            }
        }
        .padding()
    }

    func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }

    func localDBPath() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalBench/localbench.sqlite").path
    }
}

extension ChatViewModel {
    func wipeStore() throws {
        try store?.deleteAll()
        try? store?.saveBenchmarkRun(BenchmarkRun(label: "deleted", schedule: .sequential, repetitions: 0, stateless: true))
    }
}
