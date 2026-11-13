import SwiftUI
import LocalBenchCore

/// Dedicated trace browser: every persisted request, its raw evidence, and
/// independent verification status (recomputed metrics vs recorded).
@MainActor
final class TraceViewModel: ObservableObject {
    enum VerifyState: Equatable {
        case unverified
        case pass
        case fail([String])

        var badge: String {
            switch self {
            case .unverified: return "—"
            case .pass: return "PASS"
            case .fail: return "FAIL"
            }
        }
    }

    struct RequestRow: Identifiable {
        let id: String
        let backend: String
        let modelID: String?
        let createdAt: Date?
        let traceCount: Int
        var verify: VerifyState = .unverified
    }

    @Published var rows: [RequestRow] = []
    @Published var selectedID: String?
    @Published var records: [TraceRecord] = []
    @Published var report: TraceVerifier.Report?
    @Published var context: SQLiteStore.RequestContext?
    @Published var filterText = ""
    @Published var onlyWithEvidence = true
    @Published var progressNote: String?
    @Published var lastError: String?

    var filteredRows: [RequestRow] {
        rows.filter { row in
            if onlyWithEvidence && row.traceCount == 0 { return false }
            if filterText.isEmpty { return true }
            let needle = filterText.lowercased()
            return row.id.lowercased().contains(needle)
                || row.backend.lowercased().contains(needle)
                || (row.modelID?.lowercased().contains(needle) ?? false)
        }
    }

    var selectedRow: RequestRow? {
        rows.first { $0.id == selectedID }
    }

    func reload() {
        do {
            let store = try SharedDatabase.shared()
            var loaded: [RequestRow] = []
            try store.query(
                """
                SELECT r.id, r.backend, res.model_id, r.created_at,
                       (SELECT COUNT(*) FROM wire_traces w WHERE w.request_id = r.id)
                FROM requests r
                LEFT JOIN results res ON res.request_id = r.id
                ORDER BY r.created_at DESC
                """
            ) { row in
                loaded.append(RequestRow(
                    id: row.text(0) ?? "",
                    backend: row.text(1) ?? "?",
                    modelID: row.text(2),
                    createdAt: row.double(3).map { Date(timeIntervalSince1970: $0) },
                    traceCount: row.int(4) ?? 0
                ))
            }
            rows = loaded
            if selectedID == nil || !rows.contains(where: { $0.id == selectedID }) {
                selectedID = rows.first?.id
                if let first = rows.first {
                    select(first.id)
                }
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    func select(_ id: String) {
        selectedID = id
        records = []
        report = nil
        context = nil
        do {
            let store = try SharedDatabase.shared()
            records = try store.wireTraces(requestID: id)
            context = try store.requestContext(requestID: id)
            var result: ResultEnvelope?
            try store.query(
                "SELECT * FROM results WHERE request_id = ?",
                bind: [.text(id)]
            ) { row in
                result = SQLiteStore.resultEnvelope(from: row)
            }
            if let result {
                let expected = TraceVerifier.Expected(result)
                report = TraceVerifier.verify(records: records, expected: expected)
                setVerify(for: id, state: (report?.passed ?? false) ? .pass : .fail(report?.findings ?? ["no report"]))
            } else {
                // No recorded result (e.g. prewarm or in-flight request): verify structure only.
                report = TraceVerifier.verify(records: records, expected: nil)
                setVerify(for: id, state: (report?.passed ?? false) ? .pass : .fail(report?.findings ?? []))
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    func verifyAll() {
        progressNote = "verifying…"
        Task {
            for row in rows where row.traceCount > 0 {
                select(row.id)
            }
            await MainActor.run {
                let passes = rows.filter { $0.verify == .pass }.count
                let failures = rows.filter {
                    if case .fail = $0.verify { return true }
                    return false
                }.count
                progressNote = "\(passes) passed, \(failures) failed out of \(rows.count)"
            }
        }
    }

    private func setVerify(for id: String, state: VerifyState) {
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].verify = state
        }
    }
}

struct TraceScreen: View {
    @StateObject private var viewModel = TraceViewModel()
    @EnvironmentObject var router: AppRouter

    var body: some View {
        NavigationSplitView {
            requestList
                .navigationSplitViewColumnWidth(min: 260, ideal: 340)
        } detail: {
            traceDetail
        }
        .navigationTitle("Traces")
        .onAppear {
            viewModel.reload()
            adoptFocusedRequest()
        }
        .onChange(of: router.focusedRequestID) { _ in
            adoptFocusedRequest()
        }
    }

    private func adoptFocusedRequest() {
        guard let focused = router.focusedRequestID else { return }
        if viewModel.rows.contains(where: { $0.id == focused }) {
            viewModel.select(focused)
        } else {
            viewModel.reload()
            if viewModel.rows.contains(where: { $0.id == focused }) {
                viewModel.select(focused)
            }
        }
        router.focusedRequestID = nil
    }

    private var requestList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter (id/backend/model)", text: $viewModel.filterText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    viewModel.verifyAll()
                } label: {
                    Label("Verify all", systemImage: "checkmark.seal")
                }
            }
            .padding(8)
            Toggle("Only with evidence", isOn: $viewModel.onlyWithEvidence)
                .toggleStyle(.checkbox)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
            if let note = viewModel.progressNote {
                Text(note).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            }
            List(selection: Binding(
                get: { viewModel.selectedID },
                set: { if let id = $0 { viewModel.select(id) } }
            )) {
                ForEach(viewModel.filteredRows) { row in
                    HStack(spacing: 6) {
                        verifyBadge(row.verify)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(row.backend)
                                    .font(.caption.weight(.semibold))
                                Text(row.modelID ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(row.id)
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let date = row.createdAt {
                                Text(date, style: .date)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Text("\(row.traceCount)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(row.traceCount == 0 ? Color.secondary : Color.primary)
                            .help("evidence records")
                    }
                    .tag(row.id)
                }
            }
            .listStyle(.sidebar)
        }
        .toolbar {
            Button {
                viewModel.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }

    @ViewBuilder
    private func verifyBadge(_ state: TraceViewModel.VerifyState) -> some View {
        switch state {
        case .unverified:
            Text("—").font(.caption2).foregroundStyle(.secondary)
        case .pass:
            Text("PASS")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .foregroundStyle(.white)
                .background(Color.green, in: Capsule())
        case .fail:
            Text("FAIL")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .foregroundStyle(.white)
                .background(Color.red, in: Capsule())
        }
    }

    private var traceDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let row = viewModel.selectedRow {
                HStack(spacing: 10) {
                    Text(row.backend).font(.headline)
                    Text(row.modelID ?? "").font(.caption).foregroundStyle(.secondary)
                    Text(row.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    if let context = viewModel.context {
                        Button {
                            router.openConversation(
                                conversationID: context.conversationID,
                                turnID: context.turnID,
                                backend: BackendID(rawValue: row.backend)
                            )
                        } label: {
                            Label("Back to Conversation", systemImage: "arrow.uturn.backward")
                        }
                        .help("Open the exact turn and conversation that produced this request")
                    }
                    Text("\(viewModel.records.count) records")
                        .font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                if let report = viewModel.report {
                    VerifyReportView(report: report)
                        .padding(.horizontal, 14)
                }
                if let error = viewModel.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 14)
                }
                TraceRecordList(records: viewModel.records)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("Select a request to inspect its raw evidence.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
