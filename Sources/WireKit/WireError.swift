import Foundation

/// Transport-level failures shared by every wire client.
public enum WireError: Error, LocalizedError, Sendable, Equatable {
  case truncated
  case connectionFailed(String)
  case timedOut(String)
  case closed
  case protocolViolation(String)
  case authenticationFailed(String)
  case unsupported(String)
  /// The server asked for the password in a form anyone on the network could read or replay (cleartext, MD5, a key it
  /// sent), on a connection with neither SSH nor TLS (security audit M9).
  case insecureLogin(String)

  public var errorDescription: String? {
    switch self {
    case .truncated: "The server sent an incomplete message."
    case .connectionFailed(let detail): "Couldn't connect: \(detail)"
    case .timedOut(let what): "Timed out \(what)."
    case .closed: "The server closed the connection."
    case .protocolViolation(let detail): "Unexpected reply from the server: \(detail)"
    case .authenticationFailed(let detail): "Sign-in failed: \(detail)"
    case .unsupported(let detail): "Not supported: \(detail)"
    case .insecureLogin(let detail):
      "The server asked for the password \(detail), which anyone on the network could read. Database didn't send it: turn on SSH or encryption, or Allow Insecure Login in the connection's settings."
    }
  }
}
