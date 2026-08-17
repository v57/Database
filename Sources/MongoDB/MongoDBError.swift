import Foundation

public enum MongoDBError: Error, LocalizedError, Sendable {
    case invalidConfig(String)
    case invalidQuery(String)
    case notConnected
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfig(let m): return "Invalid configuration: \(m)"
        case .invalidQuery(let m): return "Invalid query: \(m)"
        case .notConnected: return "Not connected to MongoDB."
        case .server(let m): return "MongoDB error: \(m)"
        }
    }
}
