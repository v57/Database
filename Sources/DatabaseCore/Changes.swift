import BSON
import Foundation

/// A change to one field of one item.
public struct FieldChange: Hashable, Sendable, Identifiable {
  public var id: String { field }
  public var field: String
  public var old: CellValue
  public var new: CellValue
  public init(field: String, old: CellValue, new: CellValue) {
    self.field = field
    self.old = old
    self.new = new
  }
}

/// A pending change, shown in the review sheet before anything is written.
public struct RecordEdit: Hashable, Sendable, Identifiable {
  public enum Kind: Hashable, Sendable {
    case update([FieldChange])
    case insert([String: CellValue])
    case delete(Record)
  }

  public var id = UUID()
  public var ref: ObjectRef
  public var key: RecordKey?
  public var kind: Kind
  /// "Order 10476 · Elena Petrova".
  public var title: String

  public init(ref: ObjectRef, key: RecordKey?, kind: Kind, title: String) {
    self.ref = ref
    self.key = key
    self.kind = kind
    self.title = title
  }

  public var verb: String {
    switch kind {
    case .update: "EDIT"
    case .insert: "ADD"
    case .delete: "DELETE"
    }
  }
}

/// What applying a set of edits did, and how to take it back.
public struct ApplyOutcome: Sendable {
  public var changedItems: Int
  /// Edits that reverse this one, newest last; empty when undo isn't possible.
  public var undo: [RecordEdit]
  public var statements: [String]
}

/// Raised before writing to a read-only connection.
public struct ReadOnlyError: Error, LocalizedError {
  public init() {}
  public var errorDescription: String? {
    "This connection is read only. Turn off Read Only in the connection's settings to make changes."
  }
}

/// Raised when a value typed into an editor doesn't fit the field.
public struct InputError: Error, LocalizedError, Equatable {
  public var message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
