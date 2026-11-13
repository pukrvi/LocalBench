import SwiftUI
import LocalBenchCore
import UniformTypeIdentifiers

struct ChatScreen: View {
    @StateObject private var viewModel = ChatViewModel()
    @State private var promptDraft = ""
    @State private var showingFilePicker = false
    @State private var showingSettings = false
    @State private var detailBackend: BackendID?

    var body: some View {
        NavigationSplitView {
            ConversationSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            VStack(spacing: 0) {
                controlsBar
                Divider()
                if viewModel.statelessMode || viewModel.schedule == .parallel {
                    modeBanner
                }
                turnsList
                Divider()
                attachmentTray
                composer
            }
            .navigationTitle("LocalBench")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings") { showingSettings = true }
                }
            }
        } detail: {
            if let backend = detailBackend {
                RunDetailScreen(backend: backend, result: viewModel.lastResult[backend])
            } else {
                Text("Select a pane to inspect run details.")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsScreen(viewModel: viewModel)
        }
        .fileImporter(isPresented: $showingFilePicker,
                      allowedContentTypes: [.pdf, .plainText, .utf8PlainText, .image],
                      allowsMultipleSelection: true) { result in
            if let urls = try? result.get() {
                viewModel.pendingAttachments.append(contentsOf: urls)
            }
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            // Backend selector: Apple / LM / Compare
            Picker("Backend", selection: $viewModel.selectedBackends) {
                Text("Apple").tag(Set<BackendID>([.apple]))
                Text("LM Studio").tag(Set<BackendID>([.lmStudio]))
                Text("Compare").tag(Set<BackendID>([.apple, .lmStudio]))
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .onChange(of: viewModel.selectedBackends) { _ in
                viewModel.refreshAvailability()
            }

            // Sequential vs Parallel
            Picker("Schedule", selection: $viewModel.schedule) {
                Text("Sequential").tag(RunSchedule.sequential)
                Text("Parallel").tag(RunSchedule.parallel)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Toggle("Stateless", isOn: $viewModel.statelessMode)
                .help("Same system instruction + prompt, no assistant history (controlled single-turn benchmark)")

            Spacer()

            LMModelPicker(viewModel: viewModel)
        }
        .padding(10)
    }

    private var modeBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(viewModel.schedule == .parallel
                 ? "Parallel mode is contended — for UX only, label as such in published benchmarks (spec §5)."
                 : "Stateless mode: no assistant history; identical system instruction + prompt for both backends.")
                .font(.footnote)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
    }

    private var turnsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.selectedConversation.turns) { turn in
                        userBubble(text: turn.canonicalUserText)
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(turn.records.keys).sorted { $0.rawValue < $1.rawValue }, id: \.self) { backend in
                                responsePane(turn: turn, backend: backend)
                            }
                        }
                    }
                    if viewModel.isRunning {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(viewModel.selectedBackends).sorted { $0.rawValue < $1.rawValue }, id: \.self) { backend in
                                livePane(backend: backend)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .onChange(of: viewModel.selectedConversation.turns.count) { _ in
                if let last = viewModel.selectedConversation.turns.last {
                    proxy.scrollTo(last.id, anchor: .top)
                }
            }
        }
    }

    private func userBubble(text: String) -> some View {
        HStack {
            Spacer()
            Text(text)
                .textSelection(.enabled)
                .padding(10)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func responsePane(turn: Turn, backend: BackendID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            paneHeader(backend: backend)
            Text(turn.records[backend]?.streamedText ?? "")
                .textSelection(.enabled)
                .font(.system(.body))
            if let result = turn.records[backend]?.result {
                MetricStrip(result: result)
                Button("Details…") { detailBackend = backend }
                    .controlSize(.small)
            }
            if let error = turn.records[backend]?.result?.error {
                Text("⚠️ \(error.kind.rawValue): \(error.message)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .id(turn.id)
    }

    private func livePane(backend: BackendID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            paneHeader(backend: backend)
            Text(viewModel.streamingText[backend] ?? "…")
                .textSelection(.enabled)
                .foregroundStyle(backend == .apple ? Color.blue : Color.purple)
            if let report = viewModel.identityReports[backend], !report.isAvailable {
                Text("⚠️ \(report.reason) — \(report.actionableAdvice)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func paneHeader(backend: BackendID) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(backend == .apple ? Color.blue : Color.purple)
                .frame(width: 8, height: 8)
            Text(backend.displayName)
                .font(.caption.weight(.semibold))
            if let identity = viewModel.identityReports[backend]?.identity {
                Text(identity.modelID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var attachmentTray: some View {
        HStack(spacing: 8) {
            Button {
                showingFilePicker = true
            } label: {
                Label("Attach (PDF/TXT/MD/image)", systemImage: "paperclip")
            }
            ForEach(viewModel.pendingAttachments, id: \.self) { url in
                Text(url.lastPathComponent)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Toggle("OCR", isOn: $viewModel.allowOCR)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Allow local Vision OCR for scanned pages / text-heavy images (runs on-device only)")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextEditor(text: $promptDraft)
                .frame(minHeight: 64, maxHeight: 160)
                .border(Color.gray.opacity(0.3))
            if viewModel.isRunning {
                Button("Cancel", role: .destructive) {
                    viewModel.cancelRunning()
                }
            } else {
                Button("Send") {
                    viewModel.send(prompt: promptDraft)
                    promptDraft = ""
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }
}

struct LMModelPicker: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.split.2x1")
            Menu {
                if viewModel.lmModels.isEmpty {
                    Text("No LM Studio models").foregroundStyle(.secondary)
                }
                ForEach(viewModel.lmModels, id: \.id) { model in
                    Button(model.id + (model.capabilities?.vision == true ? "  (vision)" : "")) {
                        viewModel.selectedLMModel = model.id
                        viewModel.refreshAvailability()
                    }
                }
                Divider()
                Button("Refresh models") {
                    viewModel.refreshLMModels()
                }
            } label: {
                Text(viewModel.selectedLMModel ?? "LM model")
            }
            .frame(width: 200)
        }
    }
}

/// Per-pane metric strip (spec §8): TTFT, wall, decode speed, tokens with
/// provenance, memory with scope. Unavailable values render as "unavailable".
struct MetricStrip: View {
    let result: ResultEnvelope

    var body: some View {
        HStack(spacing: 10) {
            metric("TTFT", result.ttftMS.map { String(format: "%.0f ms", $0) })
            metric("Wall", String(format: "%.0f ms", result.wallMS))
            metric("Decode", result.outputTokensPerSecond.map { String(format: "%.1f tok/s", $0) })
            metric("Tokens", tokenLabel)
            metric("Mem", result.peakProcessFootprintMB.map { String(format: "%.0f MB", $0) })
            metric("Finish", result.finishReason.rawValue)
            metric("Tokens", tokenLabel)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    var tokenLabel: String? {
        switch result.tokenProvenance {
        case .native, .server:
            return "in \(result.inputTokens ?? -1) / out \(result.outputTokens ?? -1) (\(result.tokenProvenance.rawValue))"
        case .estimated:
            return "tokens ~estimated"
        case .unavailable:
            return "tokens unavailable"
        }
    }

    func metric(_ name: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.system(size: 9, weight: .semibold))
            Text(value ?? "n/a").font(.system(size: 11, design: .monospaced))
        }
    }
}

struct ConversationSidebar: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        List(selection: Binding(get: { viewModel.selectedConversationID as String? }, set: { if let id = $0 { viewModel.selectedConversationID = id } })) {
            ForEach(viewModel.conversations, id: \.id) { conversation in
                Text(conversation.title)
                    .tag(conversation.id as String?)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    let conversation = Conversation(title: "New conversation")
                    viewModel.conversations.append(conversation)
                    viewModel.selectedConversationID = conversation.id
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem {
                Button(role: .destructive) {
                    viewModel.conversations.removeAll { $0.id == viewModel.selectedConversationID }
                    if viewModel.conversations.isEmpty {
                        let conversation = Conversation(title: "New conversation")
                        viewModel.conversations = [conversation]
                        viewModel.selectedConversationID = conversation.id
                    }
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }
}

struct RunDetailScreen: View {
    let backend: BackendID
    let result: ResultEnvelope?
    @EnvironmentObject var router: AppRouter
    @State private var verifyReport: TraceVerifier.Report?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let result {
                    if let error = result.error {
                        Text("⚠️ \(error.kind.rawValue): \(error.message)")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    section("Trace evidence") {
                        HStack(spacing: 10) {
                            Text("\(result.traces.count) records")
                            Text(result.tracesFingerprint.isEmpty ? "no fingerprint" : "fingerprint \(result.tracesFingerprint.prefix(16))…")
                                .font(.caption.monospaced())
                            Spacer()
                            Button("Verify this run") {
                                verifyReport = TraceVerifier.verify(records: result.traces, expected: .init(result))
                            }
                            Button("Open in Traces") {
                                router.openTraces(requestID: result.requestID)
                            }
                        }
                        .font(.caption)
                        if let verifyReport {
                            VerifyReportView(report: verifyReport)
                        }
                        TraceRecordList(records: result.traces)
                            .frame(minHeight: 160, maxHeight: 360)
                    }

                    section("Timing") {
                        row("TTFT (first content − dispatch)", result.ttftMS.map { String(format: "%.1f ms", $0) } ?? "unavailable")
                        row("Wall time (completion − dispatch)", String(format: "%.1f ms", result.wallMS))
                        row("Decode speed", result.outputTokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "unavailable")
                        row("Prefill tok/s", "n/a — no trustworthy prefill timing exposed")
                        row("Dispatch (mono ns)", String(result.dispatchMonotonicNS))
                        row("First content (mono ns)", result.firstContentMonotonicNS.map(String.init) ?? "unavailable")
                        row("End (mono ns)", String(result.endMonotonicNS))
                    }
                    section("Tokens") {
                        row("Input", result.inputTokens.map(String.init) ?? "unavailable")
                        row("Output", result.outputTokens.map(String.init) ?? "unavailable")
                        row("Cached", result.cachedTokens.map(String.init) ?? "unavailable")
                        row("Reasoning", result.reasoningTokens.map(String.init) ?? "unavailable")
                        row("Provenance", result.tokenProvenance.rawValue)
                    }
                    section("Memory") {
                        row("Peak process footprint", result.peakProcessFootprintMB.map { String(format: "%.1f MB", $0) } ?? "unsampled")
                        row("Scope", result.memoryScopeNote)
                        row("Samples", String(result.memorySamples.count))
                        row("System pressure peak", result.systemPeakPressureLevel.map(String.init) ?? "unsampled")
                    }
                    section("Run") {
                        row("Backend", result.backend.displayName)
                        row("Model", result.modelID)
                        row("Repetition", String(result.repetitionIndex))
                        row("Warmth", result.warmth.rawValue)
                        row("Schedule", result.schedule.rawValue)
                        row("Mode", result.mode.rawValue)
                        row("Finish reason", result.finishReason.rawValue)
                        if let error = result.error {
                            row("Error", "\(error.kind.rawValue): \(error.message)")
                        }
                        row("Prompt hash", result.promptHash)
                        row("Attachment hashes", result.attachmentSHA256s.joined(separator: ", "))
                        row("OS", "\(result.osVersion) (\(result.osBuild))")
                    }
                    section("Raw text") {
                        Text(result.rawText.isEmpty ? "(empty)" : result.rawText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    Text("No result recorded for \(backend.displayName) yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Run detail — \(backend.displayName)")
    }

    func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.callout)
    }
}
