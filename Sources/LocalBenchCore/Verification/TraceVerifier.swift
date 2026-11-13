import Foundation

/// Recomputes metrics from stored trace records and diffs them against the
/// recorded results. This is the independent-verification mechanism: a human
/// expert or another model can re-derive TTFT/wall/tokens purely from the
/// stored raw wire data without trusting the recording process (spec §12).
public enum TraceVerifier {
    /// The recorded values a trace is checked against.
    public struct Expected: Sendable {
        public var modelID: String?
        public var ttftMS: Double?
        public var wallMS: Double?
        public var outputTokensPerSecond: Double?
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var tokenProvenance: String?
        public var errorKind: String?
        /// The recorded visible response, when known. A reasoning-only response
        /// legitimately has empty text, so the verifier must not treat "no
        /// content-bearing wire line" as a defect when the recording itself
        /// says there was no visible content.
        public var rawText: String?

        public init(modelID: String? = nil,
                    ttftMS: Double? = nil,
                    wallMS: Double? = nil,
                    outputTokensPerSecond: Double? = nil,
                    inputTokens: Int? = nil,
                    outputTokens: Int? = nil,
                    tokenProvenance: String? = nil,
                    errorKind: String? = nil,
                    rawText: String? = nil) {
            self.modelID = modelID
            self.ttftMS = ttftMS
            self.wallMS = wallMS
            self.outputTokensPerSecond = outputTokensPerSecond
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.tokenProvenance = tokenProvenance
            self.errorKind = errorKind
            self.rawText = rawText
        }

        public init(_ result: ResultEnvelope) {
            self.init(
                modelID: result.modelID,
                ttftMS: result.ttftMS,
                wallMS: result.wallMS,
                outputTokensPerSecond: result.outputTokensPerSecond,
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens,
                tokenProvenance: result.tokenProvenance.rawValue,
                errorKind: result.error?.kind.rawValue,
                rawText: result.rawText
            )
        }
    }

    /// Numeric tolerances. The capture clock is aligned to dispatch, but the
    /// capture timestamp for an event is taken at a slightly different instant
    /// than the recorder's own `now()` — and the recorder's end time includes
    /// stream-teardown bookkeeping after the last wire line. Both effects are
    /// milliseconds-scale; the tolerances below are generous but still tight
    /// enough to catch fabricated or transposed numbers.
    public struct Tolerances: Sendable {
        public var timingMS: Double
        public var tokensPerSecondFraction: Double

        public init(timingMS: Double = 150, tokensPerSecondFraction: Double = 0.10) {
            self.timingMS = timingMS
            self.tokensPerSecondFraction = tokensPerSecondFraction
        }

        public static let standard = Tolerances()
    }

    /// Verdict for one request's trace set.
    public struct Report: Sendable {
        public var recomputedTTFTMS: Double?
        public var recomputedWallMS: Double?
        public var recomputedInputTokens: Int?
        public var recomputedOutputTokens: Int?
        public var recomputedOutputTokensPerSecond: Double?
        /// Empty = everything checks out.
        public var findings: [String]

        public var passed: Bool { findings.isEmpty }
    }

