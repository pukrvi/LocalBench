import SwiftUI
import LocalBenchCore

/// Human / frontier review (spec §6): versioned rubric scoring, thumbs, blind
/// pairwise preference, and offline export of the whole evaluation dataset.
@MainActor
final class ReviewViewModel: ObservableObject {
    struct TurnGroup: Identifiable {
        var id: String
        var userText: String
        var createdAt: Date
        var responses: [SQLiteStore.ReviewableResponse]
    }

    @Published var responses: [SQLiteStore.ReviewableResponse] = []
    @Published var selectedRequestID: String?
    @Published var savedEvaluations: [Evaluation] = []
    @Published var pairwiseHistory: [PairwiseEvaluation] = []
    @Published var filterText = ""
    @Published var lastError: String?
    @Published var statusNote: String?
    @Published var exportPath: String?

    // Rubric draft
    @Published var scores: [String: Int] = [:]
    @Published var notes = ""
    @Published var judgedBy = "local reviewer"
    @Published var thumbs: Int?

    // Pairwise draft
    @Published var pairTurnID: String?
    @Published var pairAID: String?
    @Published var pairBID: String?
    @Published var pairWinner: PairwiseEvaluation.Winner = .tie
    @Published var pairBlind = true
    @Published var pairNotes = ""

    var selectedResponse: SQLiteStore.ReviewableResponse? {
        responses.first { $0.requestID == selectedRequestID }
    }

    var filteredGroups: [TurnGroup] {
        let needle = filterText.lowercased()
        return allGroups.compactMap { group in
            if needle.isEmpty { return group }
            let matchesUser = group.userText.lowercased().contains(needle)
            let matching = group.responses.filter {
                $0.backend.rawValue.lowercased().contains(needle)
                    || $0.modelID.lowercased().contains(needle)
                    || $0.rawText.lowercased().contains(needle)
            }
            if matchesUser { return group }
            guard !matching.isEmpty else { return nil }
            var copy = group
            copy.responses = matching
            return copy
        }
    }

