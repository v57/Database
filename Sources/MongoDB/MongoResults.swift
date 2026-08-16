import Foundation

public struct MongoWriteResult: Sendable {
    public let matchedCount: Int
    public let modifiedCount: Int
    /// Extended-JSON string of the upserted id, when an upsert happened.
    public let upsertedId: String?

    public init(matchedCount: Int, modifiedCount: Int, upsertedId: String?) {
        self.matchedCount = matchedCount
        self.modifiedCount = modifiedCount
        self.upsertedId = upsertedId
    }
}

public struct MongoDeleteResult: Sendable {
    public let deletedCount: Int

    public init(deletedCount: Int) {
        self.deletedCount = deletedCount
    }
}
