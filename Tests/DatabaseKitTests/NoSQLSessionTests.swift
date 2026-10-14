import BSON
import Foundation
import SSHTunnel
import Testing
import WireKit

@testable import DatabaseKit

/// MongoDB, Redis, Cassandra and ScyllaDB sessions against the docker-compose.yml services.
@Suite(.serialized) struct NoSQLSessionTests {
  // MARK: MongoDB

  static func mongo() async throws -> MongoSession {
    let (session, _) = try await Connector.connect(
      ConnectionProfile(engine: .mongodb, port: 27017, user: ""), credentials: Credentials())
    return try #require(session as? MongoSession)
  }

  @Test func mongoBrowsesEditsAndAggregates() async throws {
    let session = try await Self.mongo()
    defer { Task { await session.close() } }
    _ = try await session.run(
      """
      use dbpro_test
      db.products.drop()
      db.products.insertMany([
        { _id: 1, name: "Aurora Headphones", category: "Audio", price: 249.0, stock: 38, tags: ["wireless"] },
        { _id: 2, name: "Lumen Speaker", category: "Audio", price: 129.0, stock: 12, specs: { watts: 20 } },
        { _id: 3, name: "Desk Lamp", category: "Home", price: 59.0, stock: 0 }
      ])
      """, context: QueryContext(database: "dbpro_test"))
    let ref = ObjectRef(database: "dbpro_test", name: "products", kind: .collection)

    let databases = try await session.children(of: nil)
    let db = try #require(databases.first { $0.title == "dbpro_test" })
    let collections = try await session.children(of: db)
    #expect(collections.contains { $0.ref == ref })

    let fields = try await session.fields(of: ref)
    #expect(fields.first?.name == "_id")
    #expect(fields.first { $0.name == "price" }?.typeName == "Double")
    #expect(fields.first { $0.name == "specs" }?.presence.map { $0 < 0.5 } == true)

    var request = BrowseRequest(ref: ref)
    request.filters = [Filter(field: "category", op: .equals, value: "Audio"), Filter(field: "stock", op: .greater, value: "0")]
    request.sort = [SortKey(field: "price", ascending: true)]
    var page = try await session.browse(request)
    #expect(page.records.map { $0["name"]?.displayText } == ["Lumen Speaker", "Aurora Headphones"])
    #expect(page.query.contains("db.products.find("))
    #expect(try await session.count(request) == 2)
    request.filters = []
    request.search = "lamp"
    #expect(try await session.browse(request).records.count == 1)

    // Edit a field, remove another, then undo.
    var one = BrowseRequest(ref: ref)
    one.filters = [Filter(field: "_id", op: .equals, value: "2")]
    let speaker = try #require(try await session.browse(one).records.first)
    let price = try session.parseInput("99.5", isNull: false, for: FieldInfo(name: "price", typeName: "Double"))
    let edit = RecordEdit(
      ref: ref, key: speaker.key,
      kind: .update([
        FieldChange(field: "price", old: speaker["price"]!, new: price),
        FieldChange(field: "specs", old: speaker["specs"]!, new: .unset),
      ]), title: "Lumen Speaker")
    #expect(try session.statements(for: [edit]).first?.contains("$unset") == true)
    let outcome = try await session.apply([edit])
    page = try await session.browse(one)
    #expect(page.records.first?["price"] == .bson(.double(99.5)))
    #expect(page.records.first?["specs"] == nil)
    _ = try await session.apply(outcome.undo)
    page = try await session.browse(one)
    #expect(page.records.first?["price"] == .bson(.double(129)))
    #expect(page.records.first?["specs"] == .bson(.document(["watts": .int32(20)])))

    // Delete and bring back.
    let deleted = try await session.apply([RecordEdit(ref: ref, key: speaker.key, kind: .delete(speaker), title: "x")])
    #expect(try await session.count(BrowseRequest(ref: ref)) == 2)
    _ = try await session.apply(deleted.undo)
    #expect(try await session.count(BrowseRequest(ref: ref)) == 3)

    // Pipeline preview stage by stage.
    let stages: [BSONDocument] = [
      ["$match": .document(["stock": .document(["$gt": .int32(0)])])],
      ["$group": .document(["_id": .string("$category"), "n": .document(["$sum": .int32(1)])])],
    ]
    let first = try await session.aggregate(ref, stages: Array(stages.prefix(1)))
    #expect(first.count == 2)
    let both = try await session.aggregate(ref, stages: stages)
    #expect(both.documents.first?["n"] == .int32(2))

    // The shell runner.
    let runs = try await session.run(
      "db.products.find({ price: { $gte: 100 } }).sort({ price: -1 }).limit(1)", context: QueryContext(database: "dbpro_test"))
    guard case .documents(let docs, _)? = runs.first?.outputs.first else {
      Issue.record("expected documents")
      return
    }
    #expect(docs.first?["_id"] == .int32(1))
    let plan = try await session.explain("db.products.find({ category: 'Audio' })", context: QueryContext(database: "dbpro_test"))
    #expect(plan.contains("COLLSCAN"))
    await #expect(throws: (any Error).self) {
      try await session.run("db.products.frobnicate()", context: QueryContext(database: "dbpro_test"))
    }
  }

  @Test func mongoShellParsesChainsAndStatements() throws {
    let statements = try MongoShell.parse(
      """
      // comment
      show collections
      use shop; db.getCollection("a-b").find({ x: 1 }, { y: 1 })
        .sort({ y: -1 })
        .limit(5)
      db.runCommand({ ping: 1 })
      """)
    #expect(statements.count == 4)
    guard case .call(let call) = statements[2] else {
      Issue.record("expected a call")
      return
    }
    #expect(call.target == .collection("a-b"))
    #expect(call.method == "find")
    #expect(call.chain.map(\.name) == ["sort", "limit"])
    #expect(call.chain[1].arguments.first == .int32(5))
  }

  // MARK: Redis

  @Test func redisBrowsesTypesMutatesAndUndoes() async throws {
    let (anySession, _) = try await Connector.connect(
      ConnectionProfile(engine: .redis, port: 6379, user: "", database: "7"), credentials: Credentials())
    let session = try #require(anySession as? RedisSession)
    defer { Task { await session.close() } }
    _ = try await session.run(
      """
      FLUSHDB
      HSET session:1 user maya cart 3
      HSET session:2 user liam
      ZADD leaderboard:weekly 9840 noor 9512 tomasz
      SET stats:visits 48213
      RPUSH queue a b c
      """, context: QueryContext(database: "7"))
    let ref = ObjectRef(database: "7", name: "Database 7", kind: .redisDatabase)
    #expect(try await session.children(of: nil).contains { $0.ref == ref && $0.detail == "5 keys" })

    var request = BrowseRequest(ref: ref)
    var page = try await session.browse(request)
    #expect(page.records.map { $0["key"]?.displayText } == ["leaderboard:weekly", "queue", "session:1", "session:2", "stats:visits"])
    #expect(page.records.first?["type"]?.displayText == "ZSET")
    request.search = "session"
    #expect(try await session.browse(request).records.count == 2)
    request.search = ""
    request.keyType = "Sorted Set"
    #expect(try await session.browse(request).records.count == 1)

    let groups = RedisKeyTree.group(page.records.compactMap { $0["key"]?.displayText })
    #expect(groups.groups.map(\.prefix) == ["session:"])
    #expect(groups.loose == ["leaderboard:weekly", "queue", "stats:visits"])

    let (zset, total) = try await session.value(of: "leaderboard:weekly", in: ref)
    #expect(total == 2)
    #expect(zset == .zset([(member: "noor", score: 9840), (member: "tomasz", score: 9512)]))

    let undo = try await session.mutate(.hashSet(key: "session:1", field: "cart", value: "4"), in: ref)
    let removal = try await session.mutate(.listRemove(key: "queue", index: 1), in: ref)
    #expect(try await session.value(of: "queue", in: ref).0 == .list(["a", "c"]))
    let expiry = try await session.mutate(.expire(key: "stats:visits", seconds: 60), in: ref)
    #expect(try await session.ttl(of: "stats:visits", in: ref) > 0)
    try await session.undo(expiry, in: ref)
    #expect(try await session.ttl(of: "stats:visits", in: ref) == -1)
    try await session.undo(removal, in: ref)
    #expect(try await session.value(of: "queue", in: ref).0 == .list(["a", "b", "c"]))
    try await session.undo(undo, in: ref)
    if case .hash(let fields) = try await session.value(of: "session:1", in: ref).0 {
      #expect(fields.first { $0.field == "cart" }?.value == "3")
    } else {
      Issue.record("expected a hash")
    }
    let renamed = try await session.mutate(.rename(key: "queue", to: "jobs"), in: ref)
    try await session.undo(renamed, in: ref)
    #expect(try await session.value(of: "queue", in: ref).0 == .list(["a", "b", "c"]))
    #expect(try await session.value(of: "jobs", in: ref).0 == .none)

    try await session.create(key: "profile:1", type: "json", first: [#"{"name": "Ann"}"#], in: ref)
    if case .json(let text) = try await session.value(of: "profile:1", in: ref).0 {
      #expect(text.contains("Ann"))
    } else {
      Issue.record("expected JSON")
    }
    #expect(try RedisSession.arguments(#"SET "a b" 'c d' "e\"f""#) == ["SET", "a b", "c d", #"e"f"#])
    _ = try await session.run("FLUSHDB", context: QueryContext(database: "7"))
  }

  // MARK: Cassandra / ScyllaDB

  @Test(arguments: [EngineKind.cassandra, .scylla]) func cqlBrowsesAndEdits(engine: EngineKind) async throws {
    let profile = ConnectionProfile(
      engine: engine, port: engine == .cassandra ? 9042 : 9043, user: engine == .cassandra ? "cassandra" : "")
    let (session, report) = try await Connector.connect(
      profile, credentials: Credentials(password: engine == .cassandra ? "cassandra" : nil))
    #expect(report.serverDescription.hasPrefix(engine == .cassandra ? "Cassandra" : "ScyllaDB"))
    defer { Task { await session.close() } }
    let cql = try #require(session as? CQLSession)
    for statement in [
      "CREATE KEYSPACE IF NOT EXISTS dbpro_test WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}",
      "DROP TABLE IF EXISTS dbpro_test.readings",
      "CREATE TABLE dbpro_test.readings (sensor text, at timestamp, value double, tags set<text>, PRIMARY KEY (sensor, at)) WITH CLUSTERING ORDER BY (at DESC)",
      "INSERT INTO dbpro_test.readings (sensor, at, value, tags) VALUES ('s1', '2026-10-12 10:00:00+0000', 21.5, {'a'})",
      "INSERT INTO dbpro_test.readings (sensor, at, value) VALUES ('s1', '2026-10-12 11:00:00+0000', 22.0)",
      "INSERT INTO dbpro_test.readings (sensor, at, value) VALUES ('s2', '2026-10-12 10:00:00+0000', 19.0)",
    ] {
      _ = try await session.run(statement, context: QueryContext())
    }
    let ref = ObjectRef(database: "dbpro_test", name: "readings", kind: .table)
    let keyspaces = try await session.children(of: nil)
    let ks = try #require(keyspaces.first { $0.title == "dbpro_test" })
    #expect(try await session.children(of: ks).contains { $0.ref == ref })

    let fields = try await session.fields(of: ref)
    #expect(fields.map(\.name) == ["sensor", "at", "tags", "value"])
    #expect(fields[0].keyRole == .partition && fields[1].keyRole == .clustering)

    var request = BrowseRequest(ref: ref)
    request.filters = [Filter(field: "sensor", op: .equals, value: "s1")]
    #expect(try await cql.requiresFullScan(request) == false)
    var page = try await session.browse(request)
    #expect(page.records.count == 2)
    #expect(page.records.first?["at"]?.displayText == "2026-10-12 11:00:00.000Z")
    request.filters = [Filter(field: "value", op: .greater, value: "20")]
    #expect(try await cql.requiresFullScan(request))
    page = try await session.browse(request)
    #expect(page.records.count == 2)
    #expect(page.query.hasSuffix("ALLOW FILTERING"))
    request.filters = [Filter(field: "sensor", op: .contains, value: "s")]
    await #expect(throws: InputError.self) { try await session.browse(request) }

    var one = BrowseRequest(ref: ref)
    one.filters = [Filter(field: "sensor", op: .equals, value: "s2")]
    let row = try #require(try await session.browse(one).records.first)
    let valueField = try #require(fields.first { $0.name == "value" })
    let edit = RecordEdit(
      ref: ref, key: row.key,
      kind: .update([FieldChange(field: "value", old: row["value"]!, new: try session.parseInput("18.5", isNull: false, for: valueField))]),
      title: "s2")
    let outcome = try await session.apply([edit])
    #expect(try await session.browse(one).records.first?["value"] == .db(.double(18.5)))
    _ = try await session.apply(outcome.undo)
    #expect(try await session.browse(one).records.first?["value"] == .db(.double(19)))
    let delete = try await session.apply([RecordEdit(ref: ref, key: row.key, kind: .delete(row), title: "s2")])
    #expect(try await session.browse(one).records.isEmpty)
    _ = try await session.apply(delete.undo)
    #expect(try await session.browse(one).records.count == 1)
    _ = try await session.run("DROP KEYSPACE dbpro_test", context: QueryContext())
  }

  // MARK: Links and SSH

  @Test func readsConnectionLinks() throws {
    let pg = try #require(ConnectionLink.parse("postgres://app:s%40cret@db.shop.internal:5433/shop?sslmode=require"))
    #expect(pg.profile.engine == .postgres)
    #expect(pg.profile.host == "db.shop.internal")
    #expect(pg.profile.port == 5433)
    #expect(pg.profile.user == "app")
    #expect(pg.password == "s@cret")
    #expect(pg.profile.database == "shop")
    #expect(pg.profile.useTLS)
    let mongo = try #require(ConnectionLink.parse("mongodb://u:p@h1:27017,h2:27018/catalog?authSource=admin&replicaSet=rs"))
    #expect(mongo.profile.engine == .mongodb && mongo.profile.host == "h1" && mongo.profile.options["authSource"] == "admin")
    let redis = try #require(ConnectionLink.parse("rediss://:pw@cache:6380/2"))
    #expect(redis.profile.engine == .redis && redis.profile.database == "2" && redis.profile.useTLS && redis.password == "pw")
    let mssql = try #require(ConnectionLink.parse("Server=tcp:erp.corp,1444;Database=Legacy;User Id=sa;Password=x;"))
    #expect(mssql.profile.engine == .sqlserver && mssql.profile.port == 1444 && mssql.profile.database == "Legacy")
    #expect(ConnectionLink.parse("/tmp/sales.parquet")?.profile.engine == .duckdb)
    #expect(ConnectionLink.parse("~/notes.sqlite")?.profile.engine == .sqlite)
    #expect(ConnectionLink.parse("jdbc:mysql://localhost/shop")?.profile.engine == .mysql)
    #expect(ConnectionLink.parse("cassandra://cassandra@node1:9042?keyspace=telemetry")?.profile.database == "telemetry")
    #expect(ConnectionLink.parse("hello") == nil)
    let roundTrip = ConnectionLink.url(for: pg.profile)
    #expect(ConnectionLink.parse(roundTrip)?.profile.host == "db.shop.internal")
  }

  @Test(arguments: [EngineKind.postgres, .mysql, .sqlserver, .mongodb, .redis, .cassandra])
  func connectsThroughTheSSHBastion(engine: EngineKind) async throws {
    let keyURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".testing/ssh/id_ed25519")
    let key = try SSHKey(importing: String(contentsOf: keyURL, encoding: .utf8))
    let host = engine == .sqlserver ? "sqlserver" : engine == .mongodb ? "mongodb" : engine.rawValue
    var profile = ConnectionProfile(engine: engine, host: host, port: engine.defaultPort)
    profile.ssh = SSHSettings(enabled: true, host: "127.0.0.1", port: 2222, user: "tunnel", auth: .key, keyID: UUID())
    let passwords: [EngineKind: String] = [
      .postgres: "postgres", .mysql: "databasepro", .sqlserver: "DatabasePro#2026", .cassandra: "cassandra",
    ]
    if engine == .mongodb || engine == .redis { profile.user = "" }
    let (session, report) = try await Connector.connect(
      profile, credentials: Credentials(password: passwords[engine], sshKey: key))
    #expect(report.sshHostKeyFingerprint?.hasPrefix("SHA256:") == true)
    #expect(!report.serverDescription.isEmpty)
    _ = try await session.children(of: nil)
    await session.close()

    // A remembered, different host key is refused.
    profile.ssh.hostKeyFingerprint = "SHA256:someone-else"
    await #expect(throws: SSHTunnelError.self) {
      try await Connector.connect(profile, credentials: Credentials(password: passwords[engine], sshKey: key))
    }
  }
}
