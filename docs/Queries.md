# Queries

Query tabs are where you write your own queries, in the connection's language: SQL, T-SQL for SQL Server, MongoDB
Shell syntax for MongoDB, Redis commands, or CQL for Cassandra and ScyllaDB.

## Open a query tab

Choose **New Query** on the connection's overview, in the connection menu, with the tab strip's **+**, or with
**File ▸ New Query** (⌘T). The tab starts as **Untitled** with a starting query for the table you have selected, such
as `db.<collection>.find({}).limit(20)` for MongoDB or `INFO keyspace` for Redis.

Several tabs show in a strip. Switch between them, or close one with its ×. A saved query's tab shows a dot once
you've changed it.

## Write and run

The editor colors the query as you type, in light and dark. It doesn't autocorrect or use smart quotes. On the Mac it
also suggests completions as you type.

1. Check **Runs in** above the editor: the database, keyspace or Redis database the query runs in. Pick another one
   from its menu.
2. Choose **Run** (⌘↩). The tab shows "Running…", then the number of rows and the time it took.

## Read the results

Switch the results between:

- **Results**: the rows, or documents as shell JSON. Several statements give **Result 1**, **Result 2** and so on.
- **Messages**: a line per statement, and errors in red. A failed query opens here.
- **Plan**: the server's plan, after **Explain**.

On the Mac and iPad, select result rows and touch and hold them (right-click on the Mac) to **Copy Row as CSV** or
**Copy Row as JSON** (or several rows at once).

## Explain and Format

- **Explain** shows how the server plans to run the query, under **Plan**. Redis has no plan; it shows the slow log
  instead.
- **Format** tidies SQL and CQL: keywords upper case, each clause on its own line. Quoted text is left alone.

## Save a query

Choose **Save…** and give it a title. Saved queries show under **Queries** in the sidebar, under their connection,
with your unsaved tabs. Tap one to open it. Saving again keeps the same entry. To delete one, touch and hold it
(right-click on the Mac) and choose **Delete**.

## Export results

**Export ▸ CSV…** or **JSON…** saves the results to a file you pick. The file is named after the tab.
**Export ▸ Copy as CSV** copies them.

## Write queries

A query tab runs what you write, including statements that change data. On a Production connection there's no
review step for a query tab: the review is for changes made in the browser.

On a Read only connection, Redis, MongoDB, Cassandra and ScyllaDB refuse writes, and an SQLite file opens read-only.
PostgreSQL, MySQL, MariaDB and SQL Server run the statement you write. See
[Read only and query tabs](Connections.md#read-only-and-query-tabs).
