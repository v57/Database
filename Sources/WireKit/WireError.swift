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
  /// The server asked for the password in a form someone on the network could read or crack (cleartext, MD5, a key
  /// it sent), on a connection with neither SSH nor TLS (security audit M9). The detail is one of `cleartextPassword`,
  /// `md5Password`, `serverKeyPassword`.
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
      "The server asked for the password \(detail). Database didn't send it: turn on SSH or encryption, or Allow Insecure Login in the connection's settings."
    }
  }
}

extension WireError {
  /// How a server asked for the password, for `insecureLogin`: the rest of "The server asked for the password …",
  /// with what it risks.
  public static let cleartextPassword = "in cleartext, which anyone on the network could read"
  public static let md5Password = "as an MD5 hash, which anyone on the network could capture and crack"
  /// MySQL's caching_sha2_password full authentication off TLS (D-007): not cleartext, but nothing vouches for the key.
  public static let serverKeyPassword =
    "in full, encrypted to a key the server sends. Nothing checks that key, so someone on the network could send their own and read the password"
}
