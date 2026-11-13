import SwiftUI
import LocalBenchCore

/// Dedicated individual-chat section (spec §3): one model, one conversation,
/// one response pane. Distinct from the side-by-side Compare screen.
struct IndividualChatScreen: View {
    @StateObject private var viewModel = ChatViewModel(backends: [.apple])
    @State private var singleBackend: BackendID = .apple
    @State private var promptDraft = ""
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            ConversationSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                controlsBar
                Divider()
                turnsList
                Divider()
                composer
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Settings") { showingSettings = true }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsScreen(viewModel: viewModel)
        }
        .onAppear {
            viewModel.loadSavedConversations()
        }
        .onChange(of: singleBackend) { backend in
            viewModel.selectedBackends = [backend]
            viewModel.refreshAvailability()
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            Picker("Model", selection: $singleBackend) {
                Text("Apple Foundation Models").tag(BackendID.apple)
                Text("LM Studio").tag(BackendID.lmStudio)
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            if singleBackend == .lmStudio {
                LMModelPicker(viewModel: viewModel)
            }

            Spacer()

            if let report = viewModel.identityReports[singleBackend], !report.isAvailable {
                Label(report.reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(report.actionableAdvice)
            } else if let identity = viewModel.identityReports[singleBackend]?.identity {
                Text(identity.modelID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var turnsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.selectedConversation.turns) { turn in
                        userBubble(text: turn.canonicalUserText)
                        if let record = turn.records[singleBackend] {
                            responsePane(record: record)
                                .id(turn.id)
                        } else {
                            Text("No \(singleBackend.displayName) response for this turn.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if viewModel.isRunning {
                        livePane
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

    private func responsePane(record: TurnRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            paneHeader
            Text(record.streamedText)
                .textSelection(.enabled)
                .font(.system(.body))
            if let result = record.result {
                MetricStrip(result: result)
                if !result.toolCalls.isEmpty {
                    ForEach(result.toolCalls) { call in
                        Text("🛠 \(call.name)(\(call.argumentsJSON))")
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            if let error = record.result?.error {
                Text("⚠️ \(error.kind.rawValue): \(error.message)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var livePane: some View {
        VStack(alignment: .leading, spacing: 6) {
            paneHeader
            Text(viewModel.streamingText[singleBackend] ?? "…")
                .textSelection(.enabled)
                .foregroundStyle(singleBackend == .apple ? Color.blue : Color.purple)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var paneHeader: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(singleBackend == .apple ? Color.blue : Color.purple)
                .frame(width: 8, height: 8)
            Text(singleBackend.displayName)
                .font(.caption.weight(.semibold))
            Spacer()
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextEditor(text: $promptDraft)
                .frame(minHeight: 64, maxHeight: 160)
                .border(Color.gray.opacity(0.3))
            if viewModel.isRunning {
                Button("Cancel", role: .destructive) { viewModel.cancelRunning() }
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
