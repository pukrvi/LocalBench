import SwiftUI
import Charts
import LocalBenchCore

/// Benchmark dashboard: history of controlled runs, a form to launch new
/// sequential/parallel runs with repetitions, aggregate stats, per-repetition
/// results, and CSV/JSON export (spec §5, §8, §12).
@MainActor
final class DashboardViewModel: ObservableObject {
    enum TrendMetric: String, CaseIterable, Identifiable {
        case ttft
        case wall
        case throughput

        var id: String { rawValue }
        var label: String {
            switch self {
            case .ttft: return "TTFT (ms)"
            case .wall: return "Wall (ms)"
            case .throughput: return "Decode (tok/s)"
            }
        }
    }

    struct DistributionBin: Identifiable {
        var id: String { "\(backend)-\(label)" }
        var label: String
        var backend: BackendID
        var count: Int
        var requestIDs: [String]
    }

    @Published var runs: [SQLiteStore.RunSummary] = []
    @Published var history: [SQLiteStore.HistoricalResult] = []
    @Published var selectedRunID: String?
    @Published var selectedResults: [ResultEnvelope] = []
    @Published var aggregates: [BackendAggregate] = []

    // Dashboard filters
    @Published var filterBackendRaw = "all"
    @Published var filterModel = "all"
    @Published var filterModeRaw = "all"
    @Published var filterDays = 30
    @Published var trendMetric: TrendMetric = .wall

    // New-run form
    @Published var prompt = "Summarize the key trade-offs of running LLM benchmarks entirely on-device."
    @Published var reps = 3
    @Published var schedule: RunSchedule = .sequential
    @Published var stateless = true
    @Published var prewarm = true
    @Published var temperature: Double = 0.7
    @Published var maxTokens = 256
    @Published var seedText = ""
    @Published var useApple = true
    @Published var useLMStudio = true
    @Published var lmURL = LMStudioBackend.defaultBaseURL.absoluteString
    @Published var lmModels: [LMStudioWire.ModelEntry] = []
    @Published var selectedLMModel: String?

    @Published var isRunning = false
    @Published var progressNote = ""
    @Published var lastError: String?
    @Published var exportPath: String?

    var selectedRun: SQLiteStore.RunSummary? {
        runs.first { $0.id == selectedRunID }
    }

    var cutoffDate: Date? {
        filterDays > 0 ? Date().addingTimeInterval(-Double(filterDays) * 86_400) : nil
    }

    var filteredRuns: [SQLiteStore.RunSummary] {
        guard let cutoffDate else { return runs }
        return runs.filter { $0.startedAt >= cutoffDate }
    }

    var availableModels: [String] {
        Array(Set(history.map(\.modelID))).sorted()
    }

    var filteredHistory: [SQLiteStore.HistoricalResult] {
        history.filter { point in
            if filterBackendRaw != "all" && point.backend.rawValue != filterBackendRaw { return false }
            if filterModel != "all" && point.modelID != filterModel { return false }
            if filterModeRaw != "all" && point.mode.rawValue != filterModeRaw { return false }
            if let cutoffDate, point.createdAt < cutoffDate { return false }
            return true
        }
    }

    /// Successful points that can be plotted for the selected trend metric.
    var trendPoints: [SQLiteStore.HistoricalResult] {
        filteredHistory.filter { !$0.isError && metricValue($0) != nil }
    }

    func metricValue(_ point: SQLiteStore.HistoricalResult) -> Double? {
        switch trendMetric {
        case .ttft: return point.ttftMS
        case .wall: return point.wallMS
        case .throughput: return point.outputTokensPerSecond
        }
    }

