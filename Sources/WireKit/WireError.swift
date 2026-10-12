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

  public var errorDescription: String? {
    switch self {
    case .truncated: "The server sent an incomplete message."
    case .connectionFailed(let detail): "Couldn't connect: \(detail)"
    case .timedOut(let what): "Timed out \(what)."
    case .closed: "The server closed the connection."
    case .protocolViolation(let detail): "Unexpected reply from the server: \(detail)"
    case .authenticationFailed(let detail): "Sign-in failed: \(detail)"
    case .unsupported(let detail): "Not supported: \(detail)"
    }
  }
}
