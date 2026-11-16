# Database user guide

Database is one app for ten kinds of databases: PostgreSQL, MySQL, MariaDB, SQL Server, SQLite, DuckDB, MongoDB,
Redis, Cassandra and ScyllaDB. You browse tables, collections and keys, filter and sort them, edit them with a review
before anything is saved, and write queries in tabs. It can reach a database through an SSH server, and it shares
your connections, SSH servers and passwords with the other v57 apps through your vault.

## Platforms

<!-- platforms: macos ios linux windows -->

- **Mac:** every feature, including DuckDB (a download you choose), Parquet, CSV and JSON files, the Settings window
  with its Remote pane, and in-app updates.
- **iPhone and iPad:** the same connections, browser, editing, queries, pipelines and Redis tools. Differences:
  - DuckDB isn't offered, so **Open a File…** opens SQLite files only.
  - **Settings** is a button at the foot of the sidebar, with the General, SSH Keys, Privacy, Accounts and Devices
    panes. The DuckDB card and the Remote pane are on the Mac only.
  - On iPhone, tables show as a list and an item opens on its own page. On iPad, tables show as a grid with an
    inspector beside it.
  - With a hardware keyboard on iPad, the menu commands and their shortcuts work as on the Mac.
  - Updates come from the App Store.
- **Linux and Windows:** the same window as on the Mac, with **This Computer** (Linux) or **This PC** (Windows) as
  the local location. There's no iCloud, DuckDB isn't offered, and the query editor is plain text, without colors or
  completions. Shortcuts use Ctrl where the Mac uses ⌘.
  - **Linux** has the Settings window (**Edit ▸ Preferences…**), with **Devices** in place of the Mac's Remote pane,
    and in-app updates (**Help ▸ Check for Updates…**).
  - **Windows** has no Settings window and no in-app updates.

## Pages

- [Getting Started](Getting-Started.md): the window, your first connection, opening a database file.
- [Connections](Connections.md): the New Connection sheet, links, encryption, Production and Read only, managing
  saved connections.
- [SSH](SSH.md): reaching a database through an SSH server, keys, fallback addresses and server keys.
- [Browsing and Editing](Browsing-and-Editing.md): search, filters, sort, fields, the inspector, editing with review,
  undo, indexes and the Query Editor strip.
- [Queries](Queries.md): query tabs, results, Explain, Format, saved queries and export.
- [Pipelines](Pipelines.md): building MongoDB aggregation pipelines step by step, also on SQL tables.
- [Redis](Redis.md): the key browser, value editors, expiry and the command line.
- [Accounts and Sync](Accounts-and-Sync.md): iCloud, vault accounts and what other v57 apps see.
- [Settings](Settings.md): the Settings window on the Mac and Linux, and Settings on iPhone and iPad.
- [Privacy and Security](Privacy-and-Security.md): what Database sends over the network, passwords, server keys and
  insecure logins.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md)

## Works with other v57 apps

- [Vault](https://github.com/v57/Vault/blob/main/docs/README.md) holds your database connections, SSH servers,
  passwords and server keys. A connection or SSH server you add in Database shows in Vault, and the other way round.
- [Shell](https://github.com/v57/Shell/blob/main/docs/README.md) lists the same connections in its sidebar and opens
  them with Database's interface.
- [Hub](https://github.com/v57/hub-app/blob/main/docs/README.md): your Hub devices show as **Via Hub** locations when
  you connect.

## Network

Database contacts no server on its own. It connects to a database or SSH server when you open, test or refresh a
connection, syncs your vault through iCloud when iCloud is on, downloads DuckDB only when you ask, and checks for
updates only when you ask or after you turn on automatic checks.
See [Privacy and Security](Privacy-and-Security.md).

## For developers

Database's libraries are one Swift package (`https://github.com/v57/Database.git`, branch `main`). Add the products
you need; the app itself is a separate package in `App/`.

| Library | Purpose | Platforms | Import |
|---|---|---|---|
| [DatabaseKit](DatabaseKit.md) | Connections to all ten engines, sessions for browsing, editing and queries; re-exports WireKit, SSHTunnel, BSON and DuckDBKit | macOS, iOS, Linux, Windows (DuckDB on macOS only) | `import DatabaseKit` |
| [DatabaseUI](DatabaseUI.md) | Database's whole interface, for embedding in an app (Shell does) | macOS, iOS, Linux (GTK) and Windows (WinUI) through v57/SwiftUI | `import DatabaseUI` |
| [WireKit](WireKit.md) | Byte streams, dialers and the value types the engines share | macOS, iOS, Linux, Windows | `import WireKit` |
| [SQLiteKit](SQLiteKit.md) | A SQLite file with bound parameters, returning WireKit's results | macOS, iOS, Linux, Windows | `import SQLiteKit` |
| [SSHTunnel](SSHTunnel.md) | Database connections over SSH channels, with no local port; re-exports SSHKit | macOS, iOS, Linux; Windows without jump hosts | `import SSHTunnel` |
| [Libssh2](SSHTunnel.md) | libssh2 from the SSH repository (Mbed TLS on Apple platforms), for apps that drive their own sessions (shares the SSHTunnel page) | macOS, iOS, Linux, Windows | `import CLibssh2` |

The engine clients (`PostgresWire`, `MySQLWire`, `TDSWire`, `MongoWire`, `BSON`, `RedisWire`, `CQLWire`, `DuckDBKit`)
are internal targets that DatabaseKit wraps; [Engines](Engines.md) describes them and how to run the tests against the
Docker test servers in `docker-compose.yml`. SSH logins, keys, SFTP and commands are documented in the
[SSH repository](https://github.com/v57/SSH/blob/main/docs/SSHKit.md).