    /// Histogram buckets (20 tok/s wide) per backend for the current filter.
    var distribution: [DistributionBin] {
        let points = filteredHistory.filter { !$0.isError && $0.outputTokensPerSecond != nil }
        let width = 20.0
        var grouped: [BackendID: [(bucket: Int, requestID: String)]] = [:]
        for point in points {
            guard let tps = point.outputTokensPerSecond else { continue }
            grouped[point.backend, default: []].append((Int(tps / width), point.requestID))
        }
        var bins: [DistributionBin] = []
        for backend in grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let entries = grouped[backend] ?? []
            let counts = Dictionary(grouping: entries, by: \.bucket)
            for bucket in counts.keys.sorted() {
                let lower = Double(bucket) * width
                let upper = lower + width
                bins.append(DistributionBin(
                    label: String(format: "%.0f–%.0f", lower, upper),
                    backend: backend,
                    count: counts[bucket]?.count ?? 0,
                    requestIDs: counts[bucket]?.map(\.requestID) ?? []
                ))
            }
        }
        return bins
    }

    var trendXDomain: ClosedRange<Date>? {
        let dates = trendPoints.map(\.createdAt)
        guard let min = dates.min(), let max = dates.max() else { return nil }
        return min == max ? min.addingTimeInterval(-60)...max.addingTimeInterval(60) : min...max
    }

    func ensureStore() throws -> SQLiteStore {
        try SharedDatabase.shared()
    }

    func reload() {
        do {
            let store = try ensureStore()
            runs = try store.benchmarkRunSummaries()
            history = try store.historicalResults()
            if selectedRunID == nil || !runs.contains(where: { $0.id == selectedRunID }) {
                selectedRunID = runs.first?.id
            }
            loadSelected()
        } catch {
            lastError = String(describing: error)
        }
    }

    func loadSelected() {
        guard let run = selectedRun, let conversationID = run.conversationID else {
            selectedResults = []
            aggregates = []
            return
        }
        do {
            let store = try ensureStore()
            selectedResults = try store.results(conversationID: conversationID)
            let reconstructed = BenchmarkRun(
                id: run.id,
                label: run.label,
                conversationID: conversationID,
                schedule: RunSchedule(rawValue: run.schedule) ?? .sequential,
                repetitions: run.repetitions,
                stateless: run.stateless,
                results: selectedResults
            )
            aggregates = AggregateBuilder.build(run: reconstructed)
        } catch {
            lastError = String(describing: error)
        }
    }

    func discoverModels() {
        Task {
            let url = URL(string: lmURL) ?? LMStudioBackend.defaultBaseURL
            let (models, _) = await LMStudioBackend.discover(baseURL: url)
            lmModels = models
            if selectedLMModel == nil || !models.contains(where: { $0.id == selectedLMModel }) {
                selectedLMModel = models.first?.id
            }
        }
    }

    func startBenchmark() {
        guard !isRunning else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isRunning = true
        progressNote = "starting…"
        lastError = nil
        exportPath = nil
        Task {
            await runBenchmark(prompt: text)
            isRunning = false
            progressNote = ""
        }
    }

    private func makeLMBackend() -> LMStudioBackend {
        let url = URL(string: lmURL) ?? LMStudioBackend.defaultBaseURL
        let vision = lmModels.first { $0.id == selectedLMModel }?.capabilities?.vision == true
        let capabilities = CapabilityReport(text: true, streaming: true, images: vision, guidedGeneration: true, toolCalling: false, reasoning: false)
        return LMStudioBackend(baseURL: url, modelID: selectedLMModel ?? "none", discoveredCapabilities: capabilities)
    }

    private func runBenchmark(prompt text: String) async {
        do {
            let store = try ensureStore()
            var backendMap: [BackendID: ChatBackend] = [:]
            if useApple { backendMap[.apple] = AppleBackend() }
            if useLMStudio { backendMap[.lmStudio] = makeLMBackend() }
            guard !backendMap.isEmpty else {
                lastError = "Select at least one backend."
                return
            }

            var options = SamplingOptions()
            options.temperature = temperature
            options.maximumOutputTokens = max(maxTokens, 1)
            if let seed = UInt64(seedText) { options.seed = seed }

            let configuration = BenchmarkRunner.Configuration(
                prompt: text,
                schedule: schedule,
                repetitions: reps,
                stateless: stateless,
                options: options,
                prewarm: prewarm
            )

            let runner = BenchmarkRunner(backends: backendMap, store: store)
            progressNote = "running \(reps) repetition(s) \(schedule.rawValue)…"
            let run = await runner.run(configuration: configuration)
            try store.saveBenchmarkRun(run)
            selectedRunID = run.id
            reload()
        } catch {
            lastError = String(describing: error)
        }
    }

    func exportSelected() {
        guard let run = selectedRun, let conversationID = run.conversationID else { return }
        do {
            let store = try ensureStore()
            var results = try store.results(conversationID: conversationID)
            // Attach full evidence so exports are self-contained.
            for index in results.indices {
                results[index].traces = try store.wireTraces(requestID: results[index].requestID)
            }
            let reconstructed = BenchmarkRun(
                id: run.id,
                label: run.label,
                conversationID: conversationID,
                schedule: RunSchedule(rawValue: run.schedule) ?? .sequential,
                repetitions: run.repetitions,
                stateless: run.stateless,
                results: results
            )
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalBenchExports", isDirectory: true)
            let baseName = "localbench-\(Int(Date().timeIntervalSince1970))"
            let (jsonURL, csvURL) = try ExportService.write(run: reconstructed, to: directory, fileBaseName: baseName)
            exportPath = "\(jsonURL.path)  +  \(csvURL.path)"
        } catch {
            lastError = "Export failed: \(error)"
        }
    }

    func revealExports() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalBenchExports", isDirectory: true)
        NSWorkspace.shared.open(directory)
    }
}

