import Foundation
import Testing
import WireKit

@testable import DatabaseKit

/// Runs the same browse/edit/undo scenario on every SQL engine.
/// Needs the docker-compose.yml services (postgres, mysql, mariadb, sqlserver); SQLite and DuckDB use temp files.
@Suite(.serialized) struct SQLSessionTests {
  struct Setup: Sendable {
    var session: DatabaseSession
    var orders: ObjectRef
    var customers: ObjectRef
  }

  static func profile(_ engine: EngineKind) -> (ConnectionProfile, String) {
    switch engine {
    case .postgres: (ConnectionProfile(engine: .postgres, port: 5432, user: "postgres", database: "postgres"), "postgres")
    case .mysql: (ConnectionProfile(engine: .mysql, port: 3306, user: "root"), "databasepro")
    case .mariadb: (ConnectionProfile(engine: .mariadb, port: 3307, user: "root"), "databasepro")
    case .sqlserver: (ConnectionProfile(engine: .sqlserver, port: 1433, user: "sa"), "DatabasePro#2026")
    case .sqlite:
      (ConnectionProfile(engine: .sqlite, filePath: Self.tempFile("shop.sqlite")), "")
    case .duckdb:
      (ConnectionProfile(engine: .duckdb, filePath: Self.tempFile("shop.duckdb")), "")
    default: fatalError()
    }
  }

