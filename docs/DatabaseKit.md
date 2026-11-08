# DatabaseKit

DatabaseKit is the engine-neutral layer Database's app talks to. One `ConnectionProfile` describes a connection to
any of the ten engines (PostgreSQL, MySQL, MariaDB, SQL Server, SQLite, DuckDB, MongoDB, Redis, Cassandra, ScyllaDB);
`Connector` opens it, through an SSH server when the profile says so, and returns a `DatabaseSession`. The session
lists the tree of databases, schemas and tables, browses items with filters and sorting, turns edits into statements
for review and applies them with undo, and runs queries.

All engines are pure Swift on [WireKit](WireKit.md), except DuckDB, which is a library the user downloads (macOS
only). The engine clients themselves are internal targets, described in [Engines](Engines.md).

DatabaseKit has no interface and keeps no saved connections: [DatabaseUI](DatabaseUI.md) does both. It does not
store passwords either; you pass them in `Credentials` for each connection attempt.

DatabaseKit re-exports `WireKit`, `SSHTunnel` (and with it SSHKit), `BSON` and `DuckDBKit`, so one
`import DatabaseKit` brings the value types the sessions return.

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Database.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "DatabaseKit", package: "Database")]),
]
```

Connect, run a query and browse a table:

```swift
import DatabaseKit

let password = "secret"
let profile = ConnectionProfile(
  name: "Shop", engine: .postgres, host: "db.example.com", user: "app", database: "shop", useTLS: true)
let (session, report) = try await Connector.connect(profile, credentials: Credentials(password: password))
print(report.serverDescription)  // "PostgreSQL 18.0"

for run in try await session.run("SELECT id, name FROM customers LIMIT 5", context: QueryContext()) {
  for output in run.outputs {
    if case .table(let fields, let rows, _) = output {
      print(fields.map(\.name), rows.map { $0.map(\.displayText) })
    }
  }
}

let customers = ObjectRef(database: "shop", schema: "public", name: "customers")
var request = BrowseRequest(ref: customers, limit: 20)
request.filters = [Filter(field: "country", op: .equals, value: "NL")]
request.sort = [SortKey(field: "name")]
let page = try await session.browse(request)
print(page.records.count, page.query)

