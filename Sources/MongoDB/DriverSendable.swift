import MongoSwift

// Swift 6 region isolation (ApproachableConcurrency) requires Sending values
// into the driver's @concurrent async methods. MongoSwift 1.3.1 predates
// Sendable annotations. These retroactive @unchecked conformances are sound:
//   - MongoClient is documented thread-safe by the driver (pooled connections,
//     operations serialized on its event loop); MongoDatabase/MongoCollection/
//     MongoCursor are thin handles over the client.
//   - BSONDocument is an immutable value type.
// Access is additionally serialized per connection (single-thread ELG).

extension MongoClient: @retroactive @unchecked Sendable {}
extension MongoDatabase: @retroactive @unchecked Sendable {}
extension MongoCollection: @retroactive @unchecked Sendable {}
extension MongoCursor: @retroactive @unchecked Sendable {}
extension BSONDocument: @retroactive @unchecked Sendable {}