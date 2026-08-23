import Foundation

public enum RedisError: Error, LocalizedError, Sendable {
  case invalidConfig(String)
  case invalidQuery(String)
  case notConnected
  case server(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfig(let m): return "Invalid configuration: \(m)"
    case .invalidQuery(let m): return "Invalid query: \(m)"
    case .notConnected: return "Not connected to Redis."
    case .server(let m): return "Redis error: \(m)"
    }
  }
}