struct DashboardScreen: View {
    @StateObject private var viewModel = DashboardViewModel()
    @EnvironmentObject var router: AppRouter

    var body: some View {
        NavigationSplitView {
            runList
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                newRunBar
                Divider()
                if viewModel.selectedRunID == nil {
                    emptyState
                } else {
                    runDetail
                }
            }
        }
        .navigationTitle("Benchmarks")
        .onAppear {
            viewModel.reload()
            viewModel.discoverModels()
        }
    }

    private var runList: some View {
        List(selection: Binding(
            get: { viewModel.selectedRunID },
            set: { newValue in
                viewModel.selectedRunID = newValue
                viewModel.loadSelected()
            }
        )) {
            ForEach(viewModel.filteredRuns) { run in
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.label.isEmpty ? "(no label)" : run.label)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(run.startedAt, style: .date)
                        Text("·")
                        Text("\(run.repetitions)× \(run.schedule)")
                        Text("·")
                        Text("\(run.resultCount) results")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .tag(run.id)
            }
        }
        .overlay {
            if viewModel.filteredRuns.isEmpty {
                Text("No benchmark runs in this filter.")
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            Button {
                viewModel.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }

    private var newRunBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Benchmark prompt", text: $viewModel.prompt)
                    .textFieldStyle(.roundedBorder)
                Button("Run benchmark") {
                    viewModel.startBenchmark()
                }
                .disabled(viewModel.isRunning || viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.progressNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                Stepper("Reps: \(viewModel.reps)", value: $viewModel.reps, in: 1...7)
                    .fixedSize()
                Picker("", selection: $viewModel.schedule) {
                    Text("Sequential").tag(RunSchedule.sequential)
                    Text("Parallel (contended)").tag(RunSchedule.parallel)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Toggle("Stateless", isOn: $viewModel.stateless)
                Toggle("Prewarm", isOn: $viewModel.prewarm)
                HStack(spacing: 4) {
                    Text("temp")
                    TextField("0.7", value: $viewModel.temperature, format: .number.precision(.fractionLength(1)))
                        .frame(width: 50)
                }
                HStack(spacing: 4) {
                    Text("max tokens")
                    TextField("256", value: $viewModel.maxTokens, format: .number)
                        .frame(width: 60)
                }
                HStack(spacing: 4) {
                    Text("seed")
                    TextField("optional", text: $viewModel.seedText)
                        .frame(width: 80)
                        .help("Apple FM has no user-facing seed; a seed forces greedy decoding (.greedy) and applies to LM Studio only")
                }
                Toggle("Apple", isOn: $viewModel.useApple)
                Toggle("LM Studio", isOn: $viewModel.useLMStudio)
                if viewModel.useLMStudio {
                    Picker("LM model", selection: $viewModel.selectedLMModel) {
                        Text("none").tag(String?.none)
                        ForEach(viewModel.lmModels, id: \.id) { model in
                            Text(model.id).tag(String?.some(model.id))
                        }
                    }
                    .frame(width: 220)
                    .onTapGesture {}
                }
                Spacer()
            }
            .font(.caption)
            if let error = viewModel.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let path = viewModel.exportPath {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up.on.square")
                    Text("Exported: \(path)").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Button("Reveal") { viewModel.revealExports() }
                }
                .foregroundStyle(.green)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No benchmark run selected")
            Text("Launch a run with the controls above; results and aggregates appear here.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let run = viewModel.selectedRun {
                    HStack {
                        Text(run.startedAt, style: .date)
                        Text("·")
                        Text(run.schedule)
                        Text("·")
                        Text(run.stateless ? "stateless" : "conversation")
                        Spacer()
                        Button("Export CSV/JSON") { viewModel.exportSelected() }
                            .disabled(viewModel.selectedResults.isEmpty)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    filterBar

                    HStack(alignment: .top, spacing: 14) {
                        trendChart
                        distributionChart
                    }

                    if viewModel.filteredHistory.isEmpty {
                        Text("No measurements match the current filters.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(viewModel.aggregates, id: \.backend) { aggregate in
                        AggregateCard(aggregate: aggregate)
                    }

                    resultsTable
                }
            }
            .padding(16)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("Backend", selection: $viewModel.filterBackendRaw) {
                Text("All backends").tag("all")
                ForEach(BackendID.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend.rawValue)
                }
            }
            .frame(width: 190)

            Picker("Model", selection: $viewModel.filterModel) {
                Text("All models").tag("all")
                ForEach(viewModel.availableModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .frame(width: 220)

            Picker("Mode", selection: $viewModel.filterModeRaw) {
                Text("All modes").tag("all")
                Text("Conversation").tag(RunMode.conversation.rawValue)
                Text("Stateless").tag(RunMode.stateless.rawValue)
            }
            .frame(width: 170)

            Picker("Range", selection: $viewModel.filterDays) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("All time").tag(0)
            }
            .frame(width: 130)

            Picker("Trend", selection: $viewModel.trendMetric) {
                ForEach(DashboardViewModel.TrendMetric.allCases) { metric in
                    Text(metric.label).tag(metric)
                }
            }
            .frame(width: 170)

            Spacer()
            Text("\(viewModel.filteredHistory.count) measurements")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Historical trend — \(viewModel.trendMetric.label)")
                .font(.headline)
            if viewModel.trendPoints.isEmpty {
                Text("No plottable measurements for this filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(viewModel.trendPoints) { point in
                    LineMark(
                        x: .value("Date", point.createdAt),
                        y: .value(viewModel.trendMetric.label, viewModel.metricValue(point) ?? 0)
                    )
                    .foregroundStyle(by: .value("Backend", point.backend.displayName))
                    .symbol(by: .value("Backend", point.backend.displayName))
                    PointMark(
                        x: .value("Date", point.createdAt),
                        y: .value(viewModel.trendMetric.label, viewModel.metricValue(point) ?? 0)
                    )
                    .foregroundStyle(by: .value("Backend", point.backend.displayName))
                }
                .chartXScale(domain: viewModel.trendXDomain ?? Date()...Date())
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = location.x - geometry[plotFrame].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                if let nearest = viewModel.trendPoints.min(by: {
                                    abs($0.createdAt.timeIntervalSince(date)) < abs($1.createdAt.timeIntervalSince(date))
                                }) {
                                    router.openTraces(requestID: nearest.requestID)
                                }
                            }
                    }
                }
                .frame(minHeight: 200)
                Text("Click a point to open its trace evidence.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var distributionChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Decode throughput distribution")
                .font(.headline)
            if viewModel.distribution.isEmpty {
                Text("No decode measurements (sub-50 ms bursts are reported as unavailable).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(viewModel.distribution) { bin in
                    BarMark(
                        x: .value("tok/s", bin.label),
                        y: .value("Count", bin.count)
                    )
                    .foregroundStyle(by: .value("Backend", bin.backend.displayName))
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = location.x - geometry[plotFrame].origin.x
                                guard let label: String = proxy.value(atX: x) else { return }
                                if let bin = viewModel.distribution.first(where: { $0.label == label }),
                                   let requestID = bin.requestIDs.first {
                                    router.openTraces(requestID: requestID)
                                }
                            }
                    }
                }
                .frame(minHeight: 200)
                Text("Click a bar to open one of its traces.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var resultsTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-repetition results")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    headerCell("rep")
                    headerCell("backend")
                    headerCell("warmth")
                    headerCell("ttft")
                    headerCell("wall")
                    headerCell("tok/s")
                    headerCell("tokens (provenance)")
                    headerCell("status")
                    headerCell("evidence")
                }
                ForEach(viewModel.selectedResults, id: \.requestID) { result in
                    GridRow {
                        cell(String(result.repetitionIndex))
                        cell(result.backend.displayName)
                        cell(result.warmth.rawValue)
                        cell(result.ttftMS.map { String(format: "%.0f ms", $0) } ?? "n/a")
                        cell(String(format: "%.0f ms", result.wallMS))
                        cell(result.outputTokensPerSecond.map { String(format: "%.1f", $0) } ?? "n/a")
                        cell(tokenCell(result))
                        cell(result.error.map { "\($0.kind.rawValue)" } ?? result.finishReason.rawValue)
                        Button {
                            router.openTraces(requestID: result.requestID)
                        } label: {
                            Text("\(result.tracesFingerprint.isEmpty ? "—" : "open")")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                        .disabled(result.tracesFingerprint.isEmpty)
                    }
                }
            }
            .font(.caption.monospaced())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func tokenCell(_ result: ResultEnvelope) -> String {
        switch result.tokenProvenance {
        case .native, .server:
            return "in \(result.inputTokens ?? -1) / out \(result.outputTokens ?? -1) (\(result.tokenProvenance.rawValue))"
        default:
            return "n/a (\(result.tokenProvenance.rawValue))"
        }
    }

    private func headerCell(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func cell(_ text: String) -> some View {
        Text(text)
    }
}

