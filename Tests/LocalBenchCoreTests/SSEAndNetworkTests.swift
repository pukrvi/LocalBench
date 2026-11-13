import Testing
import Foundation
@testable import LocalBenchCore

@Suite("SSE parser")
struct SSEParserTests {
    @Test func parsesCompleteDataLines() {
        var parser = SSEParser()
        let events = parser.feed("data: {\"a\":1}\n\n")
        #expect(events == [.data("{\"a\":1}")])
    }

    @Test func toleratesHostileChunkBoundaries() {
        var parser = SSEParser()
        var events: [SSEParser.Event] = []
        events += parser.feed("da")
        events += parser.feed("ta: {\"x")
        events += parser.feed("\r")
        events += parser.feed("\n\ndata: ")
        events += parser.feed("[DONE]")
        // "[DONE]" never saw a blank-line terminator: finish() flushes it.
        events += parser.finish()
        #expect(events.count == 2)
        #expect(events[0] == .data("{\"x"))
        #expect(events[1] == .done)
    }

    @Test func multiLineDataAccumulates() {
        var parser = SSEParser()
        let events = parser.feed("data: line1\ndata: line2\n\n")
        #expect(events == [.data("line1\nline2")])
    }

    @Test func commentsAndUnknownFieldsIgnored() {
        var parser = SSEParser()
        let events = parser.feed(": keepalive\nevent: message\ndata: 1\nid: 5\n\n")
        #expect(events == [.data("1")])
    }

    @Test func doneSentinelRecognized() {
        var parser = SSEParser()
        let events = parser.feed("data: [DONE]\n\n")
        #expect(events.contains(.done))
    }

    @Test func finishFlushesPendingData() {
        var parser = SSEParser()
        _ = parser.feed("data: tail")
        let events = parser.finish()
        #expect(events == [.data("tail")])
    }
}

@Suite("Network policy (loopback only)")
struct NetworkPolicyTests {
    @Test func allowsLocalhostVariants() {
        for url in ["http://127.0.0.1:1234/v1", "http://localhost:1234", "http://127.0.0.2:1234", "http://[::1]:1234"] {
            #expect({
                if case .allowed = NetworkPolicy.decision(for: URL(string: url)!) { return true }
                return false
            }(), "expected allowed: \(url)")
        }
    }

    @Test func rejectsRemoteHostsByDefault() {
        for url in ["http://192.168.1.10:1234", "https://api.example.com/v1", "http://10.0.0.5:1234", "http://my-lm-studio-host:1234"] {
            #expect({
                if case .rejected = NetworkPolicy.decision(for: URL(string: url)!) { return true }
                return false
            }(), "expected rejected: \(url)")
        }
    }

    @Test func rejectsNonHTTPOrMalformed() {
        #expect({
            if case .rejected = NetworkPolicy.decision(for: URL(string: "ftp://127.0.0.1:1234")!) { return true }
            return false
        }())
        #expect({
            if case .rejected = NetworkPolicy.decision(for: URL(string: "http://")!) { return true }
            return false
        }())
    }

    @Test func validatedLoopbackThrowsWithExplanation() throws {
        do {
            _ = try NetworkPolicy.validatedLoopbackURL(URL(string: "http://8.8.8.8:1234")!)
            Issue.record("expected throw")
        } catch let error as BackendError {
            #expect(error.kind == .unavailable)
            #expect(error.message.contains("Non-loopback"))
        }
    }
}
