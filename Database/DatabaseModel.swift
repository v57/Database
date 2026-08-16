import Foundation
import Observation
import MongoDB

/// Observable app state: the active session and the three-column navigation state.
@Observable
@MainActor
final class DatabaseModel {
    var session: MongoConnection?
    var isConnecting = false
    var statusMessage = ""

    var databases: [String] = []
    var selectedDatabase: String?

    var collections: [String] = []
    var collectionSearch = ""
    var selectedCollection: String?

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
            selectedCollection = nil
            documents = []
            selectedDocument = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Reloads collections for the current database, applying `collectionSearch`.
    func refreshCollections() async {
        guard let session else { return }
        do {
            collections = try await session.listCollections(matching: collectionSearch)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Selects a collection and runs the default find (limit 100).
    func select(collection: String) async {
        guard let session else { return }
        do {
            selectedCollection = collection
            documents = try await session.find(in: collection, limit: 100)
            statusMessage = "\(documents.count) document(s) in \(collection)"
        } catch {
            statusMessage = error.localizedDescription
        }
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
