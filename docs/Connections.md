# Connections

A connection is everything Database needs to reach one database: the engine, the server or file, the login, how it
travels and how careful Database should be with it. Connections are saved in your vault, so the other v57 apps and
your other devices see them too.

## Add a connection

Choose **New Connection…** on the welcome, the **+** on the Connections card in the sidebar, or
**File ▸ New Connection…** (⌘N). The sheet has these parts, top to bottom.

### Connection link

Paste a link from your host into **Link**. Database recognizes these:

| Engine | Link starts with |
|---|---|
| PostgreSQL | `postgres://`, `postgresql://` |
| MySQL | `mysql://` |
| MariaDB | `mariadb://` |
| SQL Server | `sqlserver://`, `mssql://`, `jdbc:sqlserver://` |
| SQLite | `sqlite://`, `sqlite3://` |
| DuckDB (Mac) | `duckdb://` |
| MongoDB | `mongodb://`, `mongodb+srv://` |
| Redis | `redis://`, `rediss://` |
| Cassandra | `cassandra://`, `cql://` |
| ScyllaDB | `scylla://`, `scylladb://` |

When it understands the link, the sheet says "Recognized PostgreSQL at …" (or the engine you pasted) with a green
check. It fills in the engine, server, port, database and user, and takes the password from the link.

### Database

Pick the engine from the grid. Each tile says what kind of database it is: Relational, File, Documents, Keys & values
or Wide column. Picking one sets its usual port and user.

### Location

Where Database connects from:

- **This Mac**, **This iPhone** or **This iPad** (**This PC** on Windows, **This Computer** on Linux) connects
  directly.
- A tile for each SSH server saved in your vault, by Database, Shell or another v57 app. Database logs in to that
  server and reaches the database from there. The sheet says "Connects through … to …".
- **Via Hub** tiles for your devices that your Hub knows about.
- **New SSH** adds an SSH server.

See [SSH](SSH.md) for SSH servers, keys and their menus.

### Server

For a server engine you see the server in one line, with **Edit** to change it. The fields are **Host**, **Port**,
**Database** (**Index** for Redis, **Keyspace** for Cassandra and ScyllaDB) and **User**. MongoDB adds
**Auth database**.

For SQLite (and DuckDB on the Mac) you pick a **File** with **Choose…** instead. The connection's name starts as the
file's name.

### Password

Type the password. With **Save password in the Keychain** on, Database keeps it in your keychain, and with iCloud on
it syncs to your other devices. With it off, Database doesn't keep it.

### Encryption

- PostgreSQL, MongoDB, Redis, Cassandra and ScyllaDB have **Encrypted connection (TLS)**. Turn it on for servers that
  require it, like hosted databases. PostgreSQL needs version 17 or later for this.
- With TLS on, **Accept self-signed certificates** lets Database connect to a server whose certificate isn't signed by
  a known authority. Turn it on only for a server you know.
- MySQL, MariaDB and SQL Server show **Encrypted after it starts**: they switch to encryption after the connection
  starts, which Database doesn't do. Connect through SSH to encrypt the connection end to end.

### Allow insecure login

PostgreSQL, MySQL and MariaDB connections that don't go through SSH have **Allow insecure login**. It's off by default.

Some servers ask for the password in a form anyone on the network could read. With the switch off, Database refuses to
send it, unless the connection goes through SSH or is encrypted with TLS. Turn it on only when you trust the network
between you and the server. See [Privacy and Security](Privacy-and-Security.md#insecure-logins).

### Name and safety

- **Name**: how the connection shows in the sidebar.
- **Color**: a dot beside its name in the sidebar.
- **Production**: shows a red tag in the sidebar, the welcome and the browser. Every change is reviewed before it's
  saved, and Redis asks before running a change.
- **Read only**: look, but never change anything. Editing, adding and deleting are gone from the browser and the
  inspector. See the note under [Read only and query tabs](#read-only-and-query-tabs).

### Test and Connect

The bottom of the sheet shows what's missing, in orange, such as an empty host or a port out of range. **Test** and
**Connect** wait until it's complete.

- **Test** tries the connection without saving it. It shows "Connected to … in …", or the reason it failed. Through
  SSH it also says that the server's SSH key was saved.
- **Connect** saves the connection and opens it.

## Edit a connection

Touch and hold a connection in the sidebar (on the Mac, right-click it) and choose **Edit Connection…**. Change what
you need and choose **Save**. If the connection is open, it reconnects with the new settings and keeps its query tabs.

## The connection menu

Touch and hold a connection (right-click on the Mac), or use the **…** on the open connection's card:

- **Connect** when it's closed.
- **New Query**, **Refresh** and **Disconnect** when it's open. Disconnect closes the connection; it stays saved.
- **Edit Connection…**, **Duplicate** and **Copy Link**. Copy Link copies the connection as a link, without the
  password.
- **Delete…** removes the saved connection and its password. The database itself isn't touched. The connection is
  gone from Shell and your other devices too.

## Find and order connections

- Type in the sidebar's search to filter connections by name or host. For the open connection, the search also
  narrows its loaded databases, tables, saved queries and open tabs, and opens branches to show matches. It searches
  only what's already loaded and says what it didn't search. It asks the server nothing.
- Drag a connection up or down to reorder the list. The order is kept, also on your other devices.

## Read only and query tabs

A Read only connection never changes anything from the browser, the inspector, indexes or the Redis tools. In a
query tab, a statement that would change data is refused with "This connection is read only…":

- **PostgreSQL**, **MySQL** and **MariaDB** connect in the server's own read-only mode, so the server refuses
  writes and changes to tables. A statement that would turn that mode off (such as `SET SESSION TRANSACTION READ
  WRITE`) is refused before it's sent.
- **SQLite** and **DuckDB** files open read-only.
- **SQL Server**, **MongoDB**, **Redis**, **Cassandra** and **ScyllaDB** have no read-only mode for one connection,
  so Database reads what you run and lets through only what reads: on SQL Server, statements without `INSERT`,
  `UPDATE`, `DELETE`, `CREATE`, `EXEC` and the like; on MongoDB, finds, aggregations without `$out` or `$merge`, and
  commands that read; on Redis, commands the server doesn't mark as writes, and no scripts.

Read only guards against mistakes. To be sure nothing changes, log in as a user that can only read.

## DuckDB on the Mac

DuckDB isn't part of the app. When you pick DuckDB in the New Connection sheet, or open a DuckDB connection without it,
Database offers **Download**. It downloads DuckDB from GitHub only when you choose Download, and shows the size
first. **Settings ▸ General** also has **Update** when a newer version is available, and **Remove**. Removing takes
effect after Database restarts.

With DuckDB, a connection can open a `.duckdb` file, or a Parquet, CSV, TSV or JSON file to query directly.
