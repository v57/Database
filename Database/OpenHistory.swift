import Foundation
import SwiftData

/// Last-opened timestamps for sidebar sorting. Keyed by database/collection
/// names (global across connections — a dev tool for a local server).
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
    var lastOpened: Date

    init(databaseName: String, collectionName: String, lastOpened: Date = .now) {
        self.databaseName = databaseName
        self.collectionName = collectionName
        self.lastOpened = lastOpened
    }
}
