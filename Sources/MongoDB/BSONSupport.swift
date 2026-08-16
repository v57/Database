import Foundation
import MongoSwift

/// swift-bson 3.x (pulled in by mongo-swift-driver 1.3.1) renamed `Document` to
/// `BSONDocument`. This typealias keeps the module's `Document` API stable for
/// tests, the UI layer, and the helpers below — visible wherever MongoDB is imported.
public typealias Document = BSONDocument

/// JSON <-> BSON Document helpers for the UI layer and tests.
public enum BSONSupport {
    /// Parse a JSON string into a BSON `Document` (filter / update inputs from text fields).
    public static func document(fromJSON json: String) throws -> Document {
        do {
            return try Document(fromJSON: json)
        } catch {
            throw MongoDBError.invalidConfig("Invalid JSON: \(error.localizedDescription)")
        }
    }

    /// Single-line extended JSON of a document, for display.
    public static func json(_ doc: Document) -> String {
        doc.description
    }
}
