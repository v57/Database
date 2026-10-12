import Foundation

/// A value guarded by a lock, usable from async code.
final class Locked<Value>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()

  init(_ value: Value) { self.value = value }

  func get<T>(_ body: (Value) -> T) -> T { lock.withLock { body(value) } }
  func set<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
