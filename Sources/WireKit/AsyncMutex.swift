import Foundation

/// Keeps one request/response exchange on a connection from interleaving with another.
///
/// Wire clients are actors, but an actor runs other calls while one awaits the network,
/// so two callers could otherwise read each other's replies.
public actor AsyncMutex {
  private var locked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init() {}

  public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
    while locked { await withCheckedContinuation { waiters.append($0) } }
    locked = true
    defer {
      locked = false
      if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
    return try await body()
  }
}
