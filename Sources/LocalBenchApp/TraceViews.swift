import SwiftUI
import LocalBenchCore

/// One evidence record row: kind badge, sequence, offset, hash, and the data
/// itself (preview collapsed, full text expandable + copyable).
struct TraceRecordRow: View {
    let record: TraceRecord
    @State private var expanded = false

    private var kindColor: Color {
        switch record.kind {
        case .requestBody: return .orange
        case .sseLine: return .purple
        case .event: return .blue
        case .meta: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(record.kind.rawValue)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(.white)
                    .background(kindColor, in: Capsule())
                Text("seq \(record.seq)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(String(format: "+%.1f ms", record.offsetMS))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text("\(record.byteCount) B")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(record.sha256.prefix(12) + "…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.data, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy raw data")
            }
            if expanded {
                Text(record.data.isEmpty ? "(empty)" : record.data)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text(record.data.isEmpty ? "(empty)" : String(record.data.prefix(240)))
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .padding(.vertical, 3)
    }
}

/// Scrollable list of a request's evidence records.
struct TraceRecordList: View {
    let records: [TraceRecord]
    var emptyNote: String = "No trace records for this request."

    var body: some View {
        if records.isEmpty {
            Text(emptyNote)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(records, id: \.seq) { record in
                        TraceRecordRow(record: record)
                        Divider()
                    }
                }
                .padding(10)
            }
        }
    }
}

/// Independent-verification result for one request.
struct VerifyReportView: View {
    let report: TraceVerifier.Report

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: report.passed ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(report.passed ? Color.green : Color.red)
                Text(report.passed ? "Verified — trace evidence recomputes to the recorded metrics" : "Verification failed")
                    .font(.headline)
            }
            if !report.passed {
                ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                    Text("• \(finding)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.red)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                GridRow {
                    Text("").font(.caption.weight(.semibold))
                    Text("recomputed").font(.caption.weight(.semibold)).frame(width: 110, alignment: .trailing)
                }
                if let ttft = report.recomputedTTFTMS {
                    GridRow {
                        Text("TTFT").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.1f ms", ttft)).font(.caption.monospaced()).frame(width: 110, alignment: .trailing)
                    }
                }
                if let wall = report.recomputedWallMS {
                    GridRow {
                        Text("Wall").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.1f ms", wall)).font(.caption.monospaced()).frame(width: 110, alignment: .trailing)
                    }
                }
                if let input = report.recomputedInputTokens {
                    GridRow {
                        Text("Input tokens").font(.caption).foregroundStyle(.secondary)
                        Text(String(input)).font(.caption.monospaced()).frame(width: 110, alignment: .trailing)
                    }
                }
                if let output = report.recomputedOutputTokens {
                    GridRow {
                        Text("Output tokens").font(.caption).foregroundStyle(.secondary)
                        Text(String(output)).font(.caption.monospaced()).frame(width: 110, alignment: .trailing)
                    }
                }
                if let tps = report.recomputedOutputTokensPerSecond {
                    GridRow {
                        Text("Decode tok/s").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.2f", tps)).font(.caption.monospaced()).frame(width: 110, alignment: .trailing)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((report.passed ? Color.green : Color.red).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
