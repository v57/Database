# Engines

Each database protocol has its own pure-Swift client on [WireKit](WireKit.md). These are internal targets of the
package, not products: an app can't add them as dependencies. Apps reach them through
[DatabaseKit](DatabaseKit.md)'s `Connector` and `DatabaseSession`, which wraps each client in an engine-neutral
session. This page is for people working on the engines, and explains how to run their tests.

| Target | Speaks | Engines | Notes |
|---|---|---|---|
| `PostgresWire` | PostgreSQL v3 protocol (simple queries, text results) | PostgreSQL | SCRAM-SHA-256; MD5 and cleartext only over SSH, TLS or loopback unless allowed |
| `MySQLWire` | MySQL classic protocol (COM_QUERY, text results) | MySQL, MariaDB | `caching_sha2_password` and `mysql_native_password`; no TLS (use SSH) |
| `TDSWire` | TDS 7.4 (SQL batches, SQL logins) | SQL Server | Login sent unencrypted; servers that force encryption are reached through SSH |
| `MongoWire` + `BSON` | MongoDB wire protocol (OP_MSG) | MongoDB | SCRAM-SHA-256 or SCRAM-SHA-1 |
| `RedisWire` | RESP2 | Redis | `AUTH` with user and password; `SCAN`-based key listing |
| `CQLWire` | CQL native protocol v4 | Cassandra, ScyllaDB | Password authenticator; paging; consistency level per client |
| `SQLiteKit` | the system's SQLite | SQLite | A product of its own: see [SQLiteKit](SQLiteKit.md) |
| `DuckDBKit` + `Cduckdb` | DuckDB's C API, loaded with `dlopen` | DuckDB | Re-exported by DatabaseKit; the library is an optional download, macOS only |

`BSON` (documents, ObjectID, Decimal128, mongosh syntax and Extended JSON) and `DuckDBKit` are re-exported by
DatabaseKit, so apps see their types; the other clients stay inside it.

Every network client is an actor with the same shape: a `Config` (host, port, user, password, database, `tls`,
`connectTimeout`, and a `dialer`), a static `connect(_:)`, `close()`, and the protocol's own calls
(`PostgresClient.query(_:)` and `execute(_:)`, `MongoClient.find(…)` and `aggregate(…)`, `RedisClient.run(_:)` and
`pipeline(_:)`, `CQLClient.query(…)`, and so on). The `dialer` decides how the client reaches its server: TCP of its
own, or a channel of an SSH login (see [SSHTunnel](SSHTunnel.md)). Results come back as WireKit's `DBResult` (BSON
documents for MongoDB, RESP values for Redis).

## Adding to an engine

- Protocol code goes in the engine's target; the engine-neutral behaviour (tree, browse, edits, undo, completions)
  goes in DatabaseKit's session for that family (`Sources/DatabaseKit/SQL`, `Mongo`, `Redis`, `CQL`).
- A login that would send a password readably checks `WireDialer.protects(host:tls:)` and throws
  `WireError.insecureLogin` unless the connection allows insecure logins.
- Off Apple platforms the engines build on v57/SwiftUI's stand-ins (see the tail of `Package.swift`); MySQL's RSA
  password exchange uses Security.framework on Apple platforms and swift-crypto's `_CryptoExtras` elsewhere.

## Test servers

The engine and session tests connect to real servers. `docker-compose.yml` at the repository root runs one of each,
published on `127.0.0.1` only:

| Service | Port | Login |
|---|---|---|
| `postgres` (PostgreSQL 18) | 5432 | `postgres` / `postgres` |
| `mysql` (MySQL 8.4) | 3306 | `root` or `app`, see the file |
| `mariadb` (MariaDB 11.8) | 3307 | `root` or `app`, see the file |
| `sqlserver` (SQL Server 2022, `linux/amd64`) | 1433 | `sa`, see the file |
| `mongodb` (MongoDB 8) | 27017 | none |
| `redis` (Redis 8) | 6379 | none |
| `cassandra` (Cassandra 5) | 9042 | `cassandra` / `cassandra` (password authenticator on) |
| `scylla` (ScyllaDB 2025.1) | 9043 | none |
| `sshd` (Alpine OpenSSH bastion) | 2222 | user `tunnel`, the key in `.testing/ssh` or the password in the file |

The passwords are test values in `docker-compose.yml`; nothing there is secret. From inside the bastion the other
services are reachable by their service names (`postgres:5432`, `redis:6379`, …), which is what the tunnel tests use.

Start them with the script, which first makes the bastion's test key in `.testing/ssh` (gitignored, so every checkout
makes its own) and then waits until every service is healthy:

```bash
Scripts/test-servers.sh              # start and wait
swift test                           # every suite
Scripts/test-servers.sh down         # stop; data stays in named volumes
Scripts/test-servers.sh down -v      # stop and delete the data
```

You need Docker with Compose v2 (`docker compose`). SQL Server's image is `linux/amd64`, so it runs under emulation on
Apple silicon and takes a while to become healthy. A `mongodb-demo` service sits behind the `screenshots` profile and
isn't started by the script.

Run one engine's tests with a filter:

```bash
swift test --filter PostgresWireTests
swift test --filter MySQLWireTests        # MySQL and MariaDB
swift test --filter TDSWireTests
swift test --filter MongoWireTests
swift test --filter RedisWireTests
swift test --filter CQLWireTests          # Cassandra and ScyllaDB
swift test --filter DatabaseKitTests      # the sessions, on every engine
swift test --filter SSHTunnelTests        # through the sshd bastion
```

These need no servers: `WireKitTests`, `BSONTests`, `SQLiteKitTests`. A test whose server isn't running fails to
connect rather than being skipped.

Servers on other ports: the tests read `PG_HOST`, `PG_PORT`, `MYSQL_PORT`, `MARIADB_PORT`, `MSSQL_PORT`, `MONGO_PORT`,
`REDIS_PORT`, `CASSANDRA_PORT` and `SCYLLA_PORT` (the clients' tests), and `POSTGRES_TEST_PORT`, `MYSQL_TEST_PORT` and
`MONGO_TEST_PORT` (DatabaseKit's). The SSH variables are on the [SSHTunnel](SSHTunnel.md#testing) page.

### DuckDB

`DuckDBKitTests` run only when the DuckDB library is installed. Point the tests at a folder holding it with
`DATABASE_DUCKDB_DIR`. The installer's tests read a local zip instead of downloading, and run on macOS only.
