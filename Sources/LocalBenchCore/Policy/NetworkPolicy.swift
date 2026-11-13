import Foundation

/// Local-only network policy (spec §1, §9): LM Studio endpoints must bind to
/// the loopback interface. Remote model endpoints are rejected by default.
public enum NetworkPolicy {
    public enum Decision: Equatable, Sendable {
        case allowed
        case rejected(reason: String)
    }

    /// Validate an http(s) URL for use as an inference endpoint.
    public static func decision(for url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .rejected(reason: "Only http/https endpoints are allowed.")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return .rejected(reason: "Endpoint URL has no host.")
        }
        // Loopback names: localhost and 127.0.0.0/8 and ::1.
        if host == "localhost" { return .allowed }
        if host == "::1" || host == "[::1]" { return .allowed }
        if host.hasPrefix("127.") {
            let octets = host.split(separator: ".").compactMap { Int($0) }
            if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }), octets[0] == 127 {
                return .allowed
            }
        }
        return .rejected(reason: "Non-loopback host '\(host)' rejected. LocalBench never sends inference traffic off this machine.")
    }

    /// Convenience: return the URL or throw.
    public static func validatedLoopbackURL(_ url: URL) throws -> URL {
        switch decision(for: url) {
        case .allowed: return url
        case .rejected(let reason): throw BackendError(kind: .unavailable, message: reason)
        }
    }
}
