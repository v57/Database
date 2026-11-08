# Database user guide

Database is one app for ten kinds of databases: PostgreSQL, MySQL, MariaDB, SQL Server, SQLite, DuckDB, MongoDB,
Redis, Cassandra and ScyllaDB. You browse tables, collections and keys, filter and sort them, edit them with a review
before anything is saved, and write queries in tabs. It can reach a database through an SSH server, and it shares
your connections, SSH servers and passwords with the other v57 apps through your vault.

## Platforms

- **Mac:** every feature, including DuckDB (a download you choose), Parquet, CSV and JSON files, the Settings window
  and in-app updates.
- **iPhone and iPad:** the same connections, browser, editing, queries, pipelines and Redis tools. Differences:
  - DuckDB isn't offered, so **Open a File…** opens SQLite files only.
  - There's no Settings screen. You make and import SSH keys in the SSH configuration sheet. The iCloud switch is in
    another v57 app's Settings, such as [Vault](https://github.com/v57/Vault/blob/main/docs/README.md)'s.
  - On iPhone, tables show as a list and an item opens on its own page. On iPad, tables show as a grid with an
    inspector beside it.
  - With a hardware keyboard on iPad, the menu commands and their shortcuts work as on the Mac.
- **Linux and Windows:** Database builds there too, and is less tested than the Mac app. There's no iCloud, and DuckDB
  isn't offered. Linux has the Settings window and in-app updates; Windows has neither.

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
- [Settings](Settings.md): the Mac's Settings window.
- [Privacy and Security](Privacy-and-Security.md): what Database sends over the network, passwords, server keys and
  insecure logins.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md)

## Works with other v57 apps

- [Vault](https://github.com/v57/Vault/blob/main/docs/README.md) holds your database connections, SSH servers,
  passwords and server keys. A connection or SSH server you add in Database shows in Vault, and the other way round.
- [Shell](https://github.com/v57/Shell/blob/main/Docs/README.md) lists the same connections in its sidebar and opens
  them with Database's interface.
- [Hub](https://github.com/v57/hub-app/blob/main/docs/README.md): your Hub devices show as **Via Hub** locations when
  you connect.

## Network

Database contacts no server on its own. It connects to a database or SSH server when you open, test or refresh a
connection, syncs your vault through iCloud when iCloud is on, and downloads DuckDB or an update only when you ask.
See [Privacy and Security](Privacy-and-Security.md).