await session.close()
```

Through SSH, set the profile's `ssh` (`SSHSettings(enabled: true, host:, user:, auth:)`) and pass the SSH password or
key in `Credentials(sshPassword:sshKey:sshUnknownHost:)`. `Connector` then opens one [SSHTunnel](SSHTunnel.md) and
every connection the engine makes is a channel of it. An app that already has an SSH login passes its own
`dialer:` instead.

## Main API

### Connecting

- `EngineKind`: the ten engines, with `family` (`sql`, `document`, `keyValue`, `wideColumn`), `displayName`,
  `defaultPort`, `defaultUser`, `isFileBased`, `schemes`, `fileExtensions`, `supportsDirectTLS`,
  `supportsIndexes`, and `EngineKind.available` (the engines this device can open: not DuckDB on iOS).
- `ConnectionProfile`: a saved connection without its passwords: engine, host, port, user, database, file path,
  `options`, `useTLS`, `allowUntrustedCertificate`, `isReadOnly`, `isProduction`, `color`, `ssh` (`SSHSettings`).
  `problems` lists what is missing in plain words; `allowsInsecureLogin` (off by default) lets a login send a
  cleartext or MD5 password over a connection with neither SSH nor TLS.
- `ConnectionLink.parse(_:)` reads a pasted link (a URL, an ADO.NET string, a file path) into a profile and password;
  `ConnectionLink.url(for:)` writes a profile back as a link, without the password.
- `Credentials`: `password`, `sshPassword`, `sshKey`, and `sshUnknownHost` (what to do about an SSH host key that
  isn't known yet; `.refuseUnknown` by default).
- `Connector.connect(_:credentials:dialer:)` returns the session and a `ConnectionReport` (`serverDescription`,
  `elapsed`, the SSH host key it accepted).

### Sessions

`DatabaseSession` is the protocol every engine's session implements:

- `children(of:)`: the tree (`TreeNode`; `nil` asks for the top level). `TreeOutline` and `TreeSearch` flatten and
  search the part of a tree that's loaded, without asking the server.
- `fields(of:)`, `browse(_:)`, `count(_:)`, `relations(of:)`: items of an `ObjectRef` as a `BrowsePage` of
  `Record`s with `FieldInfo`s. `BrowseRequest` holds search text, `Filter`s (`FilterOp`), `SortKey`s, hidden fields,
  offset and limit.
- `parseInput(_:isNull:for:)`, `statements(for:)`, `apply(_:)`: editing. A `RecordEdit` is an update
  (`FieldChange`s), insert or delete; `statements(for:)` shows what would run, and `apply(_:)` writes the edits
  together where the engine allows it and returns an `ApplyOutcome` with the edits that undo it. A read-only profile
  throws `ReadOnlyError`; a value that doesn't fit throws `InputError`.
- `run(_:context:)`, `explain(_:context:)`, `completions(context:)`: the query editor. `run` returns `QueryRun`s
  whose outputs are tables, documents, text or messages. On a read-only profile `run` throws `ReadOnlyError` (with
  a `reason`) for a write: PostgreSQL logs in with `default_transaction_read_only`, MySQL and MariaDB run `SET SESSION
  TRANSACTION READ ONLY`, SQLite and DuckDB files open read-only, and `ReadOnlyGuard` refuses text that would turn
  that off; SQL Server, MongoDB and Redis, which have no such mode, get statement checks instead.

Engine-specific capabilities are protocols a session may also conform to (check with `as?`):

- `IndexSession`: `indexes(of:)`, `createStatement(for:on:)`, `dropStatement(forIndexNamed:on:)`,
  `runIndexStatement(_:on:)` (PostgreSQL, MySQL, MariaDB, SQLite, MongoDB).
- `DocumentAggregating`: MongoDB aggregation pipelines (`aggregate`, `aggregateFull`, `explainAggregate`).
- `RedisBrowsing`: a Redis key's value and expiry, `mutate(_:in:)` with `RedisMutation` and `RedisUndo`,
  `create(key:type:first:in:)`. `RedisKeyTree.group(_:separator:minimumGroup:)` groups keys by prefix.
- `WideColumnFiltering`: whether a Cassandra or ScyllaDB filter needs a full scan.
- `TunnelOwning`: the session's `SSHTunnel`, if it has one.

### Values

- `CellValue`: a table cell (`.db(DBValue)`), a BSON value (`.bson(BSON)`) or a removed document field (`.unset`);
  `displayText` and `fullText`.
- `ValueCategory`: text, numbers, dates, booleans, binary, JSON, lists, documents; drives which filters and editors
  apply.
- From `BSON` (re-exported): `BSON`, `BSONDocument`, `ObjectID`, `Decimal128`, `BSONParser`; `text(_:indent:)`
  writes mongosh syntax or Extended JSON, `BSONDocument(parsing:)` reads them.

### Secrets

- `SecretStore`: where passwords and keys are kept; `KeychainStore` (the Keychain on Apple platforms, empty
  elsewhere) and `MemorySecretStore` (for tests and previews).
- `SSHKeyStore` and `StoredSSHKey`: imported SSH private keys in a secret store, listed with their public halves.

### DuckDB (re-exported `DuckDBKit`)

- `DuckDBLibrary`: where the downloaded library lives (`directory`), `isSupported` (macOS only), `isInstalled`,
  `installedVersion`, `remove()`. The library is loaded with `dlopen` on first use.
- `DuckDBInstaller`: an `@Observable` download, checksum check and install, with a `state`. Nothing is downloaded
  until `install()` is called. The release comes from this repository's GitHub releases.
- `DuckDBFile`: a `.duckdb` file, or an in-memory database for reading Parquet, CSV and JSON files.

## Platform notes

- **macOS:** every engine, including DuckDB once downloaded.
- **iOS, iPadOS:** every engine but DuckDB (iOS can't load downloaded code; `EngineKind.available` leaves it out).
- **Linux, Windows:** the engines build on v57/SwiftUI's stand-ins (CryptoKit, Network, SQLite3, os) with RSA from
  swift-crypto's `_CryptoExtras`; Database's app runs on both. DuckDB isn't offered there. `KeychainStore` reads
  nothing there.
- **Android:** not yet.

Direct TLS (`useTLS`) works with PostgreSQL, MongoDB, Redis, Cassandra and ScyllaDB (`supportsDirectTLS`). MySQL and
MariaDB start encryption after the connection opens, which these clients don't do: with `useTLS` on, `Connector`
refuses to connect and asks for SSH instead. The SQL Server client sends its login unencrypted, which servers with
Force Encryption on refuse; reach those through SSH.

## Testing

`DatabaseKitTests` runs the same browse, edit and undo scenario on every engine, so most of it needs the test servers
from `docker-compose.yml` (see [Engines](Engines.md#test-servers)). SQLite and DuckDB use temporary files; the DuckDB
cases need the library installed.

```bash
Scripts/test-servers.sh
swift test --filter DatabaseKitTests
```

The tree outline and search tests in it need no servers.

For tests of your own, `MemorySecretStore` keeps secrets in memory, and an SQLite profile
(`ConnectionProfile(engine: .sqlite, filePath:)`) gives a real session with no server.