  static func tempFile(_ name: String) -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbpro-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(name).path
    if name.hasSuffix(".sqlite") { FileManager.default.createFile(atPath: path, contents: nil) }
    return path
  }

  static func setUp(_ engine: EngineKind) async throws -> Setup {
    let (profile, password) = profile(engine)
    let (session, report) = try await Connector.connect(profile, credentials: Credentials(password: password))
    #expect(!report.serverDescription.isEmpty)
    let decimal = engine == .sqlite ? "REAL" : "DECIMAL(10,2)"
    let text = engine == .sqlserver ? "NVARCHAR(100)" : "VARCHAR(100)"
    let tables = [
      "CREATE TABLE customers (id INTEGER PRIMARY KEY, name \(text) NOT NULL)",
      "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, status \(text), total \(decimal), created DATE, FOREIGN KEY (customer_id) REFERENCES customers(id))",
      "INSERT INTO customers (id, name) VALUES (1, 'Maya Okafor'), (2, 'Liam Chen')",
      """
      INSERT INTO orders (id, customer_id, status, total, created) VALUES
      (10, 1, 'shipped', 184.20, '2026-10-12'), (11, 2, 'pending', 42.00, '2026-10-11'),
      (12, 1, 'shipped', 312.75, '2026-10-10'), (13, 2, 'cancelled', 58.00, '2026-10-09')
      """,
    ]
    var orders = ObjectRef(name: "orders")
    var customers = ObjectRef(name: "customers")
    switch engine {
    case .postgres:
      _ = try await session.run("DROP SCHEMA IF EXISTS dbpro_test CASCADE; CREATE SCHEMA dbpro_test", context: QueryContext())
      for sql in tables { _ = try await session.run("SET search_path TO dbpro_test; " + sql, context: QueryContext()) }
      orders = ObjectRef(database: "postgres", schema: "dbpro_test", name: "orders")
      customers = ObjectRef(database: "postgres", schema: "dbpro_test", name: "customers")
    case .mysql, .mariadb:
      _ = try await session.run("DROP DATABASE IF EXISTS dbpro_test; CREATE DATABASE dbpro_test", context: QueryContext())
      for sql in tables { _ = try await session.run(sql, context: QueryContext(database: "dbpro_test")) }
      orders = ObjectRef(database: "dbpro_test", name: "orders")
      customers = ObjectRef(database: "dbpro_test", name: "customers")
    case .sqlserver:
      _ = try await session.run(
        "IF DB_ID('dbpro_test') IS NOT NULL BEGIN ALTER DATABASE dbpro_test SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE dbpro_test; END",
        context: QueryContext(database: "master"))
      _ = try await session.run("CREATE DATABASE dbpro_test", context: QueryContext(database: "master"))
      for sql in tables { _ = try await session.run(sql, context: QueryContext(database: "dbpro_test")) }
      orders = ObjectRef(database: "dbpro_test", schema: "dbo", name: "orders")
      customers = ObjectRef(database: "dbpro_test", schema: "dbo", name: "customers")
    case .duckdb:
      for sql in tables { _ = try await session.run(sql, context: QueryContext()) }
      orders = ObjectRef(database: "shop", schema: "main", name: "orders")
      customers = ObjectRef(database: "shop", schema: "main", name: "customers")
    default:
      for sql in tables { _ = try await session.run(sql, context: QueryContext()) }
    }
    return Setup(session: session, orders: orders, customers: customers)
  }

  static let engines: [EngineKind] = [.postgres, .mysql, .mariadb, .sqlserver, .sqlite, .duckdb]

  @Test(arguments: engines) func treeFieldsAndRelations(engine: EngineKind) async throws {
    let setup = try await Self.setUp(engine)
    defer { Task { await setup.session.close() } }
    let session = setup.session

    // Walk the tree down to the orders table.
    var level = try await session.children(of: nil)
    var found: TreeNode?
    for _ in 0..<4 {
      if let table = level.first(where: { $0.ref?.name == "orders" }) {
        found = table
        break
      }
      guard let next = level.first(where: { ["dbpro_test", "postgres", "shop"].contains($0.title) && $0.hasChildren })
      else { break }
      level = try await session.children(of: next)
      if let schema = level.first(where: { $0.title == "dbpro_test" && $0.kind == .schema }) {
        level = try await session.children(of: schema)
      }
    }
    let table = try #require(found, "orders not found in the tree")
    #expect(table.ref == setup.orders)

    let fields = try await session.fields(of: setup.orders)
    #expect(fields.map(\.name) == ["id", "customer_id", "status", "total", "created"])
    #expect(fields.first?.isPrimaryKey == true)
    #expect(fields[3].category == (engine == .sqlite ? .float : .decimal))
    #expect(fields[4].category == .date)
    if engine != .duckdb {
      #expect(fields[1].references?.target.name == "customers")
      let relations = try await session.relations(of: setup.customers)
      #expect(relations.contains { $0.direction == .incoming && $0.table.name == "orders" && $0.otherColumn == "customer_id" })
    }
  }

  @Test(arguments: engines) func browsesFiltersSortsAndPages(engine: EngineKind) async throws {
    let setup = try await Self.setUp(engine)
    defer { Task { await setup.session.close() } }
    let session = setup.session

    var request = BrowseRequest(ref: setup.orders, limit: 3)
    var page = try await session.browse(request)
    #expect(page.records.count == 3)
    #expect(page.hasMore)
    #expect(page.records.first?.key?.parts.first?.field == "id")
    request.offset = 3
    page = try await session.browse(request)
    #expect(page.records.count == 1)
    #expect(!page.hasMore)

    request = BrowseRequest(ref: setup.orders)
    request.filters = [Filter(field: "status", op: .equals, value: "shipped")]
    request.sort = [SortKey(field: "total", ascending: false)]
    page = try await session.browse(request)
    #expect(page.records.compactMap { $0["id"]?.dbValue?.intValue } == [12, 10])
    #expect(try await session.count(request) == 2)
    #expect(page.query.contains("ORDER BY"))

    request.filters = [Filter(field: "total", op: .greaterOrEqual, value: "100")]
    request.sort = []
    #expect(try await session.count(request) == 2)
    request.filters = [Filter(field: "status", op: .contains, value: "PEND")]
    #expect(try await session.count(request) == 1)
    request.filters = [Filter(field: "created", op: .less, value: "2026-10-11")]
    #expect(try await session.count(request) == 2)

    var search = BrowseRequest(ref: setup.customers)
    search.search = "okaf"
    page = try await session.browse(search)
    #expect(page.records.map { $0["name"]?.displayText } == ["Maya Okafor"])

    var narrow = BrowseRequest(ref: setup.orders)
    narrow.hiddenFields = ["created", "total"]
    page = try await session.browse(narrow)
    #expect(page.records.first?["total"] == nil)
    #expect(page.records.first?["id"] != nil)
  }

  @Test(arguments: engines) func editsInATransactionAndUndoes(engine: EngineKind) async throws {
    let setup = try await Self.setUp(engine)
    defer { Task { await setup.session.close() } }
    let session = setup.session
    let fields = try await session.fields(of: setup.orders)
    let statusField = try #require(fields.first { $0.name == "status" })
    let totalField = try #require(fields.first { $0.name == "total" })

    var request = BrowseRequest(ref: setup.orders)
    request.filters = [Filter(field: "id", op: .equals, value: "11")]
    let original = try #require(try await session.browse(request).records.first)

    let newStatus = try session.parseInput("shipped", isNull: false, for: statusField)
    let newTotal = try session.parseInput("38.00", isNull: false, for: totalField)
    #expect(throws: InputError.self) { try session.parseInput("abc", isNull: false, for: totalField) }
    let update = RecordEdit(
      ref: setup.orders, key: original.key,
      kind: .update([
        FieldChange(field: "status", old: original["status"]!, new: newStatus),
        FieldChange(field: "total", old: original["total"]!, new: newTotal),
      ]), title: "Order 11")
    let deleteTarget = try #require(
      try await session.browse({
        var r = BrowseRequest(ref: setup.orders)
        r.filters = [Filter(field: "id", op: .equals, value: "13")]
        return r
      }()).records.first)
    let delete = RecordEdit(ref: setup.orders, key: deleteTarget.key, kind: .delete(deleteTarget), title: "Order 13")
    let insert = RecordEdit(
      ref: setup.orders, key: nil,
      kind: .insert([
        "id": .db(.int(14)), "customer_id": .db(.int(1)), "status": .db(.text("pending")), "total": .db(.decimal("9.50")),
      ]), title: "New order")

    let statements = try session.statements(for: [update, delete, insert])
    #expect(statements.count == 3)
    #expect(statements[0].hasPrefix("UPDATE"))

    let outcome = try await session.apply([update, delete, insert])
    #expect(outcome.changedItems == 3)
    #expect(try await session.count(BrowseRequest(ref: setup.orders)) == 4)
    var changed = BrowseRequest(ref: setup.orders)
    changed.filters = [Filter(field: "status", op: .equals, value: "shipped")]
    #expect(try await session.count(changed) == 3)

    // Undo puts everything back.
    _ = try await session.apply(outcome.undo)
    #expect(try await session.count(changed) == 2)
    let restored = try #require(try await session.browse(request).records.first)
    #expect(restored["status"] == original["status"])
    var thirteen = BrowseRequest(ref: setup.orders)
    thirteen.filters = [Filter(field: "id", op: .equals, value: "13")]
    #expect(try await session.count(thirteen) == 1)
    var fourteen = BrowseRequest(ref: setup.orders)
    fourteen.filters = [Filter(field: "id", op: .equals, value: "14")]
    #expect(try await session.count(fourteen) == 0)

    // A failing edit rolls back the ones before it.
    let good = RecordEdit(
      ref: setup.orders, key: original.key,
      kind: .update([FieldChange(field: "status", old: original["status"]!, new: .db(.text("refunded")))]), title: "ok")
    let bad = RecordEdit(
      ref: setup.orders, key: nil, kind: .insert(["id": .db(.int(10)), "status": .db(.text("duplicate key"))]),
      title: "dup")
    await #expect(throws: (any Error).self) { try await session.apply([good, bad]) }
    let after = try #require(try await session.browse(request).records.first)
    #expect(after["status"] == original["status"])
  }

  @Test(arguments: engines) func runsQueriesAndExplains(engine: EngineKind) async throws {
    let setup = try await Self.setUp(engine)
    defer { Task { await setup.session.close() } }
    let session = setup.session
    let context = QueryContext(database: setup.orders.database, schema: setup.orders.schema)
    let table = engine == .postgres ? "dbpro_test.orders" : "orders"
    let runs = try await session.run("SELECT status, COUNT(*) AS n FROM \(table) GROUP BY status ORDER BY status", context: context)
    guard case .table(let fields, let rows, _)? = runs.last?.outputs.first else {
      Issue.record("expected a table")
      return
    }
    #expect(fields.map { $0.name.lowercased() } == ["status", "n"])
    #expect(rows.count == 3)
    let plan = try await session.explain("SELECT * FROM \(table) WHERE id = 10", context: context)
    #expect(!plan.isEmpty)
    let completions = await session.completions(context: context)
    #expect(completions.contains { $0.text == "orders" && $0.kind == .table })
  }
}