struct AggregateCard: View {
    let aggregate: BackendAggregate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(aggregate.backend.displayName)
                    .font(.headline)
                Text(aggregate.modelID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(aggregate.successes) ok · \(aggregate.failures) fail · \(aggregate.cancellations) cancelled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
                statRow("TTFT", aggregate.ttftMS)
                statRow("Wall", aggregate.wallMS)
                statRow("Decode tok/s", aggregate.outputTokensPerSecond)
            }
            Text("n = successes only; cancelled/failed excluded (spec §12)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    func statRow(_ name: String, _ stats: BackendAggregate.Stats?) -> some View {
        GridRow {
            Text(name).font(.caption).foregroundStyle(.secondary)
            if let stats {
                Text(stats.median.map { String(format: "median %.1f", $0) } ?? "n/a")
                    .font(.caption.monospaced())
                Text(stats.p95.map { String(format: "p95 %.1f", $0) } ?? "n/a")
                    .font(.caption.monospaced())
                Text(stats.mean.map { String(format: "mean %.1f", $0) } ?? "n/a")
                    .font(.caption.monospaced())
            } else {
                Text("n/a").font(.caption.monospaced())
                Text("n/a").font(.caption.monospaced())
                Text("n/a").font(.caption.monospaced())
            }
        }
    }
}
