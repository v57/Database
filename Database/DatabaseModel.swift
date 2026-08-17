import Foundation
import Observation
import SwiftData
import MongoDB

/// Observable app state: the active session and the three-column navigation state.
@Observable
@MainActor
final class DatabaseModel {
    /// SwiftData context shared with the app container; persists last-opened
    /// history used for sidebar sorting.
    private let modelContext: ModelContext

    /// db name -> last opened date
    private var databaseLastOpened: [String: Date] = [:]
    /// db name -> (collection name -> last opened date)
    private var collectionLastOpened: [String: [String: Date]] = [:]

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        loadOpenHistory()
    }

    var session: MongoConnection?
    var isConnecting = false
    var statusMessage = ""

    var databases: [String] = []
    var selectedDatabase: String?

    var collections: [String] = []
    var collectionSearch = ""
    var selectedCollection: String?

    /// Per-database collection names, fetched lazily as databases are expanded
    /// in the sidebar; also drives sidebar search filtering.
    private(set) var collectionsByDatabase: [String: [String]] = [:]

    var documents: [Document] = []
    var selectedDocument: Document?

    /// Connects to the server, loads the database list, and selects the
    /// default database (config.defaultDatabase ?? first ?? "admin").
    func connect(_ config: ConnectionConfig) async {
        await disconnect()

        let conn = MongoConnection(config: config)
        isConnecting = true
        statusMessage = "Connecting to \(config.host):\(config.port)…"
        defer { isConnecting = false }

        do {
            try await conn.connect()
            session = conn
            statusMessage = "Connected to \(config.name)"
            databases = try await conn.listDatabases()
            let initial = config.defaultDatabase ?? databases.first ?? "admin"
            await select(database: initial)
        } catch {
            statusMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        if let session {
            await session.disconnect()
        }
        session = nil
        databases = []
        selectedDatabase = nil
        collections = []
        collectionsByDatabase = [:]
        selectedCollection = nil
        documents = []
        selectedDocument = nil
        statusMessage = ""
    }

    /// Switches the active database and reloads its collections.
    func select(database: String) async {
        guard let session else { return }
        do {
            try await session.use(database: database)
            selectedDatabase = database
            collectionSearch = ""
            collections = try await session.listCollections()
            collectionsByDatabase[database] = collections
            selectedCollection = nil
            documents = []
            selectedDocument = nil
            markDatabaseOpened(database)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Loads (once) and caches collections for a database; called when the
    /// sidebar expands a database row.
    func loadCollections(for database: String) async {
        guard let session, collectionsByDatabase[database] == nil else { return }
        do {
            try await session.use(database: database)
            let names = try await session.listCollections()
            collectionsByDatabase[database] = names
            if database == selectedDatabase {
                collections = names
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Loads collections for every database (cached), so the sidebar search
    /// can filter across all of them. No-op for already-loaded databases.
    func loadAllCollections() async {
        for db in databases {
            await loadCollections(for: db)
        }
    }

    /// Cached collections of `database`, filtered by the plain (non-$) search
    /// terms — every term must match (AND) — then sorted most-recently-opened
    /// first; never-opened last (alphabetical).
    func collections(for database: String) -> [String] {
        let names = collectionsByDatabase[database] ?? []
        let terms = searchTerms.collectionTerms
        let filtered = terms.isEmpty
            ? names
            : names.filter { name in
                terms.allSatisfy { name.localizedCaseInsensitiveContains($0) }
            }
        let opened = collectionLastOpened[database] ?? [:]
        return filtered.sorted(by: openedFirstComparator(opened))
    }

    /// Parsed view of the sidebar search field for the current state.
    var searchTerms: SearchTerms { SearchTerms(collectionSearch) }

    // MARK: - Last-opened history (SwiftData)

    private func loadOpenHistory() {
        var dbs: [String: Date] = [:]
        if let records = try? modelContext.fetch(FetchDescriptor<DatabaseOpenRecord>()) {
            for r in records { dbs[r.databaseName] = r.lastOpened }
        }
        databaseLastOpened = dbs

        var colls: [String: [String: Date]] = [:]
        if let records = try? modelContext.fetch(FetchDescriptor<CollectionOpenRecord>()) {
            for r in records { colls[r.databaseName, default: [:]][r.collectionName] = r.lastOpened }
        }
        collectionLastOpened = colls
    }

    private func markDatabaseOpened(_ database: String) {
        let now = Date.now
        databaseLastOpened[database] = now
        let record: DatabaseOpenRecord
        if let existing = try? modelContext.fetch(
            FetchDescriptor<DatabaseOpenRecord>(
                predicate: #Predicate { $0.databaseName == database }
            )
        ).first {
            record = existing
        } else {
            record = DatabaseOpenRecord(databaseName: database)
            modelContext.insert(record)
        }
        record.lastOpened = now
        try? modelContext.save()
    }

    private func markCollectionOpened(_ database: String, _ collection: String) {
        let now = Date.now
        collectionLastOpened[database, default: [:]][collection] = now
        let record: CollectionOpenRecord
        if let existing = try? modelContext.fetch(
            FetchDescriptor<CollectionOpenRecord>(
                predicate: #Predicate {
                    $0.databaseName == database && $0.collectionName == collection
                }
            )
        ).first {
            record = existing
        } else {
            record = CollectionOpenRecord(databaseName: database, collectionName: collection)
            modelContext.insert(record)
        }
        record.lastOpened = now
        try? modelContext.save()
    }

    /// Sort closure: most-recently-opened first, never-opened last (alphabetical).
    private func openedFirstComparator(_ opened: [String: Date]) -> (String, String) -> Bool {
        { a, b in
            switch (opened[a], opened[b]) {
            case let (x?, y?): return x > y
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil):
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        }
    }

    /// Databases sorted most-recently-opened first; never-opened last.
    var sortedDatabases: [String] {
        databases.sorted(by: openedFirstComparator(databaseLastOpened))
    }

    /// Selects a collection in an explicit database (sidebar path), switching
    /// the active database first when needed.
    func select(collection: String, in database: String) async {
        guard let session else { return }
        do {
            if selectedDatabase != database {
                try await session.use(database: database)
                selectedDatabase = database
                collections = collectionsByDatabase[database] ?? []
                if collections.isEmpty {
                    collections = try await session.listCollections()
                    collectionsByDatabase[database] = collections
                }
            }
            selectedCollection = collection
            documents = try await session.find(in: collection, limit: 100)
            statusMessage = "\(documents.count) document(s) in \(collection)"
            markDatabaseOpened(database)
            markCollectionOpened(database, collection)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Selects a collection in the current database (documents refresh path).
    func select(collection: String) async {
        await select(collection: collection, in: selectedDatabase ?? "")
    }

    /// Runs a find against the selected collection. `filter` is JSON text
    /// parsed with `BSONSupport`; `nil` matches everything.
    func runFind(filter: String?, limit: Int?) async throws -> [Document] {
        guard let session, let selectedCollection else { throw MongoDBError.notConnected }
        let docFilter = try filter.flatMap { try BSONSupport.document(fromJSON: $0) }
        let docs = try await session.find(in: selectedCollection, filter: docFilter, limit: limit)
        documents = docs
        return docs
    }

    /// Runs updateMany against the selected collection and refreshes the list.
    func runUpdate(filter: String, update: String) async throws -> MongoWriteResult {
        guard let session, let selectedCollection else { throw MongoDBError.notConnected }
        let f = try BSONSupport.document(fromJSON: filter)
        let u = try BSONSupport.document(fromJSON: update)
        let result = try await session.updateMany(in: selectedCollection, filter: f, update: u)
        statusMessage = "Updated \(result.matchedCount) matched, \(result.modifiedCount) modified"
        await refreshAfterMutation(session, selectedCollection)
        return result
    }

    /// Runs deleteMany against the selected collection and refreshes the list.
    func runDelete(filter: String) async throws -> MongoDeleteResult {
        guard let session, let selectedCollection else { throw MongoDBError.notConnected }
        let f = try BSONSupport.document(fromJSON: filter)
        let result = try await session.deleteMany(from: selectedCollection, filter: f)
        statusMessage = "Deleted \(result.deletedCount) document(s)"
        await refreshAfterMutation(session, selectedCollection)
        return result
    }

    /// Re-runs the current (default) find so the list reflects a mutation.
    private func refreshAfterMutation(_ session: MongoConnection, _ collection: String) async {
        if let docs = try? await session.find(in: collection, limit: 100) {
            documents = docs
        }
    }
}

/// Parsed sidebar search: tokens starting with `$` filter database names,
/// plain tokens filter collection names. Order-independent; all terms of a
/// kind must match (AND). Example: `$maindb users` == `users $maindb` shows
/// databases whose name contains "maindb" with collections containing "users".
struct SearchTerms {
    let databaseTerms: [String]
    let collectionTerms: [String]

    var isSearching: Bool { !databaseTerms.isEmpty || !collectionTerms.isEmpty }
    var hasDatabaseTerms: Bool { !databaseTerms.isEmpty }

    init(_ raw: String) {
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        databaseTerms = tokens
            .filter { $0.hasPrefix("$") }
            .map { String($0.dropFirst()) }
            .filter { !$0.isEmpty }
        collectionTerms = tokens.filter { !$0.hasPrefix("$") }
    }
}