    var allGroups: [TurnGroup] {
        Dictionary(grouping: responses, by: \.turnID)
            .map { turnID, items in
                TurnGroup(
                    id: turnID,
                    userText: items.first?.userText ?? "",
                    createdAt: items.map(\.createdAt).max() ?? Date(),
                    responses: items.sorted { $0.backend.rawValue < $1.backend.rawValue }
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var pairwiseGroups: [TurnGroup] {
        allGroups.filter { $0.responses.count >= 2 }
    }

    var pairCandidates: [SQLiteStore.ReviewableResponse] {
        allGroups.first { $0.id == pairTurnID }?.responses ?? []
    }

    var currentMaximumScore: Int {
        EvaluationRubric.v1.criteria.reduce(0) { $0 + $1.maximumScore }
    }

    func reload() {
        do {
            let store = try SharedDatabase.shared()
            responses = try store.reviewableResponses()
            pairwiseHistory = try store.pairwiseEvaluations()
            if selectedRequestID == nil || !responses.contains(where: { $0.requestID == selectedRequestID }) {
                selectedRequestID = responses.first?.requestID
            }
            loadSelected()
            if pairTurnID == nil || !pairwiseGroups.contains(where: { $0.id == pairTurnID }) {
                pairTurnID = pairwiseGroups.first?.id
                resetPairCandidates()
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    func loadSelected() {
        guard let selectedRequestID else {
            savedEvaluations = []
            return
        }
        do {
            let store = try SharedDatabase.shared()
            savedEvaluations = try store.evaluations(forRequestID: selectedRequestID)
        } catch {
            lastError = String(describing: error)
        }
        resetDraft()
    }

    func resetDraft() {
        scores = Dictionary(uniqueKeysWithValues: EvaluationRubric.v1.criteria.map { ($0.id, 2) })
        notes = ""
        thumbs = nil
        judgedBy = "local reviewer"
    }

    func resetPairCandidates() {
        let candidates = pairCandidates
        pairAID = candidates.first?.requestID
        pairBID = candidates.count > 1 ? candidates[1].requestID : nil
        pairWinner = .tie
        pairNotes = ""
    }

    func saveEvaluation() {
        guard let response = selectedResponse else { return }
        let store: SQLiteStore
        do { store = try SharedDatabase.shared() } catch {
            lastError = String(describing: error)
            return
        }
        let rubricScores = EvaluationRubric.v1.criteria.compactMap { criterion -> RubricScore? in
            guard let score = scores[criterion.id] else { return nil }
            return RubricScore(criterionID: criterion.id, score: min(max(score, 0), criterion.maximumScore))
        }
        let evaluation = Evaluation(
            id: UUID().uuidString,
            requestID: response.requestID,
            backend: response.backend,
            kind: rubricScores.isEmpty ? .thumbs : .rubric,
            thumbs: thumbs,
            rubricVersion: rubricScores.isEmpty ? nil : EvaluationRubric.v1.version,
            rubricTitle: rubricScores.isEmpty ? nil : EvaluationRubric.v1.title,
            scores: rubricScores,
            notes: notes,
            judgedBy: judgedBy
        )
        do {
            try store.saveEvaluation(evaluation)
            statusNote = "Saved review for \(response.backend.displayName)."
            loadSelected()
        } catch {
            lastError = String(describing: error)
        }
    }

    func delete(_ evaluation: Evaluation) {
        do {
            try SharedDatabase.shared().deleteEvaluation(id: evaluation.id)
            loadSelected()
        } catch {
            lastError = String(describing: error)
        }
    }

    func savePairwise() {
        guard let pairAID, let pairBID,
              let a = responses.first(where: { $0.requestID == pairAID }),
              let b = responses.first(where: { $0.requestID == pairBID }) else {
            lastError = "Pick two responses from the same turn."
            return
        }
        guard a.turnID == b.turnID else {
            lastError = "Pairwise reviews must compare answers to the same turn."
            return
        }
        let evaluation = PairwiseEvaluation(
            requestAID: a.requestID,
            requestBID: b.requestID,
            backendA: a.backend,
            backendB: b.backend,
            winner: pairWinner,
            blind: pairBlind,
            notes: pairNotes,
            judgedBy: judgedBy
        )
        do {
            try SharedDatabase.shared().savePairwiseEvaluation(evaluation)
            statusNote = "Saved pairwise decision."
            pairwiseHistory = try SharedDatabase.shared().pairwiseEvaluations()
            pairNotes = ""
        } catch {
            lastError = String(describing: error)
        }
    }

    func exportBundle() {
        do {
            let store = try SharedDatabase.shared()
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalBenchExports", isDirectory: true)
            let url = try ExportService.writeEvaluationBundle(
                evaluations: try store.evaluations(),
                pairwise: try store.pairwiseEvaluations(),
                responses: responses,
                to: directory,
                fileBaseName: "localbench-evaluations-\(Int(Date().timeIntervalSince1970))"
            )
            exportPath = url.path
        } catch {
            lastError = "Evaluation export failed: \(error)"
        }
    }
}

struct ReviewScreen: View {
    @StateObject private var viewModel = ReviewViewModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 340)
        } detail: {
            detail
        }
        .navigationTitle("Review")
        .onAppear { viewModel.reload() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter (prompt/backend/model/text)", text: $viewModel.filterText)
                    .textFieldStyle(.roundedBorder)
                Button {
                    viewModel.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(8)
            List(selection: Binding(
                get: { viewModel.selectedRequestID },
                set: { if let id = $0 { viewModel.selectedRequestID = id; viewModel.loadSelected() } }
            )) {
                ForEach(viewModel.filteredGroups) { group in
                    Section {
                        ForEach(group.responses) { response in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(response.backend.displayName)
                                        .font(.caption.weight(.semibold))
                                    Text(response.modelID)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text(response.rawText.isEmpty ? "(empty)" : response.rawText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .tag(response.requestID)
                        }
                    } header: {
                        Text(group.userText.isEmpty ? "(no prompt)" : group.userText)
                            .lineLimit(2)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = viewModel.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let note = viewModel.statusNote {
                    Text(note).font(.caption).foregroundStyle(.green)
                }
                if let response = viewModel.selectedResponse {
                    responseHeader(response)
                    evaluationForm(response)
                    savedReviews
                } else {
                    Text("Select a recorded response to review.")
                        .foregroundStyle(.secondary)
                }
                Divider()
                pairwiseSection
                Divider()
                exportSection
            }
            .padding(16)
        }
    }

    private func responseHeader(_ response: SQLiteStore.ReviewableResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(response.backend.displayName).font(.headline)
                Text(response.modelID).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let ttft = response.ttftMS {
                    Text(String(format: "TTFT %.0f ms", ttft)).font(.caption.monospaced())
                }
                if let tps = response.outputTokensPerSecond {
                    Text(String(format: "%.1f tok/s", tps)).font(.caption.monospaced())
                }
            }
            Text(response.userText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(response.rawText.isEmpty ? "(empty response)" : response.rawText)
                .textSelection(.enabled)
                .font(.system(.body))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func evaluationForm(_ response: SQLiteStore.ReviewableResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rate this response").font(.headline)
                Spacer()
                Button {
                    viewModel.thumbs = viewModel.thumbs == 1 ? nil : 1
                } label: {
                    Label("Good", systemImage: viewModel.thumbs == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .buttonStyle(.borderless)
                Button {
                    viewModel.thumbs = viewModel.thumbs == -1 ? nil : -1
                } label: {
                    Label("Poor", systemImage: viewModel.thumbs == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .buttonStyle(.borderless)
            }

            Text("\(EvaluationRubric.v1.title) · v\(EvaluationRubric.v1.version) · max \(viewModel.currentMaximumScore)")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(EvaluationRubric.v1.criteria) { criterion in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(criterion.name).font(.callout.weight(.medium))
                        Text(criterion.guidance).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { viewModel.scores[criterion.id] ?? 0 },
                            set: { viewModel.scores[criterion.id] = $0 }
                        ),
                        in: 0...criterion.maximumScore
                    ) {
                        Text("\(viewModel.scores[criterion.id] ?? 0)/\(criterion.maximumScore)")
                            .font(.caption.monospaced())
                            .frame(width: 44, alignment: .trailing)
                    }
                    .fixedSize()
                }
            }

            TextField("Judge (human name or frontier-model id)", text: $viewModel.judgedBy)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $viewModel.notes)
                .frame(minHeight: 50, maxHeight: 100)
                .border(Color.gray.opacity(0.3))
            HStack {
                Button("Save review") { viewModel.saveEvaluation() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Reset") { viewModel.resetDraft() }
                Spacer()
                Text("Submitted for \(response.modelID)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var savedReviews: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved reviews for this response").font(.headline)
            if viewModel.savedEvaluations.isEmpty {
                Text("No reviews yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(viewModel.savedEvaluations) { evaluation in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(evaluation.kind.rawValue) · \(evaluation.judgedBy)")
                            .font(.caption.weight(.semibold))
                        if let version = evaluation.rubricVersion, let title = evaluation.rubricTitle {
                            Text("\(title) v\(version) — \(evaluation.totalScore)/\(evaluation.maximumScore)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let thumbs = evaluation.thumbs {
                            Text(thumbs > 0 ? "thumbs up" : "thumbs down").font(.caption2)
                        }
                        ForEach(evaluation.scores, id: \.criterionID) { score in
                            if let criterion = EvaluationRubric.v1.criterion(id: score.criterionID) {
                                Text("\(criterion.name): \(score.score)/\(criterion.maximumScore)")
                                    .font(.caption2.monospaced())
                            }
                        }
                        if !evaluation.notes.isEmpty {
                            Text(evaluation.notes).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        viewModel.delete(evaluation)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var pairwiseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Blind pairwise comparison").font(.headline)
                Spacer()
                Toggle("Blind", isOn: $viewModel.pairBlind)
            }
            if viewModel.pairwiseGroups.isEmpty {
                Text("Record at least two successful responses to the same turn (run both backends in Compare or a benchmark).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Turn", selection: Binding(
                    get: { viewModel.pairTurnID ?? "" },
                    set: { viewModel.pairTurnID = $0; viewModel.resetPairCandidates() }
                )) {
                    ForEach(viewModel.pairwiseGroups) { group in
                        Text(group.userText.prefix(80)).tag(group.id)
                    }
                }
                .frame(maxWidth: 520)

                HStack(alignment: .top, spacing: 12) {
                    pairCard(label: "A", requestID: viewModel.pairAID)
                    pairCard(label: "B", requestID: viewModel.pairBID)
                }

                HStack(spacing: 12) {
                    Picker("Winner", selection: $viewModel.pairWinner) {
                        Text("A").tag(PairwiseEvaluation.Winner.a)
                        Text("B").tag(PairwiseEvaluation.Winner.b)
                        Text("Tie").tag(PairwiseEvaluation.Winner.tie)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    Button("Record decision") { viewModel.savePairwise() }
                    Text(viewModel.pairBlind ? "Model identities hidden until after the vote." : "Identities visible (not blind).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                TextField("Pairwise notes", text: $viewModel.pairNotes)
                    .textFieldStyle(.roundedBorder)

                if !viewModel.pairwiseHistory.isEmpty {
                    Text("Pairwise history").font(.caption.weight(.semibold))
                    ForEach(viewModel.pairwiseHistory.prefix(5)) { decision in
                        Text("\(decision.winner.rawValue.uppercased()) · \(decision.backendA.rawValue) vs \(decision.backendB.rawValue)\(decision.blind ? " · blind" : "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func pairCard(label: String, requestID: String?) -> some View {
        let response = viewModel.pairCandidates.first { $0.requestID == requestID }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Response \(label)").font(.caption.weight(.semibold))
                if !viewModel.pairBlind, let response {
                    Text("\(response.backend.displayName) · \(response.modelID)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(response?.rawText ?? "(missing)")
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var exportSection: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.exportBundle()
            } label: {
                Label("Export evaluation dataset", systemImage: "square.and.arrow.up")
            }
            if let path = viewModel.exportPath {
                Text(path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Text("\(viewModel.savedEvaluations.count) reviews on this response · \(viewModel.pairwiseHistory.count) pairwise total")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }
}
