import Foundation

/// URLSession construction for loopback inference traffic.
///
/// `URLSession.shared` follows HTTP redirects automatically, which would let a
/// local (or compromised local) endpoint redirect the request — including the
/// prompt and any attachments — to a remote host. The delegate below re-checks
/// every redirect target against `NetworkPolicy` and refuses anything that is
/// not loopback. A refused redirect is surfaced to the caller as the original
/// 3xx response; it is never followed.
public enum LoopbackHTTP {
    /// Ephemeral session with no disk cache and a redirect guard. One session
    /// per backend instance (delegate lifetime is tied to the session).
    public static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: LoopbackRedirectGuard(), delegateQueue: nil)
    }
}

public final class LoopbackRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }

    /// Pure policy check used by the delegate and by tests.
    public static func isAllowedRedirect(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        if case .allowed = NetworkPolicy.decision(for: url) { return true }
        return false
    }

    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        // nil = do not follow; the 3xx response is delivered as final.
        completionHandler(Self.isAllowedRedirect(request) ? request : nil)
    }
}