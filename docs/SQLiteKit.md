# SQLiteKit

SQLiteKit opens a SQLite database file and runs SQL on it, returning [WireKit](WireKit.md)'s `DBResult` and
`DBValue`, the same types Database's network engines return. It is a small actor over the system's SQLite: open a
file, run statements with bound parameters, read the rows.

It is not an ORM or a migration tool, and it has no connection pool. Database's app reaches SQLite files through
[DatabaseKit](DatabaseKit.md) (engine `.sqlite`); use SQLiteKit directly when an app keeps a SQLite file of its own
(Dev's imported translation database does).

## Getting started

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/v57/Database.git", branch: "main"),
],
targets: [
  .target(
    name: "MyApp",
    dependencies: [
      .product(name: "SQLiteKit", package: "Database"),
      .product(name: "WireKit", package: "Database"),
    ]),
]
```

```swift
import SQLiteKit
import WireKit

let db = try SQLiteFile(path: "/tmp/notes.sqlite")
_ = try await db.execute("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
_ = try await db.execute("INSERT INTO notes (title) VALUES (?)", binds: [.text("Groceries")])
let result = try await db.execute("SELECT id, title FROM notes WHERE title LIKE ?", binds: [.text("G%")])
for record in result.records {
  print(record["id"]?.intValue ?? 0, record["title"]?.stringValue ?? "")
}
await db.close()
```

## Main API

- `SQLiteFile(path:readOnly:create:)`: opens the file (creating it unless `create` is false; read-only when
  `readOnly`). The connection has a 5-second busy timeout and `PRAGMA foreign_keys = ON`.
- `query(_:binds:maxRows:)`: runs every statement in the text and returns one `DBResult` per statement. `binds` fill
  the `?` and `?1` parameters of each statement that has them, so text from elsewhere is never spliced into SQL.
  Rows past `maxRows` (100,000 by default) are dropped, with a note in the result's `messages`.
- `execute(_:binds:)`: the last statement's result.
- `lastInsertRowID`, `isOpen`, `close()`, `path`, `readOnly`.
- `SQLiteError`: `code` (SQLite's result code) and `message`.

Values come back as `.null`, `.int`, `.double`, `.bytes` or `.text`. When binding, `.bool` becomes 0 or 1, and any
value other than null, numbers and bytes is bound as its text. For a statement without result columns,
`affectedRows` is the number of changed rows.

## Platform notes

- **macOS, iOS:** the system's SQLite (`import SQLite3`).
- **Linux, Windows:** builds against v57/SwiftUI's `SQLite3` module (see `Package.swift`'s Windows and Linux tail).
- **Android:** not yet.

## Testing

```bash
swift test --filter SQLiteKitTests
```

The tests use temporary files and need no servers.
