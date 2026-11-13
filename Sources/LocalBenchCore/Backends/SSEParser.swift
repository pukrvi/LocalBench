import Foundation

/// Incremental, allocation-light SSE parser for `data:`-line streams.
/// Pure and deterministic: feed arbitrary line fragments, receive events.
/// Unit-tested with hostile chunk boundaries (spec §12, §13).
public struct SSEParser {
    public enum Event: Equatable, Sendable {
        case data(String)
        case comment(String)
        case done
    }

    public private(set) var pendingLine: String = ""
    public private(set) var pendingDataBuffer: [String] = []

    public init() {}

    /// Feed one already-split line (e.g. from `URLSession.AsyncBytes.lines`,
    /// which strips the newline). Equivalent to `feed(line + "\n")`; an empty
    /// line dispatches the accumulated event.
    public mutating func feedLine(_ line: String) -> [Event] {
        feed(line + "\n")
    }

    /// Feed one raw chunk (any byte count). Returns events completed by this chunk.
    public mutating func feed(_ chunk: String) -> [Event] {
        var events: [Event] = []
        for character in chunk {
            if character == "\n" {
                if let event = completeLine() {
                    events.append(event)
                }
            } else if character == "\r" {
                // Tolerate CRLF: strip and wait for the LF.
                continue
            } else {
                pendingLine.append(character)
            }
        }
        return events
    }

    /// Signal end-of-stream: a final unterminated line still completes, and
    /// any accumulated data payload that never saw its blank-line terminator
    /// is flushed (tolerant of truncated streams).
    public mutating func finish() -> [Event] {
        var events: [Event] = []
        if let event = completeLine() {
            events.append(event)
        }
        if !pendingDataBuffer.isEmpty {
            let payload = pendingDataBuffer.joined(separator: "\n")
            pendingDataBuffer.removeAll(keepingCapacity: true)
            events.append(payload == "[DONE]" ? .done : .data(payload))
        }
        return events
    }

    private mutating func completeLine() -> Event? {
        let line = pendingLine
        pendingLine.removeAll(keepingCapacity: true)
        if line.isEmpty {
            // Blank line = end of event; dispatch accumulated data lines.
            if pendingDataBuffer.isEmpty { return nil }
            let payload = pendingDataBuffer.joined(separator: "\n")
            pendingDataBuffer.removeAll(keepingCapacity: true)
            if payload == "[DONE]" { return .done }
            return .data(payload)
        }
        if line.hasPrefix(":") {
            // Comments are ignored by SSE clients (spec §4 of text/event-stream).
            return nil
        }
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.hasPrefix(" ") { value = value.dropFirst(1) }
            pendingDataBuffer.append(String(value))
            return nil
        }
        // Unsupported fields (id:, event:, retry:) are ignored per SSE spec.
        return nil
    }
}