    public static func verify(records: [TraceRecord], expected: Expected?, tolerances: Tolerances = .standard) -> Report {
        var findings: [String] = []
        var report = Report(
            recomputedTTFTMS: nil,
            recomputedWallMS: nil,
            recomputedInputTokens: nil,
            recomputedOutputTokens: nil,
            recomputedOutputTokensPerSecond: nil,
            findings: findings
        )

        // 1. Structural integrity: seq strictly 0..n-1 and every record's hash
        //    and byte count must match its data.
        for (index, record) in records.enumerated() {
            if record.seq != index {
                findings.append("seq out of order at index \(index): record.seq=\(record.seq)")
            }
            let actualHash = Sha256.hex(record.data)
            if actualHash != record.sha256 {
                findings.append("sha256 mismatch at seq \(record.seq) (\(record.kind.rawValue)): trace says \(record.sha256.prefix(12))…, data hashes to \(actualHash.prefix(12))…")
            }
            if record.byteCount != record.data.utf8.count {
                findings.append("byte_count mismatch at seq \(record.seq): says \(record.byteCount), data is \(record.data.utf8.count)")
            }
        }

        // 2. Monotonic offsets.
        for (index, record) in records.enumerated() where index > 0 && record.offsetMS < records[index - 1].offsetMS {
            findings.append("offset goes backwards at seq \(record.seq): \(record.offsetMS) < \(records[index - 1].offsetMS)")
        }

        // 3. Recompute metrics from the evidence itself.
        let sseLines = records.filter { $0.kind == .sseLine }
        let events = records.filter { $0.kind == .event }
        let requestBodies = records.filter { $0.kind == .requestBody }

        if let body = requestBodies.first {
            if let data = body.data.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let wireModel = object["model"] as? String {
                if let expectedModel = expected?.modelID, wireModel != expectedModel {
                    findings.append("request_body model '\(wireModel)' ≠ recorded model_id '\(expectedModel)'")
                }
            } else {
                findings.append("request_body at seq \(body.seq) is not decodable JSON")
            }
        }

        if !sseLines.isEmpty {
            // LM Studio evidence path: verbatim lines are ground truth.
            var firstContentMS: Double?
            var lastLineMS: Double?
            var inputTokens: Int?
            var outputTokens: Int?
            for line in sseLines {
                lastLineMS = line.offsetMS
                guard line.data.hasPrefix("data:") else { continue }
                let payload = line.data.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { continue }
                guard let data = payload.data(using: .utf8),
                      let chunk = try? JSONDecoder().decode(LMStudioWire.StreamChunk.self, from: data) else {
                    findings.append("sse_line at seq \(line.seq) is not a decodable chat chunk")
                    continue
                }
                if firstContentMS == nil,
                   let content = chunk.choices?.first?.delta?.content,
                   !content.isEmpty {
                    firstContentMS = line.offsetMS
                }
                if let usage = chunk.usage {
                    inputTokens = usage.promptTokens
                    outputTokens = usage.completionTokens
                }
            }
            report.recomputedTTFTMS = firstContentMS
            report.recomputedWallMS = lastLineMS
            report.recomputedInputTokens = inputTokens
            report.recomputedOutputTokens = outputTokens
            if let first = firstContentMS, let last = lastLineMS, let out = outputTokens,
               last > first, (last - first) >= Double(Metrics.minimumDecodeWindowNS) / 1_000_000 {
                report.recomputedOutputTokensPerSecond = Double(out) / ((last - first) / 1000)
            }
            // No content-bearing line is not itself a defect: reasoning-only
            // responses legitimately produce none. Section 4 checks it against
            // the recorded visible text.
        } else if !events.isEmpty {
            // Apple evidence path: no wire access; verify against the
            // normalized event stream itself (self-consistency, honestly
            // labeled via the meta record).
            var firstContentMS: Double?
            var lastEventMS: Double?
            var inputTokens: Int?
            var outputTokens: Int?
            for event in events {
                lastEventMS = event.offsetMS
                guard let data = event.data.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(StreamEvent.self, from: data) else {
                    findings.append("event record at seq \(event.seq) is not a decodable StreamEvent")
                    continue
                }
                switch decoded {
                case .delta(_, let text):
                    if firstContentMS == nil, !text.isEmpty {
                        firstContentMS = event.offsetMS
                    }
                case .usage(_, let input, let output, _, _, _):
                    if let input { inputTokens = input }
                    if let output { outputTokens = output }
                default:
                    break
                }
            }
            report.recomputedTTFTMS = firstContentMS
            report.recomputedWallMS = lastEventMS
            report.recomputedInputTokens = inputTokens
            report.recomputedOutputTokens = outputTokens
            if let first = firstContentMS, let last = lastEventMS, let out = outputTokens,
               last > first, (last - first) >= Double(Metrics.minimumDecodeWindowNS) / 1_000_000 {
                report.recomputedOutputTokensPerSecond = Double(out) / ((last - first) / 1000)
            }
            // Any meta record documents provenance (wire availability, model
            // normalization, or an unavailable attempt). Do not require a
            // specific word: the note's content is human-readable, not a token
            // the verifier should pattern-match.
            let sawMeta = records.contains { $0.kind == .meta }
            if !sawMeta {
                findings.append("expected a meta record documenting evidence provenance; none found")
            }
        } else if records.contains(where: { $0.kind == .meta }) {
            // Meta-only evidence: an unavailable/prewarm attempt, or a request
            // that produced no stream. Nothing numeric is recomputable; the
            // meta note explains why. A success claim with no evidence is a
            // real finding.
            if let expected, expected.errorKind == nil {
                findings.append("meta-only trace evidence but the result is recorded as a success")
            }
        } else {
            findings.append("no evidence records (no sse_line, no event) — cannot recompute anything")
        }

        // 4. Diff against the recorded result.
        if let expected {
            func diff(_ label: String, recorded: Double?, recomputed: Double?, tolerance: Double) {
                switch (recorded, recomputed) {
                case let (recorded?, recomputed?):
                    if abs(recorded - recomputed) > tolerance {
                        findings.append(String(format: "%@: recorded %.2f vs recomputed %.2f (tolerance %.0f ms)", label, recorded, recomputed, tolerance))
                    }
                case (nil, nil):
                    break // neither recorded nor recomputable — consistent
                case (nil, _):
                    findings.append("\(label): nothing recorded but trace recomputed \(String(format: "%.2f", recomputed ?? -1))")
                default:
                    break // recorded but not independently recomputable
                }
            }
            diff("ttft_ms", recorded: expected.ttftMS, recomputed: report.recomputedTTFTMS, tolerance: tolerances.timingMS)
            diff("wall_ms", recorded: expected.wallMS, recomputed: report.recomputedWallMS, tolerance: tolerances.timingMS)

            if let expectedIn = expected.inputTokens, report.recomputedInputTokens != nil, expectedIn != report.recomputedInputTokens {
                findings.append("input tokens: recorded \(expectedIn) vs recomputed \(report.recomputedInputTokens ?? -1) (exact match required)")
            }
            if let expectedOut = expected.outputTokens, report.recomputedOutputTokens != nil, expectedOut != report.recomputedOutputTokens {
                findings.append("output tokens: recorded \(expectedOut) vs recomputed \(report.recomputedOutputTokens ?? -1) (exact match required)")
            }

            if let recordedTPS = expected.outputTokensPerSecond, let recomputedTPS = report.recomputedOutputTokensPerSecond {
                let reference = max(abs(recordedTPS), 0.001)
                if abs(recordedTPS - recomputedTPS) / reference > tolerances.tokensPerSecondFraction {
                    findings.append(String(format: "decode tok/s: recorded %.2f vs recomputed %.2f (>%.0f%%)", recordedTPS, recomputedTPS, tolerances.tokensPerSecondFraction * 100))
                }
            }

            if expected.errorKind == nil, report.recomputedTTFTMS == nil, report.recomputedWallMS != nil,
               let rawText = expected.rawText, !rawText.isEmpty {
                findings.append("recorded response text exists but trace evidence has no content-bearing line")
            }
        }

        report.findings = findings
        return report
    }
}
