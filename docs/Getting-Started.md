# Getting Started

## The window

Database has two parts: a sidebar and the page you're working on.

- The sidebar lists your saved connections in the **Connections** card. Open one and its databases, tables,
  collections or keys load under it.
- The page shows what you picked: a connection's overview, a table, a query tab or a pipeline.

On iPhone you see the sidebar first. Picking a connection, table or query opens its page, and Back returns to the
sidebar. On iPad and the Mac the sidebar and the page sit side by side.

Database connects to nothing when it opens. Your saved connections come from your vault, which syncs through iCloud
when iCloud is on.

## The welcome page

With nothing open, the page shows the welcome:

- **New Connection…** opens the sheet to add a connection.
- **Open a File…** opens a database file. On the Mac that's an SQLite, DuckDB, Parquet or CSV file. On iPhone and iPad
  it's an SQLite file.
- Once you've opened connections, the list is titled **Recent**, newest first. Tap one to connect. A Production
  connection carries a red tag.

## Add your first connection

1. Choose **New Connection…** on the welcome, the **+** on the Connections card, or **File ▸ New Connection…** (⌘N).
2. Paste a connection link from your host, such as `postgres://user:password@host:5432/dbname`. Database recognizes
   the engine, fills in the server and takes the password. Or pick an engine and fill in the details yourself.
3. Pick a **Location**: this device, or an SSH server to go through. See [SSH](SSH.md).
4. Choose **Test** to check it. The sheet says "Connected to …" with the time it took, or why it failed.
5. Choose **Connect**. Database saves the connection and opens it.

See [Connections](Connections.md) for every field in the sheet.

## Open a database file

- Use **Open a File…** on the welcome.
- On iPhone and iPad, open an SQLite file from the Files app with Database (share it, or touch and hold it and choose
  Database). Database adds a connection named after the file and opens it. Opening the same file again reuses that
  connection.
- On the Mac, drop a database file on the window. Drop a folder to have Database offer the database files in it.
- On iPad you can also drag an SQLite file onto the welcome.

## Look around a connection

1. Tap a connection's chevron, or select it. Database connects and loads its tree: databases, schemas, tables and
   views, collections, keyspaces or Redis databases.
2. Selecting a connection shows its overview: the server, how long the connection took, the server's SSH key when it
   goes through SSH, and **New Query**.
3. Pick a table or collection to browse it. See [Browsing and Editing](Browsing-and-Editing.md).

If a connection fails, its page says why in plain words, with **Try Again** and **Edit Connection…**.

## Engines

| Engine | Kind | Query language |
|---|---|---|
| PostgreSQL | Relational | SQL |
| MySQL, MariaDB | Relational | SQL |
| SQL Server | Relational | T-SQL |
| SQLite | File | SQL |
| DuckDB (Mac only) | File · analytics | DuckDB SQL |
| MongoDB | Documents | MongoDB Shell |
| Redis | Keys & values | Redis commands |
| Cassandra, ScyllaDB | Wide column | CQL |

On the Mac, DuckDB is a download you choose: Database offers it when you pick DuckDB in the New Connection sheet, and
in **Settings ▸ General**. With it, Database also opens Parquet, CSV, TSV and JSON files directly. See
[Connections](Connections.md#duckdb-on-the-mac).
