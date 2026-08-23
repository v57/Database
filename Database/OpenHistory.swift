import Foundation
import SwiftData

/// Last-opened/last-used timestamps for sidebar sorting. Keyed by
/// database/collection names (global across connections — a dev tool for a
/// local server).
@Model
final class DatabaseOpenRecord {
    var databaseName: String
    var lastOpened: Date

    init(databaseName: String, lastOpened: Date = .now) {
        self.databaseName = databaseName
        self.lastOpened = lastOpened
    }
}

@Model
final class CollectionOpenRecord {
    var databaseName: String
    var collectionName: String
    /// When a query was last executed against this collection. The
    /// original name (`lastOpened`) lets existing stores migrate.
    @Attribute(originalName: "lastOpened")
    var lastUsed: Date

    init(databaseName: String, collectionName: String, lastUsed: Date = .now) {
        self.databaseName = databaseName
        self.collectionName = collectionName
        self.lastUsed = lastUsed
    }
}
